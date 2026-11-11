# 局域网电脑 AI 超分：Windows 部署与排障

[项目首页](../README.md) · [开发指南](Development.md) · [架构与协议](Architecture.md) · [HAT 优化与实测](HATOptimization.md) · [安全说明](../SECURITY.md)

本教程从全新 Windows 环境开始，部署本仓库的**优化版 HAT-L / BF16 / 原生 4×**，再用手机提交已下载漫画。所有 IP、磁盘和目录都由你自己选择；不需要维护者的私人启动文件。

> 服务使用明文 HTTP，无认证、没有 TLS 或密码。仅限自己信任的局域网；不要开放公网、路由器端口转发、UPnP 或公共隧道。手机和电脑都要信任该网络中的其他设备。安全边界见 [SECURITY.md](../SECURITY.md)。

<a id="requirements"></a>
## 1. 准备环境

| 项目 | 要求 |
|---|---|
| 系统 | Windows x64；当前真实 GPU 验证环境为 Windows 11 |
| Python | **CPython 3.11 x64**；不是 3.9、3.12 或 ARM64 |
| GPU | NVIDIA CUDA GPU；BF16 必须同时得到硬件和模型 descriptor 支持，不以软件模拟代替 |
| 驱动 | 支持固定的 PyTorch 2.11.0 / CUDA 12.8 wheel；Blackwell 必须使用支持该架构的驱动与 wheel |
| 内存/显存 | 全页模型仍随尺寸增长。实测显卡为 RTX 5090 D v2 / 24455 MiB，系统约 30.8 GiB RAM；**没有据此声称最低配置或任意大图保证** |
| 磁盘 | CUDA Torch wheel 约 2.6 GiB，环境/缓存还需额外数 GiB；权重及上传/输出目录需要另留空间 |
| 网络 | 首次安装/下载权重需要互联网；推理不访问互联网。手机和电脑之间必须能建立 TCP 连接 |
| 手机 | 安装支持当前 HTTP 与 FP32/BF16 选择的 PicaX；[获取手机包](../README.md#获取手机-app) |

不需要单独安装 CUDA Toolkit 或 cuDNN 来替代所固定的 PyTorch wheel；仍需要兼容的 NVIDIA 驱动。此依赖文件**只用于 Windows x64 / Python 3.11**，不要复用手机 Core ML 的 macOS 环境。

其他 NVIDIA 显卡可以按设备实际支持项尝试 FP32/BF16，但没有覆盖全部设备的性能/稳定性证据。Linux/macOS/AMD 电脑 GPU 不在本教程验证范围内；`--device cpu` 仅为显式 FP32 诊断，不是自动回退。

以下命令在 **Windows PowerShell** 中执行。代码块里的 `D:\PicaX-data` 等是可自行更改的示例，不要求机器存在 D 盘。`$LanIP` 必须改成这台电脑的实际局域网 IPv4 地址，不能原样复制示例 IP。

<a id="install"></a>
## 2. 获取包含优化的源码

先安装 [Git for Windows](https://git-scm.com/downloads/win) 和可信来源的 [Python for Windows](https://www.python.org/downloads/windows/)（选择 **3.11 x64**，不要直接用其他主次版本）。NVIDIA 驱动可从[官方驱动入口](https://www.nvidia.com/en-us/drivers/)获取；用 `nvidia-smi` 核对显卡和驱动，显示的 CUDA Version 是驱动支持上限，不等于当前 Python wheel 的 CUDA 版本。在你选定的源码父目录执行：

```powershell
git clone --branch iphone-duo-ios27 https://github.com/FBKmai/PicaX-private.git
cd PicaX-private
git rev-parse --short HEAD
git merge-base --is-ancestor 60e5c374e208f53563653c950f3324a249151789 HEAD
```

最后一条退出码应为 `0`，表示包含已验证的 HAT 优化；命令成功时不输出文本。默认分支是 `iphone-duo-ios27`，不要按上游 README 克隆到另一个仓库，也不要使用本仓库旧 `main` 作为优化版入口。

不要只复制 `DesktopServer` 子目录：运行时还会使用仓库内受信任的 `BuildScripts/SuperResolution/convert.py` 和 `full_page.py` 中的权重校验与反射填充辅助逻辑；**电脑推理不执行 Core ML 转换**。

## 3. 创建独立 Python 环境

确认位于仓库根目录：

```powershell
py -3.11 -c "import sys, struct; print(sys.version); print(struct.calcsize('P') * 8)"
py -3.11 -m venv DesktopServer\.venv
$Py = (Resolve-Path .\DesktopServer\.venv\Scripts\python.exe).Path
& $Py -I -m pip install -r DesktopServer\requirements-windows-cu128.txt
& $Py -I -m pip check
```

检查第一条输出为 Python 3.11 和 `64`，安装与 `pip check` 均成功再继续。无需激活环境，因此也不必修改 PowerShell 的脚本执行策略。

依赖固定 PyTorch `2.11.0+cu128`、torchvision `0.26.0+cu128`、Spandrel `0.4.2`。Torch/Torchvision 的官方 wheel URL 带 SHA-256；其他直接依赖固定版本，但**这不是完整的传递依赖 hash 锁文件**。不要自行升级 Spandrel 后继续声称已验证 HAT 适配器兼容。

## 4. 下载并核验权重

代码许可证是 MPL-2.0；下列权重来自 the-database 的 [MangaJaNai 3.0.0](https://github.com/the-database/MangaJaNai/releases/tag/3.0.0)，适用 [CC-BY-NC-4.0](https://creativecommons.org/licenses/by-nc/4.0/)。请先阅读并确认适用于你的非商业用途，再使用确认参数。仓库不包含权重，也不接受手机上传任意模型。

先只下载 HAT-L，验证整个部署链路后再按需增加其他模型。修改下面路径，权重目标必须新建或为空，下载目录与源码、任务数据目录分开：

```powershell
$Weights = 'D:\PicaX-weights'
$Downloads = 'D:\PicaX-model-downloads'
$Data = 'D:\PicaX-data'
& $Py -I -B DesktopServer\fetch_models.py --models hat-l --destination $Weights --download-parent $Downloads --accept-noncommercial-license
```

成功应看到 `Verified illustrationjanai-v3detail-hat-l-4x-float32`，权重目录包含：

```text
4x_IllustrationJaNai_V3detail_HAT_L_28k_bf16.safetensors
provenance.json
```

HAT-L 文件 SHA-256：

```text
38c00c9ff871ae292617ae1127edc150f81c4e0f8f98685e48ff9c9cd87fba3b
```

下载器只取固定发布归档中的允许列表文件，不运行归档代码；先校验归档 hash，再校验单个权重 hash，并写入来源记录。个体权重 hash 最初来自固定的第三方注册表，**不是上游作者签名**。下载中断后若目标目录已有部分文件，不要覆盖、删除或绕过核验；检查后换一个新的空目标目录重试。

如果你自己的网络需要代理，可在当前 PowerShell 显式设置 `$env:HTTPS_PROXY = 'http://你的代理地址:端口'`；不需要代理就跳过。此教程不要求特定代理端口，不把任何人的本机代理当公共服务。

<a id="start"></a>
## 5. 启动优化版 HAT-L

用 `ipconfig` 查看连接手机所在网络的网卡 IPv4 地址，例如 `192.168.1.10`。服务要求实际的私有/链路本地 IP，不使用 `0.0.0.0`、`localhost`、主机名或公网 IP 作为启动地址。

沿用上一步变量，在仓库根目录执行：

```powershell
$LanIP = '192.168.1.10' # 必须换成自己的电脑地址
.\DesktopServer\start-server.cmd --host $LanIP --weights-dir $Weights --data-dir $Data --models hat-l --model-precision hat-l=bfloat16 --hat-window-batch 128 --hat-attention-backend eager --job-quota-gib 32 --total-quota-gib 128 --retention-hours 168 --diagnostics --accept-noncommercial-license
```

- 这是长期运行的前台服务，保留此终端。没有注册系统服务、计划任务或开机自动启动。
- HAT 默认窗口批次 `128` / backend `eager` 已是优化路径；上面显式写出便于核对。不要将 `0` 当成“自动选择”，`0` 会使用原版高峰值路径。
- 上面磁盘配额 `32 / 128 GiB` 与保留 `168` 小时都是教程示例，不是显存限制或预分配这些磁盘空间。按实际数据盘容量选择；创建任务时还会检查实际剩余空间。
- 看到连接 URL、二维码和 `HAT attention: 128 windows/batch, eager`，只说明服务启动到该阶段；模型会异步加载，须继续检查 `ready`。
- 设备不支持 BF16 时明确失败，不会换模型或静默降精度。若你决定使用 FP32，明确改为 `--model-precision hat-l=float32`，并接受不同的性能/内存特性。
- Windows 若询问网络权限，仅允许可信的**专用网络**。程序不会自动修改防火墙、驱动、注册表、频率或功耗上限。

关闭并重新打开 PowerShell 后，`$Py`、`$Weights`、`$Data`、`$LanIP` 等变量需要重新设置。可把自己确认过的启动命令放进个人脚本，**不要把私人目录、日志或连接信息提交仓库**。

## 6. 检查服务和模型是否就绪

在第二个 PowerShell 窗口把地址换成自己的电脑，执行只读请求：

```powershell
$Base = 'http://192.168.1.10:18443'
Invoke-RestMethod "$Base/"
(Invoke-RestMethod "$Base/v1/capabilities").models | Format-Table id, ready, precision, supportedPrecisions, error -AutoSize
```

预期：

- `/` 返回 `status = ok`、`transport = http` 和 `serverID`。
- HAT-L 的 `ready = True`、默认 `precision = bfloat16`，`supportedPrecisions` 包含 `bfloat16`。
- 刚启动时 `Not checked yet` / `ready=False` 可能是仍在加载；等待片刻再查。持续失败时看 `error` 和终端，不要以 HTTP 200 代替模型就绪。

`capabilities` 不包含全部推理诊断字段。HAT 是否实际以优化实现执行，要看下一步**成功页面的结果元数据**，不是从 `ready` 推断任意尺寸必过。

## 7. 手机连接并验证第一张结果

1. 安装[兼容手机包](../README.md#获取手机-app)，在系统设置中允许 PicaX 访问本地网络。
2. 手机与电脑接入同一可信局域网；关闭访客/AP 隔离。不同网段只有在实际路由和访问策略允许时才可互通。
3. 先在手机浏览器打开上一步的 `$Base` 地址；看到 `status: ok`，才证明手机能访问电脑的端口。电脑能 ping 手机不等于反向 TCP 可达。
4. PicaX → **设置 → 下载 → 局域网电脑超分**，输入电脑地址或扫描终端二维码。二维码只有地址，不是秘密凭证。
5. 下载库多选一个小的已下载漫画/章节 → **电脑超分**。选择 HAT-L、BF16，以及希望的回传倍率；要复现本文目标请选择 **4×**。默认回传为 2×，需要主动改为 4×。
6. 等全部上传并 commit 后，电脑逐页串行处理。结果进入“下载 → 超分”的独立记录，原下载保持不变。

第一张成功页的结果元数据应包含以下值（这不是完整 JSON 响应示例）：

```json
{
  "modelID": "illustrationjanai-v3detail-hat-l-4x-float32",
  "precision": "bfloat16",
  "nativeScale": 4,
  "deliveryScale": 4,
  "attentionImplementation": "hat-window-batched-v2",
  "attentionWindowBatch": 128,
  "attentionBackend": "eager",
  "mode": "fullPage"
}
```

可在自己的任务查询 `GET /v1/jobs/{jobID}` 的 `pages[].result` 核对；使用手机任务时需发送相同的 `X-PicaX-Client-ID` 分组值。完整导出的超分 ZIP 还附 `LAN-SuperResolution.json` 每页元数据；PDF 只包含图片。`--diagnostics` 终端也会显示页级精度/窗口批次/阶段内存，但不会打印漫画标题或内容。

不要仅看文件名里的 `bf16`、modelID 的 `-float32` 后缀或输出比原图大就判断精度/模型。完整说明见下节。

<a id="models"></a>
## 模型、倍率与精度

| CLI 别名 | 模型 | 原生倍率 | 回传倍率 | 验证状态 |
|---|---|---:|---|---|
| `hat-l` | IllustrationJaNai V3detail HAT-L | 4× | 2× / 4× | 默认内部窗口分批；真实 BF16/4× 测试见 [HAT 说明](HATOptimization.md) |
| `fdat-xl` | IllustrationJaNai V3detail FDAT-XL | 4× | 2× / 4× | 既有本机 FP32 普通页验证；不安装 HAT 适配器 |
| `fdat-m` | IllustrationJaNai V3detail FDAT-M unshuffle | 2× | 2× | 既有本机 FP32 验证；不安装 HAT 适配器 |
| `dat2` | IllustrationJaNai V3denoise DAT2 | 4× | 2× / 4× | 允许列表候选，未在该真实 GPU 环境下载/验证 |

4× 模型回传 2× 时，先以完整原图运行原生 4× AI，再以 Lanczos 缩到 2×；不会因此把模型计算也变成 2×。模型更重不保证文字/网点更忠实，请先用自己有权处理的少量页面确认画质。

- 通用 CLI 不指定时默认模型 `fdat-xl`、默认 FP32；本教程显式选 HAT-L/BF16。
- `--precision bfloat16` 改所有所选模型默认值；`--model-precision hat-l=bfloat16` 只覆盖该模型。手机的新任务显式选择优先，精度固定在任务清单内；改选择只影响新任务。
- CPU 只接受 FP32。CUDA BF16 还需硬件与 descriptor 支持；不提供隐式 CPU/精度回退。
- modelID 的 `-float32` 是历史身份后缀，实际精度看任务/结果的 `precision`。checkpoint 文件名的 `bf16` / `fp16` 也不能代替实际执行精度；已核验的 HAT/FDAT 文件浮点权重存储为 F32，运行时转换。
- 修改同一任务的模型、倍率或精度不是重试；需要创建新任务。旧清单缺少 `precision` 时始终按 FP32 执行。

增加模型时可在**另一个新的空权重目录**执行 `fetch_models.py --models hat-l fdat-xl fdat-m`（补上与第 4 步相同的目标、下载目录和许可参数），然后用这个目录和相同的 `--models` 列表重启。不要在已有非空目录直接重跑下载器，也不要启动列表中没有下载的模型。

<a id="compatibility"></a>
## 手机与电脑版本兼容

| 组合 | 行为/处理 |
|---|---|
| 当前 HTTP/精度选择手机 + 当前电脑 | 推荐组合；可按设备公布项选 FP32/BF16 |
| 旧 HTTPS/配对手机 + HTTP 电脑 | 不兼容，需要更新手机；重启电脑不能把旧手机协议改成 HTTP |
| HTTP 但没有精度选择的旧手机 + BF16 默认电脑 | 可能拒绝整份能力响应；更新手机，或显式把电脑全部模型默认值恢复 FP32 |
| 当前手机 + 较旧的无精度字段电脑 | 只显示 FP32，省略新任务精度字段以保持旧协议；不等于电脑已有 HAT 优化 |
| 旧任务缺 `precision` | 固定 FP32，不受新 CLI 默认 BF16 影响 |

**HAT 内存优化本身不更改手机协议/SQLite 列，不需要为此重新打 IPA。** 只需已具备 HTTP 和精度选择的手机包。电脑超分不依赖手机内置 Core ML 模型。

<a id="operations"></a>
## 升级、停止、恢复与备份

1. 优先等当前任务完成再升级。记录自己的启动命令、权重/数据目录、保留时长与配额；不要只保存示例。
2. 用 Ctrl+C 停止服务并确认进程退出。**主动停止时在途页面可能标为失败，需要在手机重试失败页**；异常退出留下的未提交页通常由下一次 `recover()` 重新排队，不承诺任何停止方式都零重算。
3. 停止后，完整备份自己的数据目录（SQLite 及任务文件，包含仍存在的 WAL/SHM），不要只复制正在写入的数据库主文件。备份不应上传公开仓库。
4. 工作区干净、没有自己的未保存改动时，执行：

```powershell
git switch iphone-duo-ios27
git pull --ff-only origin iphone-duo-ios27
```

5. 只有依赖文件改变才在原虚拟环境重新安装对应依赖并 `pip check`；不要为了源码升级重新下载相同权重或创建新的生产数据目录。
6. 按**原来的 `--data-dir`** 和其他个人参数重启。换数据目录会得到另一套任务库和 serverID，手机可能认为是另一台电脑；换 IP 则仍可用同一数据目录重连。

CLI 默认数据目录是 `%LOCALAPPDATA%\PicaX-LAN`，默认保留 **24 小时**。本教程显式选独立数据目录与 168 小时，避免依赖隐含位置。服务启动时清理超过保留期且非 queued/running 的任务，**包括已收取、取消、部分失败或未上传完成的闲置任务**。ACK 不会立即删除电脑文件。

确有需要才在停止服务、核对目录、备份之后执行手动清理；它会永久删除所选目录中的过期任务和图片：

```powershell
.\DesktopServer\start-server.cmd --data-dir $Data --cleanup --retention-hours 168
```

不要直接修改 SQLite 状态来恢复任务，也不要用 `JobStore` 构造器做只读检查；初始化、恢复和清理都可能写入数据或删除文件。

手机进入后台只暂停传输，不取消已经完整提交的电脑任务。回到前台继续收取；手机持久化并核对结果 SHA-256 后才发 ACK。明确取消需要电脑确认；丢失电脑/任务过期时可放弃本机跟踪，但这不等于远程任务已取消。

<a id="limits"></a>
## 容量与配额

- 清单最多 2 MiB / 4096 页，最多 8 个活跃任务。
- 输入 PNG 最多 64 MiB、800 万原始像素；单边默认 4096（包含模型对齐后边长，可用 `--maximum-side` 配到 8192）。
- 回传 PNG 最多 128 MiB、3200 万像素、单边 16384。它是手机接收限制，不是原生中间结果的显存预测。
- 通用磁盘配额默认单任务 **8 GiB**、总计 **16 GiB**；教程显式使用 32 / 128。每页预留 `2 × 输入 PNG 字节 + 输出宽 × 输出高 × 4 + 64 KiB`，不是压缩后实际文件大小。
- 总配额包含保留任务。删除手机记录不会释放电脑空间；单任务超限也不能靠清理别的任务解决。
- 无模型专属像素估算拒绝或默认 VRAM 分配上限；实际张量仍可能 OOM/超时，失败不会触发换模型、缩图或独立小图拼接。

<a id="troubleshooting"></a>
## 常见问题

| 现象 | 检查与处理 |
|---|---|
| `py -3.11` 不存在/显示非 64 位 | 安装 CPython 3.11 x64，重新打开终端，不使用其他 Python 的旧虚拟环境 |
| 下载 wheel 失败/版本不匹配 | 核对 Windows x64 / Python 3.11、网络、磁盘、可信源；不要借用 macOS 锁文件或不明 wheel |
| `CUDA unavailable` / wheel 缺少 `sm_...` | 核对 NVIDIA 驱动、固定 CUDA wheel、实际 GPU；不默认回退 CPU |
| BF16 不支持 | 核对 capabilities 与错误；选择设备明确支持的 FP32，或使用支持 BF16 的设备，不能把软件模拟当原生支持 |
| `Missing local checkpoint` / hash mismatch | 核对 `--weights-dir`、文件名、下载器输出。不要修改 hash 或关闭校验来“修好” |
| 浏览器能打开，但模型 `ready=False` | 看 capabilities 的 `error` 与终端；HTTP 可达不代表加载成功。多模型启动会顺序核验 |
| 手机无法访问 `/` | 检查实际 IP/端口、PicaX 本地网络权限、Windows 专用网络防火墙、访客/AP 隔离；不要关闭全部防火墙或开放公网 |
| 手机提示能力不匹配 | 核对 HTTP/精度版本兼容与模型允许列表，见[兼容性](#compatibility) |
| HTTP 507 | 区分**单任务配额**、**总配额**、**实际磁盘不足**；按错误调整，改参数后重启。只提高配额不能制造可用空间 |
| 4× 结果超接收上限 | 回传 2× 可降低接收尺寸，但模型仍用原图跑原生 4×；这不是更换模型或缩小输入 |
| OOM/共享显存增长 | 先核对结果中的 v2/128/eager 和实际精度，确认没有另一个 GPU 任务；看每页阶段数据。仍可能出现短时 shared，不用 allocated+reserved 相加，也不随意改成 `--hat-window-batch 0` |
| 改源码后仍像旧版 | 运行中的 worker 不会热更新；在安全停止后按同一数据目录重启，再检查新页面元数据 |
| 手机移除任务后电脑仍占磁盘 | 手机跟踪与电脑保留是两件事；核对保留期、ACK/取消与清理规则，先备份再清理 |

## 验证与进一步开发

- 无模型的本机轻量检查：`py -3.11 -I -B DesktopServer\tests\test_contracts.py`。
- 文档链接/示例参数检查：`py -3.11 -I -B BuildScripts\test_documentation.py`。
- HTTP 集成、HAT CPU 数值、Swift/XCTest 和真实模型验证命令统一见[开发指南](Development.md#tests)。真实 GPU 测试必须显式选择、避开其他 GPU 工作，并使用新的隔离输出目录；本教程不会自动启动第二个模型。
- [HAT 优化说明](HATOptimization.md)记录截至 2026-11-11 的真实 CUDA/BF16 结果及限制。历史 FP32/HTTPS 证据与当前 HTTP/BF16 路径不是同一次测量，不混用。
- [架构与 v1 协议](Architecture.md#protocol)解释清单、页 ID、状态机、结果校验和 ACK；这不是任意图片/任意模型上传服务。
