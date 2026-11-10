# 局域网电脑 AI 超分

## 范围与状态

- 下载库多选**已下载的漫画图片** → **电脑超分**，或在“设置 → 下载 → 局域网电脑超分”输入电脑地址/扫码连接、查看任务。
- 保留“本机超分”和下载后自动超分；自动超分仍在手机运行，不会悄悄改到电脑。
- 结果独立保存到“下载 → 超分”，不覆盖源下载。可沿用下载库的阅读、ZIP 和 PDF 导出。ZIP 附带模型来源/许可说明，完整任务还附每页推理元数据；PDF 只包含图片页。
- 电脑使用真实 PyTorch/CUDA 模型，手机可为新任务选择 **FP32 / BF16**（以模型与显卡公布的支持项为准），没有普通插值冒充 AI、隐式 CPU/精度回退或失败后换模型。
- 参考 LANDrop 的发现、配对和独立传输思路；**不是 LANDrop 协议实现，不与 LANDrop 互通，也不要求安装 LANDrop**。
- 当前连接采用**局域网 HTTP 直连**，不使用证书、口令或一次性配对。旧版 HTTPS 手机包需要更新；不能只重启电脑端就让旧包改用 HTTP。
- 原版 HTTPS 链路曾在 Windows 上实测；改版不重复跑大模型测试。手机端编译、XCTest 和 IPA 状态以对应 Actions 运行及交付报告为准；iPhone 真机跨局域网端到端仍待验证。

## 当前电脑已经装好的环境

2026-11-09 本地安装到隔离目录，没有改全局 Python、PATH、注册表或防火墙：

- Python 3.11.18：`D:\折腾\picax\PicaX-LAN-runtime.7sd1c8sq\python`
- 项目环境：`DesktopServer\.venv`
- 权重：`D:\折腾\picax\PicaX-LAN-runtime.7sd1c8sq\weights`
- 本机任务数据库、上传原图和超分结果：`D:\折腾\picax\pic`。本机启动文件显式传入该路径，不再使用 C 盘默认数据目录。
- PyTorch `2.11.0+cu128`、CUDA 12.8、Spandrel 0.4.2。
- GPU：RTX 5090 D v2，24455 MiB；驱动 616.64。
- 本机局域网地址：`192.168.5.8`（变化后修改启动地址，并在手机输入新地址即可；不用重新生成证书）。

已配置的快捷启动文件：

```text
D:\折腾\picax\PicaX-LAN-runtime.7sd1c8sq\launchers\start-picax-server.cmd
```

双击上述文件即可启动并显示长期有效的连接地址/二维码。保持终端运行；Ctrl+C 停止。无需配对，不会生成或读取证书；启动脚本已启用简短的请求状态日志，并将 HAT-L 的新任务默认精度设为 BF16（其他模型仍为 FP32）。**这需要安装带精度选择的新 IPA**；修改文件本身不会重启已运行的服务。

也可在仓库目录的 Windows 终端执行：

```bat
DesktopServer\start-server.cmd --host 192.168.5.8 --data-dir "D:\折腾\picax\pic" --weights-dir "D:\折腾\picax\PicaX-LAN-runtime.7sd1c8sq\weights" --models fdat-xl hat-l fdat-m --model-precision hat-l=bfloat16 --job-quota-gib 32 --total-quota-gib 64 --diagnostics --accept-noncommercial-license
```

若 Windows 弹出网络访问询问，仅允许你信任的**专用网络**。程序不会自动修改防火墙、开启公网端口、UPnP 或端口转发。手机和电脑须能互相访问同一局域网；访客 Wi-Fi/AP 隔离可能阻止连接。

## 模型与倍率

| CLI 名称 | 模型 | 原生倍率 | 可选回传 | 定位 |
|---|---|---:|---|---|
| `fdat-xl` | IllustrationJaNai V3detail FDAT-XL | 4× | 2× / 4× | 默认，已实测普通漫画页尺寸 |
| `hat-l` | IllustrationJaNai V3detail HAT-L | 4× | 2× / 4× | 高显存细节档；单页实际显存不足时明确报错 |
| `fdat-m` | IllustrationJaNai V3detail FDAT-M unshuffle | 2× | 2× | 快速档、手机模型对照基线 |
| `dat2` | IllustrationJaNai V3denoise DAT2 | 4× | 2× / 4× | 允许列表候选；本机未下载/验证，不会显示为已就绪 |

