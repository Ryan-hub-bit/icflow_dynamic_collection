#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "Usage: PIN_ROOT=/path/to/pin [PINTOOL=/path/to/MyPinTool.so] $0 DIRECTORY"
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

: "${PIN_ROOT:?PIN_ROOT must point to the Intel Pin kit root}"

PIN_ROOT=$(realpath "$PIN_ROOT")
PINTOOL=${PINTOOL:-"$PIN_ROOT/source/tools/MyPinTool/obj-intel64/MyPinTool.so"}
PINTOOL=$(realpath "$PINTOOL")
TARGET_DIR=$(realpath "$1")
WRAP_LOG=${WRAP_LOG:-/tmp/mypintool-wrapped-elfs.log}
MARKER="# mypintool-wrapper-v1"

if [[ ! -x "$PIN_ROOT/pin" ]]; then
    echo "Pin launcher is not executable: $PIN_ROOT/pin" >&2
    exit 1
fi

if [[ ! -f "$PINTOOL" ]]; then
    echo "MyPinTool shared object does not exist: $PINTOOL" >&2
    exit 1
fi

mkdir -p "$(dirname "$WRAP_LOG")"
touch "$WRAP_LOG"

wrapped=0

while IFS= read -r -d '' binary; do
    [[ $binary == *.orig ]] && continue
    [[ $binary == *.so || $binary == *.so.* ]] && continue
    [[ $(basename "$binary") == build_script_-* ]] && continue

    file_description=$(/usr/bin/file -b "$binary")
    [[ $file_description == ELF* && $file_description == *executable* ]] || continue

    original="${binary}.orig"
    temporary_wrapper="${binary}.mypintool-wrapper.$$"

    if [[ -f "$original" ]]; then
        if grep -Fqx "$MARKER" "$binary" 2>/dev/null; then
            continue
        fi
        echo "Refusing to overwrite an existing backup: $original" >&2
        continue
    fi

    mv -- "$binary" "$original"

    if {
        printf '#!/usr/bin/env bash\n'
        printf '%s\n' "$MARKER"
        printf 'printf "%%s\\t%%s\\n" "$0" "$*" >> %q\n' "$WRAP_LOG"
        printf 'exec %q -t %q -- %q "$@"\n' "$PIN_ROOT/pin" "$PINTOOL" "$original"
    } > "$temporary_wrapper"; then
        chmod +x "$temporary_wrapper"
        mv -- "$temporary_wrapper" "$binary"
        echo "Wrapped: $binary"
        wrapped=$((wrapped + 1))
    else
        rm -f -- "$temporary_wrapper"
        mv -- "$original" "$binary"
        echo "Failed to create wrapper: $binary" >&2
        exit 1
    fi
done < <(/usr/bin/find "$TARGET_DIR" -type f -executable ! -path '*/pkg/*' -print0)

echo "Wrapped ELF executables: $wrapped"
