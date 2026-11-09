# 局域网电脑 AI 超分

## 范围与状态

- 下载库多选**已下载的漫画图片** → **电脑超分**，或在“设置 → 下载 → 局域网电脑超分”配对、查看任务。
- 保留“本机超分”和下载后自动超分；自动超分仍在手机运行，不会悄悄改到电脑。
- 结果独立保存到“下载 → 超分”，不覆盖源下载。可沿用下载库的阅读、ZIP 和 PDF 导出。ZIP 附带模型来源/许可说明，完整任务还附每页推理元数据；PDF 只包含图片页。
- 电脑使用真实 PyTorch/CUDA 模型，没有普通插值冒充 AI、隐式 CPU 回退或失败后换模型。
- 参考 LANDrop 的发现、配对和独立传输思路；**不是 LANDrop 协议实现，不与 LANDrop 互通，也不要求安装 LANDrop**。
- Windows 电脑上的真实模型和 HTTPS 服务链路已实测，见下文。手机端编译、XCTest 和 IPA 状态以对应 Actions 运行及交付报告为准；iPhone 真机跨局域网端到端仍待验证。

## 当前电脑已经装好的环境

2026-11-09 本地安装到隔离目录，没有改全局 Python、PATH、注册表或防火墙：

- Python 3.11.18：`D:\折腾\picax\PicaX-LAN-runtime.7sd1c8sq\python`
- 项目环境：`DesktopServer\.venv`
- 权重：`D:\折腾\picax\PicaX-LAN-runtime.7sd1c8sq\weights`
- PyTorch `2.11.0+cu128`、CUDA 12.8、Spandrel 0.4.2。
- GPU：RTX 5090 D v2，24455 MiB；驱动 616.64。
- 本机局域网地址：`192.168.5.8`（地址变化后需要处理证书与重新配对）。

已配置的快捷启动文件：

```text
D:\折腾\picax\PicaX-LAN-runtime.7sd1c8sq\launchers\start-picax-server.cmd
```

验证结束后服务已停止，不会常驻占用 GPU。双击上述文件即可启动并显示一次性配对码。保持终端运行；Ctrl+C 停止。不要分享配对码截图。

也可在仓库目录的 Windows 终端执行：

```bat
DesktopServer\start-server.cmd --host 192.168.5.8 --weights-dir "D:\折腾\picax\PicaX-LAN-runtime.7sd1c8sq\weights" --models fdat-xl hat-l fdat-m --pair --accept-noncommercial-license
```

若 Windows 弹出网络访问询问，仅允许你信任的**专用网络**。程序不会自动修改防火墙、开启公网端口、UPnP 或端口转发。手机和电脑须能互相访问同一局域网；访客 Wi-Fi/AP 隔离可能阻止连接。

## 模型与倍率

| CLI 名称 | 模型 | 原生倍率 | 可选回传 | 定位 |
|---|---|---:|---|---|
| `fdat-xl` | IllustrationJaNai V3detail FDAT-XL | 4× | 2× / 4× | 默认，已实测普通漫画页尺寸 |
| `hat-l` | IllustrationJaNai V3detail HAT-L | 4× | 2× / 4× | 高显存细节档，较大整页可能被预算拒绝 |
| `fdat-m` | IllustrationJaNai V3detail FDAT-M unshuffle | 2× | 2× | 快速档、手机模型对照基线 |
| `dat2` | IllustrationJaNai V3denoise DAT2 | 4× | 2× / 4× | 允许列表候选；本机未下载/验证，不会显示为已就绪 |

默认回传 **2×**。4× 模型回传 2× 时，先运行真实原生 4× AI，再用 Lanczos 缩小到 2×；并非普通放大代替 AI。FP16/BF16 是部分上游**存储**格式，当前推理统一 FP32，关闭 TF32；未默认启用半精度或编译优化。

首版只开放**整页推理**。不自动退回之前存在上下文/接缝问题的 128 像素分块，不缩小原图来规避预算，也不保证所有页面能处理。模型越重不意味着文字、网点或线条一定更忠实。请用自己的少量页面确认画质。

### 权重与来源