默认回传 **2×**。4× 模型回传 2× 时，先运行真实原生 4× AI，再用 Lanczos 缩小到 2×；并非普通放大代替 AI。

### FP32 / BF16 选择

- 新手机在“电脑模型 / 回传倍率”下显示“推理精度”。选择 **FP32** 或 **BF16** 后提交，选择会写入手机任务日志与发送给电脑的清单；任务列表显示该任务的固定精度。切换选择只影响新任务，不改变已排队、重试或恢复中的任务。
- 通用 CLI 不传新参数时仍默认 FP32。`--precision bfloat16` 修改所有所选模型的默认值；`--model-precision hat-l=bfloat16` 只覆盖 HAT-L，可重复传入，后面的同模型值覆盖前面的。它们控制启动加载精度与手机初始选项，**手机对新任务的显式选择优先**。
- 只开放 `float32` / `bfloat16`，本轮不开放 FP16。BF16 要求 CUDA 硬件支持且 Spandrel descriptor 声明支持；CPU 诊断仅支持 FP32。不支持时明确报错，不自动换精度。`ready` 表示选定默认精度的模型加载与身份校验成功，不保证任意尺寸能执行。
- 电脑同一时间只驻留一个 GPU worker；模型或精度变化时先释放旧进程，再按任务选择加载。输入张量与模型使用相同 dtype；输出先复制到 CPU，再转 FP32 量化为原有 8-bit RGB PNG，避免将 BF16 直接交给 NumPy，也避免在 GPU 上额外分配整页 FP32 副本。FP32 仍关闭 TF32；未加入 autocast、窗口分批或 SDPA 改写。
- 权重文件名中的 `bf16` / `fp16` 不等于实际存储 dtype。本机 HAT-L、FDAT-XL、FDAT-M 的 safetensors 文件头显示浮点张量均为 F32；运行时才按选定 dtype 转换。既有 modelID 中的 `-float32` 是历史身份标识，**不再代表任务的实际执行精度**；modelID、文件和 SHA-256 均保持不变，实际精度看任务和结果的 `precision`。
- **兼容性**：缺少 `precision` 的旧任务始终按 FP32 执行，与新 CLI 默认值无关。新手机连接旧电脑服务时只显示 FP32，省略新清单字段以维持旧协议。旧手机仍强制每个模型的能力精度为 FP32，任何模型默认 BF16 都会使它拒绝**整份能力响应**，即使该模型尚未就绪；需更新 IPA，或将电脑所有模型默认值改回 FP32。
- 本次不做 BF16/FP32 数值画质对比或本机真实 GPU 验证，也未在 Windows 上构建 IPA / 运行 XCTest。下方数据均为历史 FP32；**800×1129 原生 4× 在 24GB 上能否跑通仍未实测，不作保证**。

只开放**逐页整图推理**，每次模型调用处理一页，不把整本漫画拼成一张图。不自动退回之前存在上下文/接缝问题的 128 像素分块，不缩小原图或更换模型，也不保证所有页面能处理。手机不按模型专属输入像素数、对齐后像素数或启动时显存估算拦截输入；只检查回传图片的接收范围和上传文件大小，电脑另检查输入解码/传输限制。模型越重不意味着文字、网点或线条一定更忠实。请用自己的少量页面确认画质。

### 权重与来源

