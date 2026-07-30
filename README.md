# ICFlow dynamic collection

本仓库用于在 Arch Linux 软件包测试过程中，通过 Intel Pin 和
`MyPinTool` 启动测试 ELF，收集实际执行到的间接控制流。

`arch_scripts` 中只保留了动态采集必需的流程；旧的静态批量构建脚本、包名
快照、URL 快照、统计脚本、重复版本和硬编码的个人目录均未保留。

[Ryan-hub-bit/Mypintool](https://github.com/Ryan-hub-bit/Mypintool) 的 Pin kit 已放在
`Mypintool/` 中，且不包含原仓库的 `.git` 目录，因此克隆本仓库后无需再次
下载。内置 kit 基于提交
[`bf574a6`](https://github.com/Ryan-hub-bit/Mypintool/commit/bf574a6437adad6e57be106f92b4f541359638cf)；
默认 `MyPinTool` 源码已同步为 ICFlow 使用的 JSON 采集版本，会在目标 ELF
旁生成 `*_icall.json` 和 `*_ijump.json`。旧版预编译的 `.o`/`.so` 没有保留，
必须按下文重新编译。

## 运行环境与顺序

整理或阅读本仓库不要求使用 Arch Linux；**真正执行动态采集的机器必须是
Arch Linux x86-64**。准备顺序如下：

1. 准备 Arch Linux 机器并安装构建依赖。
2. 首先编译定制的 `Ryan-hub-bit/llvm-project`。
3. 然后编译本仓库内置的 `MyPinTool`。
4. 最后运行本仓库的采集脚本。软件包的测试程序会通过
   `pin -t MyPinTool.so -- <test>.orig ...` 启动，而不是直接启动原 ELF。

不要以 `root` 身份运行采集脚本；`makepkg` 本身也不允许这样做。

## 1. 安装 Arch Linux 依赖

```bash
sudo pacman -Syu --needed base-devel cmake ninja git python file
```

`makepkg --syncdeps` 可能根据每个 `PKGBUILD` 安装额外依赖，因此运行期间需要
可用的 `sudo` 和网络连接。

## 2. 首先编译定制 LLVM

必须使用 [Ryan-hub-bit/llvm-project](https://github.com/Ryan-hub-bit/llvm-project)，
不能直接替换为系统自带的 Clang：

```bash
git clone git@github.com:Ryan-hub-bit/llvm-project.git
cd llvm-project

cmake -S llvm -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_TARGETS_TO_BUILD=X86

cmake --build build --target clang llvm-nm -- -j"$(nproc)"
```

确认构建结果：

```bash
./build/bin/clang --version
./build/bin/llvm-nm --version
```

## 3. 编译内置的 MyPinTool

本仓库的 `Mypintool/` 已包含 Intel Pin kit 和
`source/tools/MyPinTool`。进入本仓库内的目录重新编译，不要直接依赖其中已有
的构建产物：

```bash
cd /absolute/path/to/icflow_dynamic_collection/Mypintool/source/tools/MyPinTool
make clean
make obj-intel64/MyPinTool.so
```

确认文件存在：

```bash
test -x ../../../pin
test -f obj-intel64/MyPinTool.so
```

也可以直接验证一次启动方式：

```bash
../../../pin -t obj-intel64/MyPinTool.so -- /usr/bin/true
```

## 4. 准备软件包 URL 列表

创建一个文本文件，每行放一个 Arch 官方打包仓库或 AUR Git URL。空行和以
`#` 开头的行会被忽略。例如：

```text
https://gitlab.archlinux.org/archlinux/packaging/packages/zydis.git
https://aur.archlinux.org/example-package.git
```

列表属于每次实验的输入数据，因此不提交大规模、很快会过期的包名和 URL
快照。

## 5. 执行动态采集

回到本仓库，设置三个绝对路径后运行：

```bash
export LLVM_BUILD=/absolute/path/to/llvm-project/build
export PIN_ROOT=/absolute/path/to/icflow_dynamic_collection/Mypintool
export PINTOOL="$PIN_ROOT/source/tools/MyPinTool/obj-intel64/MyPinTool.so"

./collect_dynamic.sh /absolute/path/to/package_urls.txt
```

脚本会对每个 URL 顺序执行：

1. 克隆打包仓库到 `work/`。
2. 使用定制 LLVM 执行一次带 `--nocheck` 的 `makepkg`，生成测试 ELF。
3. 临时把 `src/` 中的 ELF 可执行文件替换为 MyPinTool 启动脚本，原文件保存为
   `.orig`。
4. 再次执行启用 `check()` 的 `makepkg`。测试启动 ELF 时实际执行的是
   `pin -t MyPinTool.so -- <binary>.orig ...`。
5. 保存日志和 MyPinTool 生成的非空 `*_icall.json`、`*_ijump.json`，然后恢复
   原 ELF。

默认结果写入 `output/`：

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

`wrapped-executions.tsv` 非空才表示至少有一个测试 ELF 确实以 MyPinTool 方式
启动。已经成功处理的 URL 会在下次运行时自动跳过。

可以修改超时和工作目录：

```bash
BUILD_TIMEOUT=3600 \
TEST_TIMEOUT=3600 \
WORK_ROOT=/data/icflow-work \
./collect_dynamic.sh package_urls.txt /data/icflow-output
```

## 单独包装或恢复 ELF

调试单个已构建项目时，可以直接调用包装脚本：

```bash
PIN_ROOT="$PIN_ROOT" PINTOOL="$PINTOOL" \
  ./wrap_with_mypintool.sh /path/to/package/src

# 运行测试后恢复原 ELF
./restore_wrapped_elfs.sh /path/to/package/src
```

采集脚本会在正常结束、报错、`SIGINT` 或 `SIGTERM` 时自动恢复。如果进程被
`SIGKILL` 强制终止，请手动运行 `restore_wrapped_elfs.sh`。

## 文件说明

- `Mypintool/`：内置 Pin kit 和 ICFlow MyPinTool 源码，不含嵌套 `.git`。
- `collect_dynamic.sh`：构建软件包、启用 MyPinTool 测试并整理结果。
- `wrap_with_mypintool.sh`：把测试 ELF 临时替换为 MyPinTool 启动脚本。
- `restore_wrapped_elfs.sh`：将 `.orig` 恢复为原 ELF。
- `makepkg.conf`：继承 Arch Linux 系统配置，启用 `check()` 并禁止剥离符号。