来源：[the-database / MangaJaNai 3.0.0](https://github.com/the-database/MangaJaNai/releases/tag/3.0.0)。全部仅限 **CC-BY-NC-4.0 非商业用途**；作者 the-database。[许可全文](https://creativecommons.org/licenses/by-nc/4.0/)。应用不提交权重到 git。

固定文件名、架构、倍率和 SHA-256 位于 `DesktopServer/picax_lan/models.py`，手机允许列表位于 `LanSuperResolutionModels.swift`，Python 回归测试比较二者。个体权重散列最初来自固定版本的第三方[转换器模型注册表](https://github.com/imxieyi/waifu2x-ios-model-converter/blob/68e3f51517e04433164c09d8505a409e26477905/known_models.yaml)，不是声称上游作者签名。下载工具还核对 GitHub release API 提供的上游归档 SHA-256，再核对归档内每个指定权重。

下载示例（目标必须为新/空目录；不解压或运行归档中的脚本）：

```bat
DesktopServer\.venv\Scripts\python.exe -I -B DesktopServer\fetch_models.py --models fdat-xl hat-l fdat-m --destination D:\PicaX-weights --download-parent D:\PicaX-downloads --accept-noncommercial-license
```

需要代理时，在当前终端设置 `HTTPS_PROXY=http://127.0.0.1:7890`。服务的推理不需要访问互联网，不接收手机上传的模型、Python 代码或 pickle。

## 本机真实验证结果

诊断图包含文字、细线和彩色区域；不是用户漫画，不构成主观画质或文字保真度认证。单 GPU worker 串行运行；每个模型在独立 spawn 进程加载。没有 CPU 回退。

| 模型 | 输入 | 回传 | 推理/编码等总耗时 | PyTorch 峰值 allocated |
|---|---|---|---:|---:|
| FDAT-M | 1000×1500 | 2000×3000 | 0.781 秒 | 2.48 GiB |
| FDAT-XL | 1000×1500 | 2000×3000 | 15.859 秒 | 14.62 GiB |
| FDAT-XL | 256×384 | 1024×1536 | 0.547 秒 | 1.04 GiB |
| HAT-L | 512×768 | 1024×1536 | 4.297 秒 | 14.76 GiB |
| HAT-L | 256×384 | 1024×1536 | 1.047 秒 | 3.81 GiB |

测试还覆盖各模型 128×192 → 256×384。PyTorch allocated 不含桌面显示/其他进程的所有显存，不等于整机 GPU 总占用，也不是大图的保证。

实际 HTTPS → SQLite → CUDA → 收取 → SHA-256 → ACK 链路另测了 FDAT-XL：

- 连续两张 1000×1500 → 2000×3000，分别约 12.125 / 11.281 秒推理，证明后续页面不会因可复用的 PyTorch 缓存被误拒。
- 256×384 → 1024×1536 原生 4× 回传。
- 单次配对、叶证书 SHA-256 pin、上传原图、完整提交、真实 GPU worker、下载解码、散列、持久化 ACK、存储恢复全部通过。
- 测试仅监听回环地址，不改防火墙，不等同于 iPhone/真实 Wi-Fi 的端到端测试。

完整报告和 PNG：

```text
D:\折腾\picax\PicaX-LAN-runtime.7sd1c8sq\validation-first\report.json
D:\折腾\picax\PicaX-LAN-runtime.7sd1c8sq\validation-https\report.json
```

显存预算已按本机测量上调：HAT-L 不能按轻量模型估计。启动时按剩余显存进一步限制手机可见的像素上限，每页推理前再次检查；分配失败/超时会终止并重启 worker，失败信息不会伪装成功。

## 新机器安装

需要 CPython **3.11 x64**、兼容 Blackwell 的 NVIDIA 驱动和足够磁盘空间（当前 CUDA wheel 约 2.6 GiB，安装和缓存还需额外数 GiB）。不要安装到全局环境，也不要复用 macOS Core ML 的依赖。

```bat
py -3.11 -m venv DesktopServer\.venv
DesktopServer\.venv\Scripts\python.exe -I -m pip install -r DesktopServer\requirements-windows-cu128.txt
```

直接依赖固定版本，Torch/Torchvision 的官方 Windows wheel URL 带 SHA-256；`requirements-transport.txt` 不是完整的传递依赖 hash 锁文件。无 CUDA 时启动报错，不默认改用 CPU。`--device cpu` 仅为显式诊断用。

## 配对、传输与恢复

- Bonjour `_picax-sr._tcp` **只提供未经认证的发现提示**，不能更新已配对地址或证书。
- 电脑 `--pair` 显示 5 分钟、一次性、高熵配对码，包含地址、电脑 ID、TLS 叶证书 SHA-256；手机支持扫码和手动粘贴 JSON，连接前显示确认。
- TLS pin 必须和二维码一致；自签名证书仍检查 SAN/有效期。不“信任所有证书”。只允许 HTTPS 私有字面 IP，不跟随重定向。
- 配对后每台手机独立 bearer token；电脑仅存摘要。手机 token/pin 在 `WhenUnlockedThisDeviceOnly` Keychain，不进设置备份。锁屏无法读凭据时等待，不删凭据。
- 手机采用独立 ephemeral URLSession，不继承漫画源代理、Cookie、认证、缓存，不使用蜂窝。
- 页级 SHA-256、字节数、实际 PNG 尺寸、模型 ID/散列/倍率和推理来源都验证。
- **页级恢复**，不是 PNG 字节级断点续传。手机进入后台只暂停传输，不发送取消；上传完整并 commit 后电脑独立运行。
- 结果导入顺序：校验文件 → 原子落盘 → throwing SQLite 更新 → 恢复日志 → ACK。重复结果不重复加大小/页数；冲突 hash 不覆盖。
- 本机自动超分队列不会删除远程部分结果；同一本下载被远程任务占用时，不允许新下载或本机超分修改来源。
- 明确“取消任务”需要电脑确认；电脑丢失/任务过期时可**放弃本机跟踪**，这不等于取消电脑，也不删除已收取页。

命令：

```bat
DesktopServer\start-server.cmd --list-clients
DesktopServer\start-server.cmd --revoke-client <手机UUID>
DesktopServer\start-server.cmd --cleanup --retention-hours 24
```

默认数据目录为 `%LOCALAPPDATA%\PicaX-LAN`。保管其中私钥/数据库，不放到公开同步目录。闲置任务默认保留 24 小时，`--retention-hours 168` 可延长到一周；清理在启动或显式 `--cleanup` 时执行。不要在服务运行期间用另一进程操作同一数据目录。

私有 IP 改变时不自动换证书：固定地址/ DHCP 保留优先。确需更换时先停止服务，备份身份文件，明确重建身份并在手机重新配对；不要只改 pin 绕过不匹配。

## 协议概览（v1）

| 方法 | 路径 | 用途 |
|---|---|---|
| POST | `/v1/pair` | 唯一无需 bearer 的短期配对入口 |
| GET | `/v1/capabilities` | 已配置/校验模型、预算、默认回传倍率 |
| POST | `/v1/jobs` | 幂等创建完整任务清单 |
| PUT | `/v1/jobs/{id}/pages/{page}` | 逐页规范化 RGB PNG |
| POST | `/v1/jobs/{id}/commit` | 输入完整后入队 |
| GET | `/v1/jobs/{id}` | 查询页面进度/元数据 |
| GET | `/v1/jobs/{id}/pages/{page}/result` | 完整结果 PNG，不支持 Range |
| POST | `/v1/jobs/{id}/pages/{page}/ack` | 手机持久化后确认 SHA-256 |
| POST | `/v1/jobs/{id}/retry` | 仅重试失败页 |
| POST | `/v1/jobs/{id}/cancel` | 明确取消 |

任务 UUID、固定 `e0000-p0000` 页 ID、紧凑章节/连续页索引，不能传任意文件路径。清单最多 2 MiB/4096 页，输入 PNG 64 MiB/800 万像素，输出 128 MiB/3200 万像素/单边 16384；还需满足模型对齐、原生输出和显存上限。默认单任务磁盘配额 8 GiB、总配额 16 GiB、最多 8 个活跃任务。每个查询/收取/操作均校验任务归属。

## 验证命令

轻量 stdlib 回归，不加载模型：

```bat
python -I -B DesktopServer\tests\test_contracts.py
DesktopServer\.venv\Scripts\python.exe -I -B DesktopServer\tests\test_http.py
```

显式真实模型验证（只在授权后运行；输出目录必须新/空）：

```bat
DesktopServer\.venv\Scripts\python.exe -I -B DesktopServer\validate_local.py --weights-dir D:\PicaX-weights --output-dir D:\PicaX-local-check --models fdat-m fdat-xl hat-l --accept-noncommercial-license
DesktopServer\.venv\Scripts\python.exe -I -B DesktopServer\validate_transport.py --weights-dir D:\PicaX-weights --output-dir D:\PicaX-https-check --model fdat-xl --accept-noncommercial-license
```

`validate_local.py --source <你自己的页面>` 可替换生成图，不修改源文件。输出 PNG 的“不同于 Lanczos”仅是排除假 AI 的执行检查，不代表更好看。

CI 的轻量 Windows/Linux HTTP 回归不加载模型；Swift/XCTest 由既有 iPhone Actions 构建运行。真实 CUDA 不会在每次 push 自动测试，也不会默认在用户本机运行。
