#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "Usage: $0 DIRECTORY"
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

TARGET_DIR=$(realpath "$1")
MARKER="# mypintool-wrapper-v1"
restored=0

while IFS= read -r -d '' original; do
    wrapper=${original%.orig}

    if [[ -f "$wrapper" ]] && grep -Fqx "$MARKER" "$wrapper" 2>/dev/null; then
        rm -f -- "$wrapper"
        mv -- "$original" "$wrapper"
        echo "Restored: $wrapper"
        restored=$((restored + 1))
    fi
done < <(/usr/bin/find "$TARGET_DIR" -type f -name '*.orig' -print0)

echo "Restored ELF executables: $restored"
