# Reproduce ICFlow Dynamic Collection

This repository combines the required scripts and `.makepkg.conf` from
[`arch_scripts`](https://github.com/Ryan-hub-bit/arch_scripts) with the Intel
Pin kit and JSON-producing `MyPinTool`. The copied `.makepkg.conf` keeps
`CFLAGS="-O3"` commented for the baseline run. Generated Core/Extra lists and
build results are not stored in Git.

The workflow below was designed for an x86-64 Linux host with Docker. Package
builds run as the non-root `icflow` user because `makepkg` refuses to run as
root.

## 1. Build and enter the Docker container

```bash
git clone --branch codex/arch-scripts-docker-compat \
  https://github.com/Ryan-hub-bit/icflow_dynamic_collection.git
cd icflow_dynamic_collection

docker build \
  --build-arg USER_ID="$(id -u)" \
  --build-arg GROUP_ID="$(id -g)" \
  -t icflow-arch .

docker run -it --init \
  --name icflow \
  --cap-add=SYS_PTRACE \
  --security-opt seccomp=unconfined \
  icflow-arch
```

After leaving the shell, enter the same container again with:

```bash
docker start -ai icflow
```

If it is already running, use `docker exec -it icflow bash`. The image also
contains `vim`, `jq`, the Arch build tools, CMake, and Ninja.

## 2. Compile the custom LLVM inside Docker

Run these commands inside the container:

```bash
git clone https://github.com/Ryan-hub-bit/llvm-project.git "$HOME/llvm-project"
cd "$HOME/llvm-project"

cmake -S llvm -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_TARGETS_TO_BUILD=X86

cmake --build build --target clang llvm-nm lld -- -j"$(nproc)"
```

Verify the toolchain:

```bash
"$HOME/llvm-project/build/bin/clang" --version
"$HOME/llvm-project/build/bin/llvm-nm" --version
"$HOME/llvm-project/build/bin/ld.lld" --version
```

## 3. Compile and smoke-test MyPinTool

The small [`testlink.cpp`](testlink.cpp) program contains an indirect function
call and provides a quick end-to-end Pin/JSON check.

```bash
cd /workspace/icflow_dynamic_collection/Mypintool/source/tools/MyPinTool
make clean
make obj-intel64/MyPinTool.so -j"$(nproc)"

cd /workspace/icflow_dynamic_collection
export LLVM_BUILD="$HOME/llvm-project/build"
export PIN_ROOT="$PWD/Mypintool"
export PINTOOL="$PIN_ROOT/source/tools/MyPinTool/obj-intel64/MyPinTool.so"
export MAKEPKG_CONF="$PWD/.makepkg.conf"

"$LLVM_BUILD/bin/clang++" -O0 -g -fno-pie -no-pie \
  testlink.cpp -o testlink
rm -f testlink_icall.json testlink_ijump.json
"$PIN_ROOT/pin" -t "$PINTOOL" -- "$PWD/testlink"

test -s testlink_icall.json
jq . testlink_icall.json
```

`testlink_icall.json` must contain at least one source address mapped to the
indirectly called target. `testlink_ijump.json` may be empty because this small
program is intended to test an indirect call.

## 4. Build sample Arch packages and collect static binaries

`test-packages.txt` contains two verified official Arch package repositories:
[Zydis](https://gitlab.archlinux.org/archlinux/packaging/packages/zydis) and
[Expat](https://gitlab.archlinux.org/archlinux/packaging/packages/expat). Run the copied and Docker-adapted
`buildall_timeout.sh` on that list:

```bash
cd /workspace/icflow_dynamic_collection
export LLVM_BUILD="$HOME/llvm-project/build"
export MAKEPKG_CONF="$PWD/.makepkg.conf"

ARCH_PACKAGES_ROOT="$HOME/icflow-static" \
MAX_JOBS=2 \
BUILD_TIMEOUT=1800 \
./buildall_timeout.sh sample "$PWD/test-packages.txt"

find "$HOME/icflow-static/elf_outputs" -type f -exec file {} + | grep ELF
cat "$HOME/icflow-static/elf_map.txt"
```

An `ELF` line and a corresponding entry in `elf_map.txt` confirm that the
static package binary was built and copied successfully.

## 5. Collect dynamic ICFlow ground truth

Use a separate output directory so the static and dynamic results are easy to
compare:

```bash
cd /workspace/icflow_dynamic_collection
export LLVM_BUILD="$HOME/llvm-project/build"
export PIN_ROOT="$PWD/Mypintool"
export PINTOOL="$PIN_ROOT/source/tools/MyPinTool/obj-intel64/MyPinTool.so"
export MAKEPKG_CONF="$PWD/.makepkg.conf"

BUILD_TIMEOUT=1800 TEST_TIMEOUT=1800 \
WORK_ROOT="$HOME/icflow-work" \
./collect_dynamic.sh "$PWD/test-packages.txt" "$HOME/icflow-dynamic"
```

Verify that package tests really launched through Pin and that a binary/ground
truth pair exists:

```bash
find "$HOME/icflow-dynamic" -name wrapped-executions.tsv -size +0 -print
find "$HOME/icflow-dynamic" \
  -type f \( -name '*_icall.json' -o -name '*_ijump.json' \) \
  -print0 | while IFS= read -r -d '' result; do
    jq -e 'length > 0' "$result" >/dev/null && echo "$result"
  done

find "$HOME/icflow-dynamic" -path '*/artifacts/*' -type f -exec file {} + \
  | grep ELF
```

For every JSON result, the collector also copies its associated ELF into the
same package's `artifacts/` tree. A non-empty `wrapped-executions.tsv` proves a
package test executed an instrumented binary; non-empty `*_icall.json` or
`*_ijump.json` files are the dynamic ICFlow ground truth.

This workflow was validated from a clean Docker build with custom LLVM/Clang
20.0.0git. The static sample built 2/2 packages and copied five ELF files.
Zydis produced ICFlow for `ZydisInfo`, and Expat produced ICFlow for `runtests`;
both associated ELF files were preserved under `artifacts/`.

## 6. Generate the complete Core and Extra lists

The repository deliberately does not contain large, stale `core/` and `extra/`
snapshots. Generate current lists from the Arch package API when needed:

```bash
./collect_arch_git.sh "$HOME/arch_packages"

wc -l "$HOME/arch_packages/core/clone_urls.txt"
wc -l "$HOME/arch_packages/extra/clone_urls.txt"
```

Then pass either list to the static or dynamic command. Start with the two
sample packages because collecting all of Extra requires substantial time,
network bandwidth, and disk space.

## 7. Copy results or export the validated image

From the Ubuntu host:

```bash
docker cp icflow:/home/icflow/icflow-static ./icflow-static
docker cp icflow:/home/icflow/icflow-dynamic ./icflow-dynamic

# Optional: preserve compiled LLVM and MyPinTool in a reusable image.
docker commit icflow icflow-arch:validated
docker save icflow-arch:validated | gzip > icflow-arch-validated.tar.gz
```

Another x86-64 Linux host can load it with:

```bash
gunzip -c icflow-arch-validated.tar.gz | docker load
docker run -it --init --cap-add=SYS_PTRACE \
  --security-opt seccomp=unconfined icflow-arch:validated
```
