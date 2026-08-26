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

## Experimental module: LLM-generated supplementary tests

The paper's LLM augmentation is separate from the two-package functional test
below. Its primary goal is to obtain as many unique dynamically observed
indirect-call pairs as possible. A pair is the combination of an indirect call
site and the callee target reached at runtime, as recorded in `*_icall.json`.
The generated tests should add pairs that the project's native tests did not
reach; line coverage and the number of generated tests are secondary metrics.
The experimental `llm_test_generation` module selects a bounded source
snapshot, asks an OpenAI model to propose supplementary tests, and writes the
result to a separate directory. It never runs generated code or edits the input
project.

The current prebuilt `docker-v1` image predates this experimental branch. From
inside either the prebuilt container or a source-built container, fetch it with:

```bash
cd /workspace/icflow_dynamic_collection
git fetch origin codex/llm-test-generation
git switch -c codex/llm-test-generation FETCH_HEAD
```

### Use each researcher's own OpenAI API key

Create an API key in the researcher's own OpenAI project. Enter it inside the
container without putting it in the repository, Dockerfile, command history,
or generated output:

```bash
read -rsp "OpenAI API key: " OPENAI_API_KEY
export OPENAI_API_KEY
echo
```

The module reads `OPENAI_API_KEY` only from the process environment, never
writes it to disk, and sends API requests with `store: false`. The default is
`gpt-5.6-sol`; set `OPENAI_MODEL` or pass `--model` to use another model
available to that account:

```bash
export OPENAI_MODEL=gpt-5.6-sol
```

### Inspect the source selection and prompt first

Run a dry-run before submitting project code. This performs no API request:

```bash
cd /workspace/icflow_dynamic_collection
python3 -m llm_test_generation.generate_tests /path/to/project \
  --dry-run \
  --prompt-output /data/project-llm-prompt.md
```

Review `/data/project-llm-prompt.md`. The selector excludes common build,
dependency, VCS, and secret-file locations and enforces per-file and total
context limits. This is a safety aid, not a guarantee that source files contain
no sensitive information. Only submit code that the researcher is authorized
to share with the API.

### Generate supplementary tests

The reusable prompt is
[`llm_test_generation/prompt_template.md`](llm_test_generation/prompt_template.md).
It asks for deterministic tests that maximize unique indirect call-site/target
pairs by varying callbacks, function-pointer targets, virtual implementations,
handlers, parser states, error paths, and boundary conditions while reusing the
project's native test framework. Tests likely to repeat the same pairs should
be avoided.

Example for a CMake project with an optional coverage report:

```bash
python3 -m llm_test_generation.generate_tests /path/to/project \
  --output-dir /data/llm-generated-tests/project-name \
  --test-count 12 \
  --existing-test-command "ctest --test-dir build --output-on-failure" \
  --coverage-report /path/to/coverage-summary.txt \
  --extra-instructions \
    "Maximize new indirect-call pairs. Prioritize unseen callback targets, virtual implementations, parser handlers, and state transitions."
```

If no coverage report is available, omit `--coverage-report`. The output
directory contains the proposed test files, `generation.json`, and
`generation_metadata.json`, including token usage when returned by the API.
Existing non-empty output directories are rejected unless `--force` is given.

Review every generated file before compiling or running it. To use approved
tests for ICFlow collection:

1. Copy the approved files into the unpacked project's test tree.
2. Add them to the project's test build and its `check()` command without
   modifying unrelated production behavior.
3. Confirm the native and generated tests pass normally.
4. Run the native tests under MyPinTool to establish the baseline set of unique
   indirect call-site/target pairs.
5. Run the approved generated tests under MyPinTool and compare the union of
   pairs against that baseline. The main result is the number of new unique
   pairs in `*_icall.json`, not merely whether the JSON file is non-empty.
6. Run `collect_dynamic.sh` on the package repository. During `makepkg check()`,
   the collector wraps test ELF executables with MyPinTool and saves the
   resulting binary plus `*_icall.json` and `*_ijump.json` artifacts.

Source files and coverage text selected by this module are sent to the OpenAI
Responses API. Usage is billed to the API project associated with the key. See
the official [Responses API reference](https://developers.openai.com/api/reference/cli/resources/responses/methods/create)
and [model guide](https://developers.openai.com/api/docs/models).

## Functional test only: verify MyPinTool with `testlink`

The `testlink`, Zydis, and Expat commands in the next two sections are small
functional tests. They verify that the compiler, Pin instrumentation, static
binary extraction, and dynamic JSON collection work. They do **not** generate
the complete Core or Extra dataset.

`testlink.cpp` contains an indirect function call and provides a quick
end-to-end binary/JSON check:

```bash
cd /workspace/icflow_dynamic_collection

"$LLVM_BUILD/bin/clang++" -O0 -g -fno-pie -no-pie \
  testlink.cpp -o testlink
rm -f testlink_icall.json testlink_ijump.json
"$PIN_ROOT/pin" -t "$PINTOOL" -- "$PWD/testlink"

jq -e 'type == "object" and length > 0' testlink_icall.json
jq . testlink_icall.json
jq . testlink_ijump.json
```

An empty `{}` is valid when that type of indirect control flow was not
observed during the test.

## Functional test only: build two sample packages

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

## Full pipeline: generate and process complete Core or Extra lists

This is the full dataset pipeline:

1. Run `collect_arch_git.sh` to generate the complete current Core and Extra
   repository lists.
2. Run `buildall_timeout.sh` on a complete list to build and extract the static
   ELF binaries.
3. Run `collect_dynamic.sh` on the same list to execute package tests through
   MyPinTool and collect the dynamic `*_icall.json` and `*_ijump.json` ground
   truth.

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
