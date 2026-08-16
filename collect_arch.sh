#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
    cat <<'EOF'
Usage: collect_arch.sh {core|extra|all} [OUTPUT_DIRECTORY]

Run ICFlow dynamic collection with the package URL snapshots copied from
Ryan-hub-bit/arch_scripts. Missing Core and Extra lists are generated from the
current Arch Linux package API. Required and optional environment variables are
the same as collect_dynamic.sh.

Examples:
  bash ./collect_arch.sh core
  bash ./collect_arch.sh extra /data/icflow-output
  bash ./collect_arch.sh all /data/icflow-output
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage >&2
    exit 2
fi

selection=$1
output_root=${2:-"$SCRIPT_DIR/output"}

case $selection in
    core | extra)
        repositories=("$selection")
        ;;
    all)
        repositories=(core extra)
        ;;
    *)
        echo "Unknown package set: $selection" >&2
        usage >&2
        exit 2
        ;;
esac

failures=0

for repository in "${repositories[@]}"; do
    if [[ ! -f "$SCRIPT_DIR/$repository/clone_urls.txt" ]]; then
        echo "Package URL lists are missing; generating current Core and Extra lists..."
        bash "$SCRIPT_DIR/collect_arch_git.sh" "$SCRIPT_DIR"
        break
    fi
done

for repository in "${repositories[@]}"; do
    url_list="$SCRIPT_DIR/$repository/clone_urls.txt"
    if [[ ! -f $url_list ]]; then
        echo "Package URL list does not exist: $url_list" >&2
        failures=$((failures + 1))
        continue
    fi

    if ! "$SCRIPT_DIR/collect_dynamic.sh" \
        "$url_list" "$output_root/$repository"; then
        failures=$((failures + 1))
    fi
done

if (( failures > 0 )); then
    echo "Collection failed for $failures package set(s)." >&2
    exit 1
fi

echo "Arch package collection finished successfully: $output_root"
