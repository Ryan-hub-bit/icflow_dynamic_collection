#!/bin/bash

# Output paths
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ARCH_PACKAGES_ROOT=${ARCH_PACKAGES_ROOT:-"$HOME/arch_packages"}
LLVM_BUILD=${LLVM_BUILD:-"$HOME/llvm-project/build"}
MAKEPKG_CONF=${MAKEPKG_CONF:-"$SCRIPT_DIR/.makepkg.conf"}
BUILD_TIMEOUT=${BUILD_TIMEOUT:-1200}
BUILD_LOG="$ARCH_PACKAGES_ROOT/build_summary.log"
ELF_OUTPUT_DIR="$ARCH_PACKAGES_ROOT/elf_outputs"
ELF_MAP="$ARCH_PACKAGES_ROOT/elf_map.txt"
PROGRESS_LOG="$ARCH_PACKAGES_ROOT/processed_urls.txt"

mkdir -p "$ELF_OUTPUT_DIR"

if [[ ! -x "$LLVM_BUILD/bin/clang" || ! -x "$LLVM_BUILD/bin/clang++" ]]; then
  echo "Custom clang and clang++ are required under: $LLVM_BUILD/bin" >&2
  exit 1
fi

if [[ ! -f "$MAKEPKG_CONF" ]]; then
  echo "makepkg configuration not found: $MAKEPKG_CONF" >&2
  exit 1
fi
# Only create a new BUILD_LOG if it doesn't exist
if [ ! -f "$BUILD_LOG" ]; then
  > "$BUILD_LOG"
fi
> "$ELF_MAP"
touch "$PROGRESS_LOG"

# GitLab access info
GITLAB_USERNAME=${GITLAB_USERNAME:-}
GITLAB_TOKEN=${GITLAB_TOKEN:-}

# Parallel settings
MAX_JOBS=${MAX_JOBS:-8}

# Rate limiting settings - 30 clones per minute (more conservative than the 600 per min limit)
CLONE_RATE_LIMIT=${CLONE_RATE_LIMIT:-10}
CLONE_COUNTER=0
CLONE_COUNTER_FILE="$ARCH_PACKAGES_ROOT/clone_counter.txt"
CLONE_TIMESTAMP_FILE="$ARCH_PACKAGES_ROOT/clone_timestamp.txt"

# Initialize rate limiting counters
if [ ! -f "$CLONE_COUNTER_FILE" ]; then
  echo "0" > "$CLONE_COUNTER_FILE"
fi
if [ ! -f "$CLONE_TIMESTAMP_FILE" ]; then
  date +%s > "$CLONE_TIMESTAMP_FILE"
fi

# ─── Functions ────────────────────────────────────────────── #

# Function to wait until running background jobs < MAX_JOBS
wait_for_jobs() {
  while (( $(jobs -r | wc -l) >= MAX_JOBS )); do
    sleep 1
  done
}

# Function to enforce rate limiting for cloning
enforce_clone_rate_limit() {
  local current_time
  local start_time
  local elapsed_time

  current_time=$(date +%s)
  start_time=$(cat "$CLONE_TIMESTAMP_FILE")
  elapsed_time=$((current_time - start_time))

  # Load the current counter value
  CLONE_COUNTER=$(cat "$CLONE_COUNTER_FILE")

  # If a minute has passed, reset counter
  if (( elapsed_time >= 60 )); then
    echo "0" > "$CLONE_COUNTER_FILE"
    date +%s > "$CLONE_TIMESTAMP_FILE"
    CLONE_COUNTER=0
    return 0
  fi

  # If we've reached the rate limit, wait until one minute has passed
  if (( CLONE_COUNTER >= CLONE_RATE_LIMIT )); then
    local wait_time=$((60 - elapsed_time))
    echo "⏳ Rate limit reached. Waiting ${wait_time} seconds before next batch..."
    sleep "$wait_time"

    # Reset counter and timestamp
    echo "0" > "$CLONE_COUNTER_FILE"
    date +%s > "$CLONE_TIMESTAMP_FILE"
    CLONE_COUNTER=0
  fi

  return 0
}

# Function to increment clone counter
increment_clone_counter() {
  CLONE_COUNTER=$((CLONE_COUNTER + 1))
  echo "$CLONE_COUNTER" > "$CLONE_COUNTER_FILE"
}

# Function to handle rate limit responses and retry logic
handle_rate_limit() {
  local http_code=$1
  local retry_after=${2:-60}  # Default to 60 seconds if not provided

  if [[ $http_code -eq 429 ]]; then
    echo "⚠️ Rate limit exceeded (HTTP 429). Waiting ${retry_after} seconds before retry..."
    sleep "$retry_after"
    return 0
  fi

  return 1
}