来源：[the-database / MangaJaNai 3.0.0](https://github.com/the-database/MangaJaNai/releases/tag/3.0.0)。全部仅限 **CC-BY-NC-4.0 非商业用途**；作者 the-database。[许可全文](https://creativecommons.org/licenses/by-nc/4.0/)。应用不提交权重到 git。

固定文件名、架构、倍率和 SHA-256 位于 `DesktopServer/picax_lan/models.py`，手机允许列表位于 `LanSuperResolutionModels.swift`，Python 回归测试比较二者。个体权重散列最初来自固定版本的第三方[转换器模型注册表](https://github.com/imxieyi/waifu2x-ios-model-converter/blob/68e3f51517e04433164c09d8505a409e26477905/known_models.yaml)，不是声称上游作者签名。下载工具还核对 GitHub release API 提供的上游归档 SHA-256，再核对归档内每个指定权重。

下载示例（目标必须为新/空目录；不解压或运行归档中的脚本）：

```bat
DesktopServer\.venv\Scripts\python.exe -I -B DesktopServer\fetch_models.py --models fdat-xl hat-l fdat-m --destination D:\PicaX-weights --download-parent D:\PicaX-downloads --accept-noncommercial-license
```

需要代理时，在当前终端设置 `HTTPS_PROXY=http://127.0.0.1:7890`。服务的推理不需要访问互联网，不接收手机上传的模型、Python 代码或 pickle。

## 历史本机 FP32 真实验证结果

诊断图包含文字、细线和彩色区域；不是用户漫画，不构成主观画质或文字保真度认证。以下均是既有 FP32 报告，**不是本次 BF16 改造的新实测**。单 GPU worker 串行运行；每个模型在独立 spawn 进程加载。没有 CPU 回退。

| 模型 | 输入 | 回传 | 推理/编码等总耗时 | PyTorch 峰值 allocated |
|---|---|---|---:|---:|
| FDAT-M | 1000×1500 | 2000×3000 | 0.781 秒 | 2.48 GiB |
| FDAT-XL | 1000×1500 | 2000×3000 | 15.859 秒 | 14.62 GiB |
| FDAT-XL | 256×384 | 1024×1536 | 0.547 秒 | 1.04 GiB |
| HAT-L | 512×768 | 1024×1536 | 4.297 秒 | 14.76 GiB |
| HAT-L | 256×384 | 1024×1536 | 1.047 秒 | 3.81 GiB |

测试还覆盖各模型 128×192 → 256×384。PyTorch allocated 不含桌面显示/其他进程的所有显存，不等于整机 GPU 总占用，也不是大图的保证。

历史版本的 HTTPS → SQLite → CUDA → 收取 → SHA-256 → ACK 链路另测了 FDAT-XL（以下不是本次 HTTP 改版的重新实测）：

- 连续两张 1000×1500 → 2000×3000，分别约 12.125 / 11.281 秒推理，证明后续页面不会因可复用的 PyTorch 缓存被误拒。
- 256×384 → 1024×1536 原生 4× 回传。
- 单次配对、叶证书 SHA-256 pin、上传原图、完整提交、真实 GPU worker、下载解码、散列、持久化 ACK、存储恢复全部通过。
- 测试仅监听回环地址，不改防火墙，不等同于 iPhone/真实 Wi-Fi 的端到端测试。

完整报告和 PNG：

```text
D:\折腾\picax\PicaX-LAN-runtime.7sd1c8sq\validation-first\report.json
D:\折腾\picax\PicaX-LAN-runtime.7sd1c8sq\validation-https\report.json
```

这些历史实测不是输入尺寸硬上限。本次已移除模型专属像素上限、原生中间结果像素上限，以及启动时/每页执行前的显存估算拒绝。能力字段 `maximumInputPixels` 仅表示配置的输入解码上限，不代表显存预测或成功保证；手机也不依据旧任务缓存中的该字段拒绝页面。实际 CUDA 分配失败时，错误会明确说明模型、单页尺寸、原生倍率和实际 FP32/BF16 精度，并区分“实际显存不足”与输入解码/回传限制；worker 会被终止，后续页重新加载，不会缩图、分块或换模型。本次只做轻量回归，未重新实测大图 GPU 推理。

## 新机器安装

需要 CPython **3.11 x64**、兼容 Blackwell 的 NVIDIA 驱动和足够磁盘空间（当前 CUDA wheel 约 2.6 GiB，安装和缓存还需额外数 GiB）。不要安装到全局环境，也不要复用 macOS Core ML 的依赖。

```bat
py -3.11 -m venv DesktopServer\.venv
DesktopServer\.venv\Scripts\python.exe -I -m pip install -r DesktopServer\requirements-windows-cu128.txt
```

直接依赖固定版本，Torch/Torchvision 的官方 Windows wheel URL 带 SHA-256；`requirements-transport.txt` 不是完整的传递依赖 hash 锁文件。无 CUDA 时启动报错，不默认改用 CPU。`--device cpu` 仅为显式诊断用。

## 连接、传输与恢复

1. 启动电脑服务。在新版 PicaX 的“局域网电脑超分”输入 `192.168.5.8:18443`，或扫描电脑二维码，直接连接。
2. 手机和电脑都必须使用这一版 HTTP 连接方式。旧 IPA 的 HTTPS/配对流程不能连接新服务，需要重装新版 IPA。
3. 排查网络时，可先用手机浏览器打开 `http://192.168.5.8:18443/`，出现 `status: ok` 就说明手机能访问服务端口。电脑能 ping 通手机，并不能证明反向 TCP 端口可达。

- 不再使用 TLS、自签名证书、证书指纹、一次性密钥、5 分钟有效期、bearer token 或配对确认。二维码只包含 HTTP 地址，重启服务后仍可使用。
- **没有加密或访问口令**。任何能访问该端口的设备都能调用服务，只在自己的可信局域网运行，不要开放公网/端口转发。
- Bonjour `_picax-sr._tcp` 仅用于发现附近名称；扫码或输入 IP 不依赖发现服务。
- iOS 只对私有/链路本地 IP 网段放行 HTTP，不全局关闭 ATS。传输仍使用独立 ephemeral URLSession，不继承漫画源代理、Cookie、认证或缓存。
- 手机本地仅保存电脑地址与任务分组 ID，不再保存新口令或 pin；旧版已保存的地址/任务分组 ID 可以沿用。
- `X-PicaX-Client-ID` 只是区分手机任务的普通标签，**不是身份认证**，无需注册或令牌。
- 页级恢复、大小和像素上限、PNG 解码、文件完整性与不覆盖原图的保护保留。手机进入后台只暂停传输，不取消电脑任务；完整上传并 commit 后电脑独立运行。
- 结果原子落盘、更新 SQLite 后才 ACK；重复收取不重复计数。本机自动超分仍不会删除远程部分结果。
- 同一电脑换 IP 时修改电脑启动参数，再在手机输入新地址即可继续原任务。电脑 ID 仅用于防止把旧任务错误地发给另一台电脑，不作证书认证。
- 明确取消需要电脑确认；电脑丢失/任务过期时可放弃本机跟踪，不删除已收取页。

通用 CLI 默认数据目录仍为 `%LOCALAPPDATA%\PicaX-LAN`；**这台电脑已经迁移到 `D:\折腾\picax\pic`，须使用上面的双击启动文件或显式传入 `--data-dir`，否则会打开另一套空库**。旧版 `identity` 和客户端令牌记录不再被读取，不必删除或重建。闲置任务默认保留 24 小时，`--retention-hours 168` 可延长到一周；启动时会清理过期任务。以下手动清理会删除该目录内过期任务及其图片，只在确认需要清理并停止服务后运行：

```bat
DesktopServer\start-server.cmd --data-dir "D:\折腾\picax\pic" --cleanup --retention-hours 24
```

## 协议概览（v1）

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/` | 无需认证的服务状态页，供手机浏览器排查连接 |
| GET | `/v1/capabilities` | 已配置/校验模型、可选推理精度、解码/传输限制、默认回传倍率 |
| POST | `/v1/jobs` | 幂等创建完整任务清单 |
| PUT | `/v1/jobs/{id}/pages/{page}` | 逐页规范化 RGB PNG |
| POST | `/v1/jobs/{id}/commit` | 输入完整后入队 |
| GET | `/v1/jobs/{id}` | 查询页面进度/元数据 |
| GET | `/v1/jobs/{id}/pages/{page}/result` | 完整结果 PNG，不支持 Range |
| POST | `/v1/jobs/{id}/pages/{page}/ack` | 手机持久化后确认 SHA-256 |
| POST | `/v1/jobs/{id}/retry` | 仅重试失败页 |
| POST | `/v1/jobs/{id}/cancel` | 明确取消 |

任务 UUID、固定 `e0000-p0000` 页 ID、紧凑章节/连续页索引，不能传任意文件路径。清单最多 2 MiB/4096 页，输入 PNG 64 MiB/800 万原始像素，输入单边默认 4096（可通过 `--maximum-side` 配置至 8192，包含模型对齐后边长）；输出 128 MiB/3200 万像素/单边 16384。模型对齐只用于整页边缘填充与裁切，不额外限制原生中间结果像素或预估显存。最多 8 个活跃任务。每个查询/收取/操作均校验任务归属。

能力项 `precision` 是该模型配置的默认值，`supportedPrecisions` 是当前架构/设备支持的选择列表。新任务清单可带 `precision: "float32"` / `"bfloat16"`，作为不可变任务身份的一部分；旧清单缺字段时固定为 `float32`。结果的 `precision` 必须与清单完全匹配，不能只因属于允许集合就接受。除此之外仍保留 v1 HTTP 路径、RGB PNG、SHA-256 和持久化后 ACK，SQLite 无需新增列。

### 磁盘配额与 HTTP 507

- 通用启动默认单任务预估配额 **8 GiB**、全部保留任务合计 **16 GiB**；可用 `--job-quota-gib 32 --total-quota-gib 64` 调整，要求两者为正整数且单任务不大于总配额。本机上文的双击启动文件已配置为 **32 / 64 GiB**。
- 配额不是 PNG 实际压缩大小：逐页预留 `2 × 输入 PNG 字节数 + 输出宽 × 输出高 × 4 + 64 KiB`，包含重复上传临时文件和保守的输出空间。因此几百页漫画即使源文件不大，也可能超过旧版 8 GiB 单任务上限。
- **单任务超限**时，即使清空全部旧任务也不会解决；需拆分任务或增大 `--job-quota-gib`。**总配额超限**才与旧任务占用有关；已收取和取消的任务在文件被清理前仍计入配额，仅在手机移除记录不会释放电脑空间。
- 仍会单独检查数据所在磁盘的实际剩余空间，并保留至少 128 MiB 余量。增大配额不会绕过实际空间检查，也不改变解码/传输限制或实际显存容量；调整配额本身不会删除旧图片，启动时原有的过期任务清理规则仍适用。
- HTTP 507 分别显示单任务预估/上限、总预留/上限或实际磁盘剩余空间，不再一律提示清理旧任务。修改配额或更新电脑代码后需重启服务，手机 IPA 不用更新。

## 验证命令

轻量 stdlib 回归，不导入 Torch、NumPy、Pillow 或加载模型：

```bat
python -I -B DesktopServer\tests\test_contracts.py
```

HTTP 传输集成回归（使用已安装的 FastAPI/Pillow 等传输依赖，不加载模型，供 CI 运行）：

```bat
DesktopServer\.venv\Scripts\python.exe -I -B DesktopServer\tests\test_http.py
```

显式真实模型验证（只在授权后运行；输出目录必须新/空）：

```bat
DesktopServer\.venv\Scripts\python.exe -I -B DesktopServer\validate_local.py --weights-dir D:\PicaX-weights --output-dir D:\PicaX-local-check --models fdat-m fdat-xl hat-l --accept-noncommercial-license
DesktopServer\.venv\Scripts\python.exe -I -B DesktopServer\validate_transport.py --weights-dir D:\PicaX-weights --output-dir D:\PicaX-https-check --model fdat-xl --accept-noncommercial-license
```

`validate_local.py --source <你自己的页面>` 可替换生成图，不修改源文件。输出 PNG 的“不同于 Lanczos”仅是排除假 AI 的执行检查，不代表更好看。

CI 的轻量 Windows/Linux HTTP 回归不加载模型；Swift/XCTest 由既有 iPhone Actions 构建运行。真实 CUDA 不会在每次 push 自动测试，也不会默认在用户本机运行。
