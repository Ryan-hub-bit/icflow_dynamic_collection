#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

PACKAGE_URL=https://gitlab.archlinux.org/archlinux/packaging/packages/zydis.git
PACKAGE_REVISION=b24321b2f1041af560173d8036541fc8c376b849
BINARY_NAME=ZydisInfo

usage() {
    cat <<'EOF'
Usage: run_e1.sh --output OUTPUT_DIRECTORY [--sample zydis]

Build the pinned Arch Linux Zydis package with the custom LLVM, run its native
tests through Pin/MyPinTool, collect static and dynamic ICF ground truth, strip
the ZydisInfo ELF, construct its heterogeneous ACFG, and verify the result.
EOF
}

sample=zydis
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

[[ $sample == zydis ]] || {
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

for command in cmp cp file find git grep gzip jq makepkg mkdir mktemp mv objcopy \
    objdump readelf realpath sed sha256sum strip sudo tee timeout touch; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Required command is unavailable: $command" >&2
        exit 1
    }
done

for path in \
    "$LLVM_BUILD/bin/clang" \
    "$LLVM_BUILD/bin/clang++" \
    "$LLVM_BUILD/bin/llvm-nm" \
    "$LLVM_BUILD/bin/ld.lld" \
    "$PIN_ROOT/pin" \
    "$GRAPH_PYTHON"; do
    [[ -x $path ]] || { echo "Required executable is unavailable: $path" >&2; exit 1; }
done
[[ -f $PINTOOL ]] || { echo "MyPinTool is unavailable: $PINTOOL" >&2; exit 1; }

dynamic_scripts=/opt/icflownet-e1/dynamic
for path in \
    "$dynamic_scripts/collect_dynamic.sh" \
    "$dynamic_scripts/wrap_with_mypintool.sh" \
    "$dynamic_scripts/restore_wrapped_elfs.sh" \
    "$dynamic_scripts/.makepkg.conf"; do
    [[ -f $path ]] || { echo "Required package-collection input is unavailable: $path" >&2; exit 1; }
done

mkdir -p "$output"
output=$(realpath "$output")
if find "$output" -mindepth 1 -print -quit | grep -q .; then
    echo "Output directory must be empty: $output" >&2
    exit 1
fi

exec > >(tee "$output/run.log") 2>&1

static_scripts="$ICFLOWNET_ROOT/src/groundtruth/static"
static_root="$output/static"
binary_name=$BINARY_NAME
angrinfo="$static_root/angrinfo/$binary_name"
sourceinfo="$static_root/sourceinfo/$binary_name"
res="$static_root/res/$binary_name"
package_output="$output/package"
package_work=$(mktemp -d /tmp/icflownet-e1-zydis.XXXXXX)
trap 'rm -rf -- "$package_work"' EXIT

for path in \
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
    "$package_output" \
    "$static_root/binary" \
    "$angrinfo" \
    "$sourceinfo" \
    "$res"

echo "[1/9] Record the self-contained tool and package versions"
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
    printf 'package_url %s\n' "$PACKAGE_URL"
    printf 'package_revision %s\n' "$PACKAGE_REVISION"
} | tee "$output/versions.txt"

echo "[2/9] Fetch the pinned Arch Linux Zydis PKGBUILD"
package_repo="$package_work/zydis"
git init -q "$package_repo"
git -C "$package_repo" remote add origin "$PACKAGE_URL"
git -C "$package_repo" fetch --depth 1 origin "$PACKAGE_REVISION"
git -C "$package_repo" checkout --detach -q FETCH_HEAD
actual_revision=$(git -C "$package_repo" rev-parse HEAD)
[[ $actual_revision == "$PACKAGE_REVISION" ]]
printf '%s\n' "$PACKAGE_URL" > "$package_work/packages.txt"
printf '%s\n' "$PACKAGE_URL" > "$output/package-url.txt"
printf '%s\n' "$actual_revision" > "$output/package-revision.txt"

echo "[3/9] Compile Zydis and run its PKGBUILD tests through Pin/MyPinTool"
BUILD_TIMEOUT=1800 \
TEST_TIMEOUT=1800 \
WORK_ROOT="$package_work" \
MAKEPKG_CONF="$dynamic_scripts/.makepkg.conf" \
"$dynamic_scripts/collect_dynamic.sh" \
    "$package_work/packages.txt" "$package_output"

package_result="$package_output/zydis"
labeled_source="$package_result/artifacts/src/build/$binary_name"
dynamic_icall_source="$package_result/artifacts/src/build/${binary_name}.orig_icall.json"
dynamic_ijump_source="$package_result/artifacts/src/build/${binary_name}.orig_ijump.json"

for path in \
    "$labeled_source" \
    "$dynamic_icall_source" \
    "$dynamic_ijump_source" \
    "$package_result/wrapped-executions.tsv" \
    "$package_result/test.log"; do
    [[ -f $path ]] || { echo "Required Zydis result is unavailable: $path" >&2; exit 1; }