# Function to clone a package repo
clone_package() {
  local url="$1"
  local section_dir="$2"
  local max_retries=3
  local retry_count=0

  # Enforce rate limiting
  enforce_clone_rate_limit

  # Public repositories do not need credentials. Authentication is opt-in.
  local clone_url="$url"
  if [[ -n "$GITLAB_TOKEN" && "$url" == https://* ]]; then
    clone_url="${url/https:\/\//https:\/\/$GITLAB_USERNAME:$GITLAB_TOKEN@}"
  fi
  local pkg_name
  pkg_name=$(basename "$url" .git)

  echo "🌐 Cloning $pkg_name..."

  while (( retry_count < max_retries )); do
    # Use git clone with output redirected to a temp file to capture HTTP status
    local temp_output
    temp_output=$(mktemp)

    if git clone "$clone_url" "$pkg_name" &>"$temp_output"; then
      echo "✅ CLONE SUCCESS: $pkg_name" | tee -a "$BUILD_LOG"
      # Record URL in the progress log
      echo "$url" >> "$PROGRESS_LOG"
      rm -f "$temp_output"
      break
    else
      # Check if the failure was due to rate limiting
      if grep -q "HTTP 429" "$temp_output"; then
        retry_count=$((retry_count + 1))
        local retry_after
        retry_after=$(grep -oP 'Retry-After: \K\d+' "$temp_output" || echo 60)

        rm -f "$temp_output"

        if (( retry_count >= max_retries )); then
          echo "❌ CLONE FAILED (Rate limit): $pkg_name after $max_retries retries" | tee -a "$BUILD_LOG"
          echo "$url" >> "$PROGRESS_LOG"
          break
        fi

        echo "⚠️ Rate limit hit for $pkg_name, retry $retry_count/$max_retries after ${retry_after}s..."
        sleep "$retry_after"
      else
        echo "❌ CLONE FAILED: $pkg_name ($url)" | tee -a "$BUILD_LOG"
        echo "$url" >> "$PROGRESS_LOG"
        rm -f "$temp_output"
        break
      fi
    fi
  done

  # Increment the clone counter after a clone attempt
  increment_clone_counter
}

# Function to build a package
build_package() {
  local pkg_dir=$1
  local full_path
  full_path=$(realpath "$pkg_dir")

  echo "⚙️  Building package in $full_path..."

  cd "$full_path" || return
  export CC="$LLVM_BUILD/bin/clang"
  export CXX="$LLVM_BUILD/bin/clang++"

  if timeout "${BUILD_TIMEOUT}" makepkg --config "$MAKEPKG_CONF" --syncdeps --noconfirm --needed --skippgpcheck &> build.log; then
    echo "✅ BUILD SUCCESS: $full_path" | tee -a "$BUILD_LOG"
    cd - > /dev/null

    # Copy usable ELF files (flattened), record mapping
    find "$full_path/pkg" -type f | while read -r exe; do
      if file "$exe" | grep -q "ELF"; then
        if objdump -h "$exe" &>/dev/null; then
          out_dir="$ELF_OUTPUT_DIR/$(basename "$pkg_dir")"
          mkdir -p "$out_dir"

          base_name=$(basename "$exe")
          dest="$out_dir/$base_name"

          i=1
          while [[ -e "$dest" ]]; do
            dest="$out_dir/${base_name}_$i"
            ((i++))
          done

          cp "$exe" "$dest"
          echo "$exe -> $(realpath --relative-to="$ELF_OUTPUT_DIR" "$dest")" >> "$ELF_MAP"
        fi
      fi
    done

    echo "🧹 Cleaning up $full_path"
    chmod -R u+w "$full_path" 2>/dev/null || true
    rm -rf "$full_path"
  else
    echo "❌ BUILD FAILED: $full_path" | tee -a "$BUILD_LOG"
    echo "🧹 Cleaning up $full_path"
    chmod -R u+w "$full_path" 2>/dev/null || true
    chmod -R u+w "$full_path" 2>/dev/null || true
    rm -rf "$full_path"
    cd - > /dev/null
  fi
}

process_packages() {
  local section=$1
  local list_file=$2

  echo "📦 Processing $section packages..."
  echo "File size: $(wc -l < "$list_file") lines"

  local section_dir="${section}_packages"
  mkdir -p "$section_dir"
  cd "$section_dir" || exit

  echo "🌐 Cloning and building packages..."
  local processed_count=0
  local skipped_count=0
  local total_count=0
  local batch_count=0
  local batch_urls=()

  # Use a different approach to read the file
  mapfile -t all_urls < "$list_file"
  echo "Read ${#all_urls[@]} lines from file"

  for url in "${all_urls[@]}"; do
    total_count=$((total_count + 1))

    # Skip comments and empty lines
    [[ "$url" =~ ^#.*$ || -z "$url" ]] && {
      echo "Skipped comment/empty line: $total_count";
      skipped_count=$((skipped_count + 1));
      continue;
    }

    # Check if already processed
    if grep -Fxq "$url" "$PROGRESS_LOG"; then
      echo "⏭️  Already processed: $url ($total_count)"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    # Add URL to current batch
    batch_urls+=("$url")
    ((batch_count++))
    ((processed_count++))

    echo "Added to batch: $url ($processed_count processed, $total_count total)"

    # Process batch when limit reached
    if (( batch_count >= 10 )); then
      echo "Processing batch of $batch_count URLs..."
      process_batch "$section_dir" "${batch_urls[@]}"
      echo "Batch completed. Processed $processed_count of $total_count (skipped $skipped_count)"

      # Reset batch
      batch_count=0
      batch_urls=()
    fi
  done

  # Process remaining URLs
  if (( batch_count > 0 )); then
    echo "Processing final batch of $batch_count URLs..."
    process_batch "$section_dir" "${batch_urls[@]}"
  fi

  echo "✅ All packages processed for $section!"
  echo "Final stats: Processed $processed_count, Skipped $skipped_count, Total $total_count"
  cd ..
}

# Process a batch of packages (clone then build)
process_batch() {
  local section_dir=$1
  shift
  local urls=("$@")
  local cloned_dirs=()

  echo "🔄 Processing new batch of ${#urls[@]} packages..."

  # Clone phase for this batch
  for url in "${urls[@]}"; do
    local pkg_name
    pkg_name=$(basename "$url" .git)
    wait_for_jobs
    clone_package "$url" "$section_dir" &
    cloned_dirs+=("$pkg_name")
  done

  wait
  echo "✅ Batch cloning done!"

  # Build phase for this batch
  echo "⚙️ Building packages from this batch..."
  for pkg_name in "${cloned_dirs[@]}"; do
    local pkg_dir="$pkg_name"
    if [ -d "$pkg_dir" ]; then
      wait_for_jobs
      build_package "$pkg_dir" &
    fi
  done

  wait
  echo "✅ Batch building done!"

  # Short pause before next batch to help with rate limiting
  sleep 2
}

# ─── Main ─────────────────────────────────────────────────── #

section=${1:-extra}
list_file=${2:-"$ARCH_PACKAGES_ROOT/$section/clone_urls.txt"}

if [[ ! -f "$list_file" ]]; then
  echo "Package URL list not found: $list_file" >&2
  echo "Usage: ./buildall_timeout.sh [SECTION] [URL_LIST]" >&2
  exit 2
fi

process_packages "$section" "$(realpath "$list_file")"

# ─── Success Rate Summary ────────────────────────────────── #

echo ""
echo "📈 Generating success rate report..."

clone_success=$(grep -c "^✅ CLONE SUCCESS:" "$BUILD_LOG" || true)
clone_failed=$(grep -c "^❌ CLONE FAILED:" "$BUILD_LOG" || true)
build_success=$(grep -c "^✅ BUILD SUCCESS:" "$BUILD_LOG" || true)
build_failed=$(grep -c "^❌ BUILD FAILED:" "$BUILD_LOG" || true)

echo "🔹 Clone success: $clone_success"
echo "🔹 Clone failed:  $clone_failed"
echo "🔸 Build success: $build_success"
echo "🔸 Build failed:  $build_failed"

total_clone=$((clone_success + clone_failed))
total_build=$((build_success + build_failed))

if (( total_clone > 0 )); then
  clone_rate=$(awk "BEGIN {printf \"%.2f\", ($clone_success/$total_clone)*100}")
else
  clone_rate=0
fi

if (( total_build > 0 )); then
  build_rate=$(awk "BEGIN {printf \"%.2f\", ($build_success/$total_build)*100}")
else
  build_rate=0
fi

echo "📊 Clone success rate: ${clone_rate}%"
echo "📊 Build success rate: ${build_rate}%"
echo ""
echo "📝 Build log saved to: $BUILD_LOG"
echo "📜 ELF binary map saved to: $ELF_MAP"
echo "📘 Processed URLs saved to: $PROGRESS_LOG"
