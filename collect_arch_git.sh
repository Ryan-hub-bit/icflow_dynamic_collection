#!/usr/bin/env bash

set -Eeuo pipefail

OUTPUT_ROOT=${1:-"$HOME/arch_packages"}
PACKAGE_API=https://archlinux.org/packages/search/json/

for command in awk curl jq mktemp realpath sort wc; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command not found: $command" >&2
        exit 1
    fi
done

mkdir -p "$OUTPUT_ROOT/core" "$OUTPUT_ROOT/extra"
OUTPUT_ROOT=$(realpath "$OUTPUT_ROOT")
TEMP_DIR=$(mktemp -d "$OUTPUT_ROOT/.collect-arch-git.XXXXXX")
trap 'rm -rf -- "$TEMP_DIR"' EXIT

fetch_repository() {
    local api_repository=$1
    local output_name=$2
    local output_dir="$OUTPUT_ROOT/$output_name"
    local packages_temp="$TEMP_DIR/$output_name-packages.txt"
    local urls_temp="$TEMP_DIR/$output_name-clone_urls.txt"
    local page=1
    local page_count page_total response

    : > "$packages_temp"
    echo "Fetching current $api_repository packages from archlinux.org..."

    while :; do
        response=$(curl --fail --silent --show-error \
            --retry 3 --retry-delay 2 \
            "$PACKAGE_API?repo=$api_repository&page=$page")

        if ! jq -e '.results | type == "array"' >/dev/null <<<"$response"; then
            echo "Unexpected Arch package API response for $api_repository page $page" >&2
            return 1
        fi

        jq -r '.results[] | .pkgname + "," + (.pkgbase // .pkgname)' \
            <<<"$response" >> "$packages_temp"

        page_count=$(jq -r '.results | length' <<<"$response")
        page_total=$(jq -r '.num_pages // empty' <<<"$response")
        echo "  page $page: $page_count package records"

        if (( page_count == 0 )); then
            break
        fi
        if [[ $page_total =~ ^[0-9]+$ ]] && (( page >= page_total )); then
            break
        fi
        if [[ -z $page_total ]] && (( page_count < 250 )); then
            break
        fi
        page=$((page + 1))
    done

    sort -u "$packages_temp" -o "$packages_temp"
    awk -F, '{print "https://gitlab.archlinux.org/archlinux/packaging/packages/" $2 ".git"}' \
        "$packages_temp" | sort -u > "$urls_temp"

    if [[ ! -s $packages_temp || ! -s $urls_temp ]]; then
        echo "No package data generated for $api_repository" >&2
        return 1
    fi

    mv -- "$packages_temp" "$output_dir/packages.txt"
    mv -- "$urls_temp" "$output_dir/clone_urls.txt"

    echo "Generated $output_name/packages.txt: $(wc -l < "$output_dir/packages.txt") records"
    echo "Generated $output_name/clone_urls.txt: $(wc -l < "$output_dir/clone_urls.txt") repositories"
}

fetch_repository Core core
fetch_repository Extra extra

echo "Core and Extra package lists are ready under: $OUTPUT_ROOT"
