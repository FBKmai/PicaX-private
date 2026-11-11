# 开发指南

[首页](../README.md) · [贡献流程](../CONTRIBUTING.md) · [架构](Architecture.md) · [电脑部署](LanSuperResolution.md) · [HAT 说明](HATOptimization.md)

本文面向准备修改代码的开发者，不要求先下载模型或跑一次整本推理。先理解边界，再选择必要的验证层级。

## 1. 获取代码与选择环境

```sh
git clone --branch iphone-duo-ios27 https://github.com/FBKmai/PicaX-private.git
cd PicaX-private
git switch -c feat/my-change
```

本仓库 PR 的目标分支是 **`iphone-duo-ios27`**，不是上游仓库，也不是这里的历史 `main`。已经 fork 的开发者将此仓库配置为 upstream，自行 fetch/rebase/merge；不要覆盖自己的未提交改动。

| 工作 | 推荐环境 | 不需要 |
|---|---|---|
| 文档、Python 契约逻辑 | Python 3.11；本机只跑 stdlib 检查 | Torch、权重、GPU、Xcode |
| HTTP 集成 | Python 3.11 + `requirements-transport.txt`，CI 测 Windows/Linux | CUDA、权重 |
| HAT 小模型数值 | Actions 独立 Linux CPU job；依赖见 workflow | 真实 checkpoint、CUDA |
| 真实电脑模型 | [Windows x64 CUDA 环境](LanSuperResolution.md#requirements) | macOS Core ML 环境 |
| Swift/App、XCTest、IPA | macOS + **Xcode 27.1**，或 Actions | 电脑端权重 |
| 手机模型转换 | 单独的 macOS arm64 / Python 3.11.9 hash-locked 环境 | Windows CUDA venv |

不要把虚拟环境、权重、漫画、数据库、签名凭据或私人启动脚本提交 git。不要把下载/解压目录作为 Python 或构建工具的工作目录；只从受信任源码运行，以 `-I` 隔离意外模块导入。

## 2. 代码地图

| 目录/文件 | 职责 |
|---|---|
| `PicaX/PicaXApp.swift`、`ContentView.swift` | 主应用与生命周期入口 |
| `PicaX/Views/` | SwiftUI 页面；下载、阅读、设置、搜索等分区 |
| `PicaX/Services/DownloadService.swift` | 下载记录、原下载/超分记录及自动本机队列的集成 |
| `PicaX/Services/ContentPlatforms/` | 各漫画源网络/解析适配 |
| `PicaX/Services/Proxy/` | 来源请求代理、凭据和有界响应处理 |
| `PicaX/Models/`、`PicaXShared/` | 模型、共享纯逻辑和跨 target 辅助代码 |
| `PicaX/Services/LanSuperResolution/` | 电脑连接、HTTP、任务清单、日志、恢复与文件收取 |
| `PicaX/Views/Downloads/LanSuperResolutionView.swift` | 电脑超分 UI 与模型/精度选项 |
| `PicaX/Services/SuperResolutionService.swift`、`SuperResolutionModel.swift` | 手机 Core ML 加载与推理，不是 CUDA 服务 |
| `PicaX/Services/SuperResolutionBatch.swift`、`AutoSuperResolutionBackgroundCoordinator.swift` | 手机批量与系统允许的后台时段协调 |
| `DesktopServer/launch.py`、`picax_lan/cli.py` | 受信任入口、参数校验、队列恢复和启动 |
| `DesktopServer/picax_lan/server.py`、`protocol.py` | HTTP、清单/结果校验、传输与解码限制 |
| `DesktopServer/picax_lan/jobs.py`、`worker.py` | SQLite/原子文件、队列、单模型进程与重载 |
| `DesktopServer/picax_lan/models.py` | 固定模型身份、来源和 hash，不接受远程任意权重 |
| `DesktopServer/picax_lan/inference.py`、`hat_memory.py` | 真实 PyTorch 推理、输出量化与 HAT 内存调度 |
| `PicaXTests/`、`DesktopServer/tests/` | Swift 与电脑服务回归测试 |
| `BuildScripts/`、`.github/workflows/` | 构建、资源审计、模型工具与 CI |
| `BuildSupport/`、`PicaX.xcodeproj/` | Info.plist、target、签名、SPM 与 scheme |

更详细的数据流与持久化约束见[架构](Architecture.md)。

## 3. Apple 开发环境与构建

### Xcode 中运行

1. 安装 **Xcode 27.1**、命令行工具，以及 iPhone Duo / iOS 27.1 模拟器。可用 `xcodebuild -version`、`xcrun simctl list devices available` 检查。
2. 打开 `PicaX.xcodeproj`，选择共享 scheme **PicaX**。SPM 依赖版本由 `PicaX.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` 记录，除非本次任务就是升级依赖，不要顺手重新解析到新版本。
3. 普通模拟器运行不需要个人签名证书。代码/界面修改后用 Product → Test 或下面命令运行 XCTest。
4. 真机运行要在 Signing & Capabilities 选择自己的 Team，按需修改主应用、Watch App、Live Activity 扩展及测试 target 的 bundle ID。工程内维护者的 Team/标识不是可供其他开发者使用的证书。
5. 改 bundle ID 时同步核对 `BuildSupport/PicaX-Info.plist` 中 BGTask 标识，以及 `AutoSuperResolutionBackgroundCoordinator.swift` 的注册标识；它们不能随意变成两套值。只为模拟器测试时无需做这些修改。

工程最低部署 iOS 15.2 / watchOS 9 / macOS 26 / visionOS 26，Live Activity 扩展 iOS 16.1。这不是构建 SDK 版本；Duo 专用脚本要求链接 iOS SDK ≥27.1。旧版普通多平台工作流使用另一套 Xcode 26.6 环境，不要把它等同于当前 Duo 构建路径。

在 macOS 仓库根目录执行（没有该模拟器时先安装，或针对普通开发选择实际存在的目标）：

```sh
xcodebuild -resolvePackageDependencies \
  -project PicaX.xcodeproj -scheme PicaX \
  -onlyUsePackageVersionsFromResolvedFile

xcodebuild test \
  -project PicaX.xcodeproj -scheme PicaX \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone Duo,OS=27.1' \
  -parallel-testing-enabled NO \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO
```

### 未签名 IPA

本机在**干净、独立的源码副本**中执行：

```sh
bash BuildScripts/build-iphone-unsigned.sh
```

该脚本顺序执行依赖解析、模拟器测试、Release iPhone 构建、资源审计和 ZIP 打包，输出 `build/iPhoneDuo/PicaX-iPhoneDuo-unsigned.ipa` 与 SHA-256/环境记录。它会临时移除 Watch 嵌入依赖，并在退出时恢复工程；**不要同时在同一副本编辑工程或并行运行两次**。已有 `Payload`/IPA/测试结果目录时应检查后换新副本，不使用盲目清理命令。

更容易复现的路径是在自己的仓库手动运行 [Build iPhone Duo unsigned IPA](https://github.com/FBKmai/PicaX-private/actions/workflows/build-iphone-duo.yml)，保持 `bundle_color_model=false`。需要能调度 `xcode-27` runner，且该 runner 已有 Xcode 27.1 和 iOS 27.1 的 iPhone Duo 模拟器；fork 不会复制他人的 runner 配置。没有该环境时使用自己的 macOS/Xcode，或先配置满足条件的 CI runner，不绕过 SDK/测试检查。无内置模型的构建仍能连接电脑超分。不要为了验证一个 UI 修改就开启真实 Core ML 转换/模型打包。

未签名 IPA 需要自己的合法签名才能安装。Actions 下载与有效期见[首页](../README.md#获取手机-app)。更改 `AppUpdateService.swift` 前注意：当前应用内更新检查仍指向上游，本仓库构建应按提交与 artifact 核对。

<a id="tests"></a>
## 4. 测试矩阵

命令从仓库根目录运行。下面不是要求每次把所有测试都在本机跑完；尤其真实权重、转换和 GPU 测试必须显式选择，不能默认运行或与生产任务竞争。

### A. 本机轻量 stdlib 检查（不导入 Torch/NumPy/Pillow，不加载权重）

以下为 Windows PowerShell；macOS 可将 `py -3.11` 换成 `python3.11`：

```powershell
py -3.11 -I -B BuildScripts\test_documentation.py
py -3.11 -I -B DesktopServer\tests\test_contracts.py
py -3.11 -I -B BuildScripts\SuperResolution\test_convert.py
py -3.11 -I -B BuildScripts\SuperResolution\test_fetch_checkpoint.py
py -3.11 -I -B BuildScripts\SuperResolution\test_stage_bundle_model.py
py -3.11 -I -B BuildScripts\test-super-resolution-bundle.py
git diff --check
```

文档检查只读取 git 跟踪及未忽略的 Markdown/少量源码，核对相对链接、显式锚点、当前仓库/分支入口、CLI 参数与关键部署约定；不访问网络，不验证外部链接存活，不证明从全新机器安装已通过。

### B. HTTP 集成（无真实 AI）

Actions 在 Windows/Linux 的干净环境安装 `DesktopServer/requirements-transport.txt` 后执行：

```sh
python -I -B -X utf8 DesktopServer/tests/test_http.py
```

这些测试启动独立的 **loopback** HTTP/临时存储，验证上传、校验、配额、ACK、恢复等；不是手机 Wi-Fi 端到端或 CUDA 性能测试。不要把它指向生产数据目录。

### C. HAT CPU 数值（小模型，无 checkpoint）

由 `test-lan-super-resolution.yml` 的独立 job 安装固定 CPU Torch/Spandrel 后执行：

```sh
python -I -B -X utf8 DesktopServer/tests/test_hat_memory.py
```

比较普通/移位/重叠注意力、紧凑 mask、零填充、尾批、生产同款 head_dim/window 几何、小型完整模型及量化边界；FP32 `atol=rtol=2e-5`。真实 eager matmul/gather 批次边界也受观察。受控 SDPA 模拟不等于真实 fused CUDA 已运行，CPU FP32 通过不保证真实 BF16 GEMM 舍入一致。

### D. Swift

使用上一节的 `xcodebuild test` 或 iPhone Actions。XCTest 证明覆盖到的逻辑，不证明真机图像质量、发热、后台稳定性或 GPU/ANE 后端。修改协议时必须同时检查 Python 和 `PicaXTests/LanSuperResolutionTests.swift`。

### E. 真实模型（重型、手动、隔离）

只在使用者明确选择、没有其他 GPU 工作并接受耗时/资源消耗时运行。以下示例先用小图验证当前配置，输出目录必须新建或为空，**不得使用生产 `$Data`**：

```powershell
$Py = (Resolve-Path .\DesktopServer\.venv\Scripts\python.exe).Path
& $Py -I -B -X utf8 DesktopServer\validate_local.py --weights-dir D:\PicaX-weights --output-dir D:\PicaX-check-new --models hat-l --precision bfloat16 --hat-window-batch 128 --hat-attention-backend eager --size 128x192 --accept-noncommercial-license
```

`validate_local.py` 使用真实生产 Predictor/worker，在同一 worker 内可 `--size WIDTHxHEIGHT` 多次指定和 `--repeat` 重复，或 `--source` 读取自己有权处理的页面；`--size` 与 `--source` 互斥。HAT 会按模型可选回传倍率分别验证，并写 `report.json` 与输入/输出。脚本默认 FP32，BF16 必须显式指定；“与 Lanczos 不同”只是排除伪 AI 的执行检查，不是画质验收。

需要真实 CUDA+HTTP 时，可显式运行：

```powershell
& $Py -I -B DesktopServer\validate_transport.py --weights-dir D:\PicaX-weights --output-dir D:\PicaX-http-check-new --model hat-l --accept-noncommercial-license
```

这个脚本是 **loopback HTTP / legacy FP32 清单**验证，不提供 BF16 选择，也不模拟真实手机网络。不要将其报告标为 BF16/手机端到端。真实大页、原版对照、WDDM dedicated/shared 采样和误差门槛见 [HAT 说明](HATOptimization.md)。不要为了文档或小 UI 修改默认跑这些重型测试。

## 5. 常见修改需要配套改什么

| 修改 | 必须一起考虑 |
|---|---|
| 新增电脑模型 | Python 固定身份/hash/架构/倍率、下载器归档映射、Swift 允许列表、能力/结果校验、许可来源、契约测试与真实验证；不能只填一个文件名 |
| 改协议/精度 | 手机/电脑同时验证；缺精度旧任务固定 FP32，任务身份不可变，结果精度必须与清单精确相同 |
| 改 HAT 注意力 | 保留整页卷积/全局通道信息、OCAB 零填充、mask 0/-100、完整 QKV/proj GEMM 形状；重做 CPU 数值/边界与必要的真实 BF16 对照 |
| 改输出量化/尺寸 | 先 CPU 后 FP32、有界行带、完整 native 有限值检查、舍入/裁剪/Lanczos 和 SHA 契约 |
| 改队列/恢复 | 幂等创建/重复上传/ACK、原子文件与 SQLite 状态一致；使用临时库测试，不手改生产库 |
| 改普通阅读 | 不把 AI 专用预算施加到可降采样显示的普通长图；保留来源请求的凭据、取消及代理边界 |
| 改构建/依赖 | 更新实际需求文档；不提高最低系统版本来掩盖兼容问题，不关闭校验、跳过失败或放宽阈值来“过 CI” |

## 6. CI 与提交

- `test-documentation.yml`：各分支 push / PR 的文档与文档检查相关修改，运行轻量 stdlib 文档测试。
- `test-lan-super-resolution.yml`：各分支 push / PR 的电脑与手机 LAN 相关代码，运行 Windows/Linux 契约+HTTP、Linux HAT CPU 数值；也可手动运行。
- `build-iphone-duo.yml`：默认分支的相关代码 push、相关 PR 与手动运行，进行工具契约、XCTest 和无签名构建；普通触发不下载模型、不发布 Release、不发 Telegram。文档变更本身不应启动大模型转换。
- `validate-super-resolution*.yml`：手机 Core ML 的真实转换/验证，独立于电脑 CUDA；完整页工作流在相关转换代码修改时也会运行。不要无必要触发。
- `build-unsigned.yml`：历史 `main`/版本标签的多平台发布路径，可能包含 Release/Telegram 行为；**不是当前默认的日常开发入口**。

提交前 `git diff --check`，说明测试命令/结果和未覆盖项。PR 应指向默认分支，写明行为变化、兼容性、许可/隐私影响以及验证层级。公开 issue/PR 中不放账号、Cookie、Token、私人漫画、完整任务日志或数据库。见[贡献说明](../CONTRIBUTING.md)与[安全说明](../SECURITY.md)。
