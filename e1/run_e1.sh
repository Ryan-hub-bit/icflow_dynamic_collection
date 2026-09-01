#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
    cat <<'EOF'
Usage: run_e1.sh --output OUTPUT_DIRECTORY [--sample testlink]

Build one custom-LLVM binary, collect static and dynamic ICF ground truth,
strip the graph input, construct its heterogeneous ACFG, and verify the result.

The output directory must not already contain files. The only supported sample
is testlink, which is included in the dynamic-collection image.
EOF
}

sample=testlink
output=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sample)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            sample=$2
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            output=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ $sample == testlink ]] || {
    echo "Unsupported sample: $sample" >&2
    exit 2
}
[[ -n $output ]] || {
    echo "--output is required" >&2
    usage >&2
    exit 2
}

: "${LLVM_BUILD:?LLVM_BUILD is required}"
: "${PIN_ROOT:?PIN_ROOT is required}"
: "${PINTOOL:?PINTOOL is required}"
: "${ICFLOWNET_ROOT:?ICFLOWNET_ROOT is required}"
: "${GRAPH_PYTHON:?GRAPH_PYTHON is required}"

for command in cmp cp file find grep gzip jq mkdir mv objcopy objdump \
    readelf realpath sed sha256sum strip tee touch; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Required command is unavailable: $command" >&2
        exit 1
    }
done

for path in \
    "$LLVM_BUILD/bin/clang++" \
    "$LLVM_BUILD/bin/llvm-nm" \
    "$LLVM_BUILD/bin/ld.lld" \
    "$PIN_ROOT/pin" \
    "$GRAPH_PYTHON"; do
    [[ -x $path ]] || { echo "Required executable is unavailable: $path" >&2; exit 1; }
done
[[ -f $PINTOOL ]] || { echo "MyPinTool is unavailable: $PINTOOL" >&2; exit 1; }

mkdir -p "$output"
output=$(realpath "$output")
if find "$output" -mindepth 1 -print -quit | grep -q .; then
    echo "Output directory must be empty: $output" >&2
    exit 1
fi

exec > >(tee "$output/run.log") 2>&1

source_file="$PIN_ROOT/../testlink.cpp"
static_scripts="$ICFLOWNET_ROOT/src/groundtruth/static"
static_root="$output/static"
binary_name=testlink
angrinfo="$static_root/angrinfo/$binary_name"
sourceinfo="$static_root/sourceinfo/$binary_name"
res="$static_root/res/$binary_name"

for path in \
    "$source_file" \
    "$static_scripts/parsebylabel.py" \
    "$static_scripts/angrcfginfo.py" \
    "$static_scripts/palmtree/vocab" \
    "$static_scripts/palmtree/transformer.ep19"; do
    [[ -f $path ]] || { echo "Required E1 input is unavailable: $path" >&2; exit 1; }
done

mkdir -p \
    "$output/labeled" \
    "$output/dynamic" \
    "$output/stripped" \
    "$output/proof" \
    "$static_root/binary" \
    "$angrinfo" \
    "$sourceinfo" \
    "$res"

echo "[1/8] Record the self-contained tool versions"
{
    "$LLVM_BUILD/bin/clang++" --version | sed -n '1p'
    "$LLVM_BUILD/bin/llvm-nm" --version | sed -n '1p'
    "$LLVM_BUILD/bin/ld.lld" --version | sed -n '1p'
    "$GRAPH_PYTHON" - <<'PY'
import angr
import dgl
import torch
print(f"angr {angr.__version__}")
print(f"DGL {dgl.__version__}")
print(f"PyTorch {torch.__version__}")
PY
} | tee "$output/versions.txt"

echo "[2/8] Compile the labeled non-PIE testlink ELF"
"$LLVM_BUILD/bin/clang++" \
    -O0 -g -fno-pie -no-pie \
    --ld-path="$LLVM_BUILD/bin/ld.lld" \
    "$source_file" \
    -o "$output/labeled/testlink"
file "$output/labeled/testlink" | tee "$output/proof/labeled-file.txt"
readelf -h "$output/labeled/testlink" > "$output/proof/labeled-elf-header.txt"
grep -Eq 'Type:[[:space:]]+EXEC' "$output/proof/labeled-elf-header.txt"
objdump -t "$output/labeled/testlink" > "$output/proof/labeled-symbols.txt"
grep -q -- '-t-' "$output/proof/labeled-symbols.txt"