done
[[ -s $package_result/wrapped-executions.tsv ]]
grep -q '100% tests passed' "$package_result/test.log"

echo "[4/9] Verify the labeled ZydisInfo ELF and extract static ground truth"
cp "$labeled_source" "$output/labeled/$binary_name"
cp "$dynamic_icall_source" "$output/dynamic/${binary_name}_icall.json"
cp "$dynamic_ijump_source" "$output/dynamic/${binary_name}_ijump.json"
file "$output/labeled/$binary_name" | tee "$output/proof/labeled-file.txt"
readelf -h "$output/labeled/$binary_name" > "$output/proof/labeled-elf-header.txt"
grep -Eq 'Type:[[:space:]]+EXEC' "$output/proof/labeled-elf-header.txt"
objdump -t "$output/labeled/$binary_name" > "$output/proof/labeled-symbols.txt"
grep -q -- '-t-' "$output/proof/labeled-symbols.txt"
"$GRAPH_PYTHON" "$static_scripts/parsebylabel.py" \
    "$output/labeled/$binary_name" "$sourceinfo"
jq -e 'type == "object"' "$sourceinfo/${binary_name}_icallinstocallee.json" >/dev/null
jq -e 'type == "object" and length > 0 and ([.[] | length] | add) > 0' \
    "$sourceinfo/${binary_name}_jmptable.json" >/dev/null
jq -e 'type == "object" and length > 0 and ([.[] | length] | add) > 0' \
    "$output/dynamic/${binary_name}_ijump.json" >/dev/null

echo "[5/9] Strip a copy and prove that its .text bytes are unchanged"
objcopy --dump-section .text="$output/proof/text-before.bin" \
    "$output/labeled/$binary_name"
cp "$output/labeled/$binary_name" "$output/stripped/$binary_name"
strip --strip-all "$output/stripped/$binary_name"
objcopy --dump-section .text="$output/proof/text-after.bin" \
    "$output/stripped/$binary_name"
cmp "$output/proof/text-before.bin" "$output/proof/text-after.bin"
sha256sum "$output/proof/text-before.bin" > "$output/proof/text-before.sha256"
sha256sum "$output/proof/text-after.bin" > "$output/proof/text-after.sha256"
file "$output/stripped/$binary_name" | tee "$output/proof/stripped-file.txt"
grep -q 'stripped' "$output/proof/stripped-file.txt"
readelf -S "$output/stripped/$binary_name" > "$output/proof/stripped-sections.txt"
if grep -q '[.]symtab' "$output/proof/stripped-sections.txt"; then
    echo "The stripped graph input still has a symbol table" >&2
    exit 1
fi

echo "[6/9] Construct the heterogeneous ACFG from the stripped ZydisInfo ELF"
cp "$output/stripped/$binary_name" "$static_root/binary/$binary_name"
PALMTREE_USE_CUDA=0 "$GRAPH_PYTHON" "$static_scripts/angrcfginfo.py" \
    "$static_root/binary/$binary_name" \
    "$angrinfo" \
    "$sourceinfo" \
    "$res" \
    "$static_root" \
    0

run_static() {
    PALMTREE_USE_CUDA=0 "$GRAPH_PYTHON" "$@"
}

echo "[7/9] Complete static return and index postprocessing"
touch "$static_root/gttobin.json"
run_static "$static_scripts/processdcallreturn.py" "$binary_name" "$angrinfo" "$res"
run_static "$static_scripts/processicallreturn.py" "$binary_name" "$angrinfo" "$sourceinfo" "$res"
run_static "$static_scripts/getfuncascalleetoicallins.py" "$binary_name" "$sourceinfo"
run_static "$static_scripts/combinefuncascalleetocallins.py" "$binary_name" "$angrinfo" "$sourceinfo"
run_static "$static_scripts/gettcfunctocallee.py" "$binary_name" "$angrinfo" "$sourceinfo"
run_static "$static_scripts/gettcfuncallpathret.py" "$binary_name" "$angrinfo" "$sourceinfo"
run_static "$static_scripts/getrettoaftercallfortc.py" "$binary_name" "$angrinfo" "$res"
run_static "$static_scripts/mergeret.py" \
    "$binary_name" "$res" "$static_root/binary/$binary_name" "$static_root/gttobin.json"
mv "$angrinfo/${binary_name}_nodelookup.json" "$res/"
run_static "$static_scripts/getindextobin.py" "$static_root"

echo "[8/9] Verify static GT covers the dynamically observed ICF pairs"
echo "[9/9] Validate the stripped-binary DGL graph"
PALMTREE_USE_CUDA=0 "$GRAPH_PYTHON" "$SCRIPT_DIR/verify_e1.py" "$output"

echo "E1 PASS: Zydis static GT, dynamic GT, and stripped-binary heterogeneous ACFG verified"
