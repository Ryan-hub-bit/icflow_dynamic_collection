# ICFlow Dynamic Collection

This repository collects dynamically observed indirect control flow while
running Arch Linux package tests. Test ELF executables are launched through
Intel Pin and `MyPinTool`.

Only the dynamic collection workflow was retained from `arch_scripts`. The
old static batch-build scripts, package and URL snapshots, statistics helpers,
duplicate implementations, and hard-coded personal paths were removed.

The Pin kit from
[Ryan-hub-bit/Mypintool](https://github.com/Ryan-hub-bit/Mypintool) is vendored
under `Mypintool/` without its original `.git` directory, so no separate Pin
download is required after cloning this repository. The bundled kit is based on
commit
[`bf574a6`](https://github.com/Ryan-hub-bit/Mypintool/commit/bf574a6437adad6e57be106f92b4f541359638cf).
The default `MyPinTool` source has been synchronized with the JSON-producing
ICFlow implementation. It writes `*_icall.json` and `*_ijump.json` files next
to the target ELF. Stale prebuilt `.o` and `.so` files are intentionally
excluded; rebuild the tool as described below.

## Environment and required order

This repository can be inspected or edited on any Linux distribution, but
**dynamic collection must run on an Arch Linux x86-64 machine**. Prepare the
environment in this order:

1. Prepare an Arch Linux machine and install the build dependencies.
2. First build the custom `Ryan-hub-bit/llvm-project`.
3. Then build the `MyPinTool` bundled with this repository.
4. Finally run the collection script. Package test executables will be launched
   as `pin -t MyPinTool.so -- <test>.orig ...` instead of being executed
   directly.

Do not run the collection script as `root`; `makepkg` also refuses to run as
`root`.

## 1. Install Arch Linux dependencies

```bash
sudo pacman -Syu --needed base-devel cmake ninja git python file
```

`makepkg --syncdeps` may install additional dependencies declared by each
`PKGBUILD`, so working `sudo` access and a network connection are required
during collection.

## 2. Build the custom LLVM first

You must use
[Ryan-hub-bit/llvm-project](https://github.com/Ryan-hub-bit/llvm-project).
Do not replace it with the system Clang:

```bash
git clone git@github.com:Ryan-hub-bit/llvm-project.git
cd llvm-project

cmake -S llvm -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_TARGETS_TO_BUILD=X86

cmake --build build --target clang llvm-nm -- -j"$(nproc)"
```

Verify the build:

```bash
./build/bin/clang --version
./build/bin/llvm-nm --version
```

## 3. Build the bundled MyPinTool

`Mypintool/` contains both the Intel Pin kit and
`source/tools/MyPinTool`. Enter the directory inside this repository and
rebuild the tool instead of relying on an existing binary:

```bash
cd /absolute/path/to/icflow_dynamic_collection/Mypintool/source/tools/MyPinTool
make clean
make obj-intel64/MyPinTool.so
```

Verify the required files:

```bash
test -x ../../../pin
test -f obj-intel64/MyPinTool.so
```

You can also verify the launch command directly:

```bash
../../../pin -t obj-intel64/MyPinTool.so -- /usr/bin/true
```

## 4. Prepare the package URL list

Create a text file containing one official Arch packaging repository or AUR Git
URL per line. Blank lines and lines beginning with `#` are ignored. For
example:

```text
https://gitlab.archlinux.org/archlinux/packaging/packages/zydis.git
https://aur.archlinux.org/example-package.git
```

The list is an input to each experiment, so large package-name and URL snapshots
that quickly become outdated are not committed to this repository.

## 5. Run dynamic collection

Return to this repository, set the three absolute paths, and run the collector:

```bash
export LLVM_BUILD=/absolute/path/to/llvm-project/build
export PIN_ROOT=/absolute/path/to/icflow_dynamic_collection/Mypintool
export PINTOOL="$PIN_ROOT/source/tools/MyPinTool/obj-intel64/MyPinTool.so"

./collect_dynamic.sh /absolute/path/to/package_urls.txt
```

For each URL, the script performs the following steps:

1. Clone the packaging repository into `work/`.
2. Run `makepkg` once with `--nocheck` and the custom LLVM to produce the test
   ELF executables.
3. Temporarily replace ELF executables under `src/` with MyPinTool launch
   scripts, preserving each original executable with an `.orig` suffix.
4. Run `makepkg` again with `check()` enabled. When a test launches an ELF, it
   actually runs `pin -t MyPinTool.so -- <binary>.orig ...`.
5. Save the logs and non-empty `*_icall.json` and `*_ijump.json` files
   produced by MyPinTool, then restore the original ELF executables.

Results are written to `output/` by default:

```text
output/
├── collection.log
├── processed_urls.txt
├── failed_urls.txt
└── <package>/
    ├── build.log
    ├── test.log
    ├── wrapped-executions.tsv
    └── artifacts/
```

A non-empty `wrapped-executions.tsv` confirms that at least one test ELF was
actually launched through MyPinTool. Successfully processed URLs are skipped on
subsequent runs.

Timeouts and the working directory can be customized:

```bash
BUILD_TIMEOUT=3600 \
TEST_TIMEOUT=3600 \
WORK_ROOT=/data/icflow-work \
./collect_dynamic.sh package_urls.txt /data/icflow-output
```

## Wrap or restore ELF files manually

For a single prebuilt project, invoke the wrapper directly:

```bash
PIN_ROOT="$PIN_ROOT" PINTOOL="$PINTOOL" \
  ./wrap_with_mypintool.sh /path/to/package/src

# Restore the original ELF files after running the tests
./restore_wrapped_elfs.sh /path/to/package/src
```

The collector automatically restores wrapped executables after normal
completion, errors, `SIGINT`, or `SIGTERM`. If the process is forcibly
terminated with `SIGKILL`, run `restore_wrapped_elfs.sh` manually.

## Repository contents

- `Mypintool/`: bundled Pin kit and ICFlow MyPinTool source, without a nested
  `.git` directory.
- `collect_dynamic.sh`: builds packages, runs tests through MyPinTool, and
  organizes the results.
- `wrap_with_mypintool.sh`: temporarily replaces test ELF files with
  MyPinTool launch scripts.
- `restore_wrapped_elfs.sh`: restores the original ELF files from their
  `.orig` backups.
- `makepkg.conf`: inherits the Arch Linux system configuration, enables
  `check()`, and disables symbol stripping.