echo "[3/8] Extract label-derived static ground truth before stripping"
"$GRAPH_PYTHON" "$static_scripts/parsebylabel.py" \
    "$output/labeled/testlink" "$sourceinfo"
jq -e 'type == "object" and length == 1 and ([.[] | length] | add) == 2' \
    "$sourceinfo/testlink_icallinstocallee.json" >/dev/null

echo "[4/8] Run both indirect-call paths through Pin/MyPinTool"
cp "$output/labeled/testlink" "$output/dynamic/testlink"
"$PIN_ROOT/pin" -t "$PINTOOL" -- "$output/dynamic/testlink"
"$PIN_ROOT/pin" -t "$PINTOOL" -- "$output/dynamic/testlink" alternate
jq -e 'type == "object" and length == 1 and ([.[] | length] | add) == 2' \
    "$output/dynamic/testlink_icall.json" >/dev/null
jq -e 'type == "object"' "$output/dynamic/testlink_ijump.json" >/dev/null

echo "[5/8] Strip a copy and prove that its .text bytes are unchanged"
objcopy --dump-section .text="$output/proof/text-before.bin" \
    "$output/labeled/testlink"
cp "$output/labeled/testlink" "$output/stripped/testlink"
strip --strip-all "$output/stripped/testlink"
objcopy --dump-section .text="$output/proof/text-after.bin" \
    "$output/stripped/testlink"
cmp "$output/proof/text-before.bin" "$output/proof/text-after.bin"
sha256sum "$output/proof/text-before.bin" > "$output/proof/text-before.sha256"
sha256sum "$output/proof/text-after.bin" > "$output/proof/text-after.sha256"
file "$output/stripped/testlink" | tee "$output/proof/stripped-file.txt"
grep -q 'stripped' "$output/proof/stripped-file.txt"
readelf -S "$output/stripped/testlink" > "$output/proof/stripped-sections.txt"
if grep -q '[.]symtab' "$output/proof/stripped-sections.txt"; then
    echo "The stripped graph input still has a symbol table" >&2
    exit 1
fi

echo "[6/8] Construct the heterogeneous ACFG from the stripped copy"
cp "$output/stripped/testlink" "$static_root/binary/testlink"
PALMTREE_USE_CUDA=0 "$GRAPH_PYTHON" "$static_scripts/angrcfginfo.py" \
    "$static_root/binary/testlink" \
    "$angrinfo" \
    "$sourceinfo" \
    "$res" \
    "$static_root" \
    0

run_static() {
    PALMTREE_USE_CUDA=0 "$GRAPH_PYTHON" "$@"
}

echo "[7/8] Complete return and index postprocessing"
touch "$static_root/gttobin.json"
run_static "$static_scripts/processdcallreturn.py" "$binary_name" "$angrinfo" "$res"
run_static "$static_scripts/processicallreturn.py" "$binary_name" "$angrinfo" "$sourceinfo" "$res"
run_static "$static_scripts/getfuncascalleetoicallins.py" "$binary_name" "$sourceinfo"
run_static "$static_scripts/combinefuncascalleetocallins.py" "$binary_name" "$angrinfo" "$sourceinfo"
run_static "$static_scripts/gettcfunctocallee.py" "$binary_name" "$angrinfo" "$sourceinfo"
run_static "$static_scripts/gettcfuncallpathret.py" "$binary_name" "$angrinfo" "$sourceinfo"
run_static "$static_scripts/getrettoaftercallfortc.py" "$binary_name" "$angrinfo" "$res"
run_static "$static_scripts/mergeret.py" \
    "$binary_name" "$res" "$static_root/binary/testlink" "$static_root/gttobin.json"
mv "$angrinfo/testlink_nodelookup.json" "$res/"
run_static "$static_scripts/getindextobin.py" "$static_root"

echo "[8/8] Compare GT pairs and validate the DGL graph"
PALMTREE_USE_CUDA=0 "$GRAPH_PYTHON" "$SCRIPT_DIR/verify_e1.py" "$output"

echo "E1 PASS: static GT, dynamic GT, and stripped-binary heterogeneous ACFG verified for testlink"
