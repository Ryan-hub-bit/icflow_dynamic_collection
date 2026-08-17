# Reproduce ICFlow Dynamic Collection

Use either the prebuilt image or compile the toolchain yourself. Both choices
run on an x86-64 Linux Docker host and use the non-root `icflow` user required
by `makepkg`.

## Choice A: download the ready-to-run image

Download the image and its checksum from the
[`docker-v1` release](https://github.com/Ryan-hub-bit/icflow_dynamic_collection/releases/tag/docker-v1):

```bash
curl -LO https://github.com/Ryan-hub-bit/icflow_dynamic_collection/releases/download/docker-v1/icflow-dynamic-collection-amd64.tar.gz
curl -LO https://github.com/Ryan-hub-bit/icflow_dynamic_collection/releases/download/docker-v1/icflow-dynamic-collection-amd64.tar.gz.sha256
sha256sum -c icflow-dynamic-collection-amd64.tar.gz.sha256
docker load < icflow-dynamic-collection-amd64.tar.gz

docker volume create icflow-data
docker run -it --init \
  --name icflow \
  --cap-add=SYS_PTRACE \
  --security-opt seccomp=unconfined \
  -v icflow-data:/data \
  icflow-dynamic-collection:prebuilt
```

LLVM, MyPinTool, and their environment variables are already configured in
this image. Generate current Core and Extra package lists immediately:

```bash
cd /workspace/icflow_dynamic_collection
./collect_arch_git.sh

wc -l "$HOME/arch_packages/core/clone_urls.txt"
wc -l "$HOME/arch_packages/extra/clone_urls.txt"
```

To enter the same container later:

```bash
docker start -ai icflow
# If it is already running:
docker exec -it icflow bash
```

## Choice B: build the image and compile everything

Clone the repository and build the Arch Linux environment:

```bash
git clone https://github.com/Ryan-hub-bit/icflow_dynamic_collection.git
cd icflow_dynamic_collection

docker build \
  --build-arg USER_ID="$(id -u)" \
  --build-arg GROUP_ID="$(id -g)" \
  -t icflow-arch .

docker run -it --init \
  --name icflow \
  --cap-add=SYS_PTRACE \
  --security-opt seccomp=unconfined \
  -v icflow-data:/data \
  icflow-arch
```

Run the remaining commands inside the container.

### Compile the custom LLVM

```bash
git clone https://github.com/Ryan-hub-bit/llvm-project.git "$HOME/llvm-project"
cd "$HOME/llvm-project"

cmake -S llvm -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_TARGETS_TO_BUILD=X86

cmake --build build --target clang llvm-nm lld -- -j"$(nproc)"

./build/bin/clang --version
./build/bin/llvm-nm --version
./build/bin/ld.lld --version
```

### Compile MyPinTool

```bash
cd /workspace/icflow_dynamic_collection/Mypintool/source/tools/MyPinTool
make clean
make obj-intel64/MyPinTool.so -j"$(nproc)"

cd /workspace/icflow_dynamic_collection
export LLVM_BUILD="$HOME/llvm-project/build"
export PIN_ROOT="$PWD/Mypintool"
export PINTOOL="$PIN_ROOT/source/tools/MyPinTool/obj-intel64/MyPinTool.so"
export MAKEPKG_CONF="$PWD/.makepkg.conf"
```

## Verify MyPinTool with `testlink`

`testlink.cpp` contains an indirect function call and provides a quick
end-to-end binary/JSON check:

```bash
cd /workspace/icflow_dynamic_collection

"$LLVM_BUILD/bin/clang++" -O0 -g -fno-pie -no-pie \
  testlink.cpp -o testlink
rm -f testlink_icall.json testlink_ijump.json
"$PIN_ROOT/pin" -t "$PINTOOL" -- "$PWD/testlink"

test -s testlink_icall.json
jq . testlink_icall.json
jq . testlink_ijump.json
```

An empty `{}` is valid when that type of indirect control flow was not
observed during the test.

## Build the two verified sample packages

`test-packages.txt` contains
[Zydis](https://gitlab.archlinux.org/archlinux/packaging/packages/zydis) and
[Expat](https://gitlab.archlinux.org/archlinux/packaging/packages/expat).

Build their static binaries:

```bash
cd /workspace/icflow_dynamic_collection

ARCH_PACKAGES_ROOT=/data/icflow-static \
MAX_JOBS=2 \
BUILD_TIMEOUT=1800 \
./buildall_timeout.sh sample "$PWD/test-packages.txt"

find /data/icflow-static/elf_outputs -type f -exec file {} + | grep ELF
cat /data/icflow-static/elf_map.txt
```

Collect their dynamic ICFlow ground truth:

```bash
BUILD_TIMEOUT=1800 TEST_TIMEOUT=1800 \
WORK_ROOT=/data/icflow-sample-work \
./collect_dynamic.sh "$PWD/test-packages.txt" /data/icflow-dynamic
```

Verify the binary/ground-truth pairs:

```bash
find /data/icflow-dynamic -name wrapped-executions.tsv -size +0 -print
find /data/icflow-dynamic \
  -type f \( -name '*_icall.json' -o -name '*_ijump.json' \) \
  -print0 | while IFS= read -r -d '' result; do
    jq -e 'length > 0' "$result" >/dev/null && echo "$result"
  done

find /data/icflow-dynamic -path '*/artifacts/*' -type f -exec file {} + \
  | grep ELF
```

The validated run built both packages and copied five static ELF files. Zydis
produced ICFlow for `ZydisInfo`; Expat produced ICFlow for `runtests`. Their
associated ELF files and `*_icall.json`/`*_ijump.json` files were preserved
under each package's `artifacts/` directory.

## Generate and process complete Core or Extra lists

Generate current lists from the Arch package API:

```bash
cd /workspace/icflow_dynamic_collection
./collect_arch_git.sh
```

Build static binaries for Core or Extra:

```bash
ARCH_PACKAGES_ROOT=/data/static-core \
BUILD_TIMEOUT=1800 \
./buildall_timeout.sh core "$HOME/arch_packages/core/clone_urls.txt"

ARCH_PACKAGES_ROOT=/data/static-extra \
BUILD_TIMEOUT=1800 \
./buildall_timeout.sh extra "$HOME/arch_packages/extra/clone_urls.txt"
```

Collect dynamic ICFlow for Core or Extra:

```bash
WORK_ROOT=/data/work-core \
./collect_dynamic.sh \
  "$HOME/arch_packages/core/clone_urls.txt" /data/dynamic-core

WORK_ROOT=/data/work-extra \
./collect_dynamic.sh \
  "$HOME/arch_packages/extra/clone_urls.txt" /data/dynamic-extra
```

Core and especially Extra require substantial time, network bandwidth, and
disk space. The scripts record processed URLs so interrupted collection can be
resumed with the same command.

## Copy results from the Docker volume

Find the volume location on the host:

```bash
docker volume inspect icflow-data
```

Or copy a result directory directly from the container:

```bash
docker cp icflow:/data/icflow-static ./icflow-static
docker cp icflow:/data/icflow-dynamic ./icflow-dynamic
```
