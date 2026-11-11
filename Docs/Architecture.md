# 项目架构与电脑超分协议

[首页](../README.md) · [开发指南](Development.md) · [电脑部署](LanSuperResolution.md) · [HAT 优化](HATOptimization.md)

## 组件边界

```text
PicaX / SwiftUI
  ├─ 漫画源客户端 → 来源网络/代理 → 浏览、阅读、下载库
  ├─ 本机画质增强 → 传统滤镜 或 可选 Core ML 模型
  └─ LAN 超分协调器
       ├─ 本地任务日志、源下载保留、前台传输
       └─ 可信 LAN HTTP
            └─ DesktopServer / FastAPI
                 ├─ 固定模型/清单/PNG/容量校验
                 ├─ JobStore → SQLite + 每页 source/result 文件
                 └─ Worker 监督线程 → 单个 spawn 模型进程
                      └─ PyTorch Predictor → 同一整页模型
                           └─ HAT 时安装实例级窗口调度适配器
```

- 手机负责选择已下载原图、规范化上传、记录任务、下载并验证结果、生成独立超分下载记录；完整 commit 后电脑可独立运行。
- 电脑负责模型身份核验、原生倍率推理、结果量化/可选降采样、持久化和恢复；不获取漫画源账号，不替手机登录网站，不接收远程模型/代码。
- 手机 Core ML 与电脑 CUDA 是两条独立推理路径，不能用其中一条的测试为另一条背书。手机自动超分仍使用本机执行器。
- HTTP 明文、无认证；客户端分组 ID 只能用于防止普通误操作，不是对同网络恶意设备的权限隔离。见[安全说明](../SECURITY.md)。

## 代码职责

| 层 | 主要文件 | 约束 |
|---|---|---|
| 手机 UI | `LanSuperResolutionView.swift` | 展示模型能力、精度、倍率、任务状态 |
| 手机编排 | `LanSuperResolutionCoordinator.swift` | 保留原下载、不可变清单、上传/收取、前后台恢复 |
| 手机契约/文件 | `LanSuperResolutionModels.swift`、`LanSuperResolutionFiles.swift`、`LanSuperResolutionJournal.swift` | 模型允许列表、大小/解码/hash、持久化后 ACK |
| 手机传输 | `LanSuperResolutionClient.swift`、`LanSuperResolutionDiscovery.swift` | 独立 URLSession、私有 literal IP、发现不等于认证 |
| 服务入口 | `DesktopServer/launch.py`、`cli.py`、`identity.py` | 参数先校验、固定存储目录、恢复/清理、地址/Bonjour |
| 服务 HTTP | `server.py`、`protocol.py` | 有界 body、严格 JSON/PNG/模型契约、错误码 |
| 存储 | `jobs.py` | SQLite WAL/FULL、幂等、固定路径、配额/恢复 |
| 进程监督 | `worker.py` | 一个模型进程，模型/精度切换先释放旧进程，超时/失败重建 |
| 推理 | `inference.py`、`hat_memory.py`、`models.py` | 固定权重/精度/原生倍率，有限值和输出检查，无隐式换模型 |

上述 Swift 文件位于 `PicaX/Services/LanSuperResolution/`，UI 除外。不能只复制 Python 包：权重核验/反射填充还调用受信任的 `BuildScripts/SuperResolution/` 辅助逻辑，但电脑运行不执行模型转换。

## 任务和页面生命周期

1. 手机为普通下载记录保留源，生成 UUID 任务与紧凑连续页清单。模型 hash、原生/回传倍率、可选精度、输入尺寸/字节/SHA 都是任务身份。
2. `POST /v1/jobs` 幂等创建。相同 ID + 相同清单返回已有状态；相同 ID + 不同清单是冲突。先计算磁盘预留与实际剩余空间，再建任务。
3. 逐页 `PUT` 上传到固定 `source.part`。长度、PNG、尺寸、SHA 都核验后，flush/fsync 并原子改为 `source.png`，页状态变为 uploaded。丢响应后的重复上传不会重置已完成页。
4. 全部源上传完才 commit 入队。单监督线程按任务/页顺序领取工作；只有一个 GPU 模型进程，同一时刻不并发两个页面或两个模型。
5. Predictor 以同一精度执行原图整页模型，写 `result.part`，返回形状、SHA 和诊断元数据。父进程再次验证结果、fsync、原子改为 `result.png`，再提交成功页状态。
6. 手机下载完整 PNG，验证响应/元数据/hash/尺寸，原子持久化为新的超分下载记录；此后才 ACK。重复下载/ACK 不应重复计数或覆盖原图。
7. 全部页面成功时任务 completed；有失败页则 partial；全部持久化 ACK 后 acknowledged。cancelled 是显式请求，不能把“手机进入后台”当取消。

常见任务状态：`uploading → queued → running → completed/partial → acknowledged`，以及显式 `cancelled`。页状态：`missing → uploaded → running → succeeded/failed`。不是每条任务都必然走过所有状态；重试/恢复会重新计算状态，参见实现与测试，不靠 UI 文案写数据库。

### 恢复与清理

- 启动 `recover()` 只承认 hash/数据库一致的已提交结果；固定 `.part` 文件不是权威结果，会被清理。
- 被异常中断、但完整源仍存在的页面可重排队；源缺失需要重新上传。已标 failed 的页不会被启动恢复悄悄改为成功，需要显式重试。
- 优雅停止也可能将当前页记为“server stopping”失败；不承诺 Ctrl+C 零重算。完成任务后升级最安全。
- 同一 `--data-dir` 保留 serverID，换 IP 不换身份；换数据目录会得到另一套库。serverID 只防误连，不是认证。
- 默认保留 24 小时，启动时清理过期且非 queued/running 的任务及文件。ACK 不立即释放电脑磁盘；客户端移除跟踪也不等于电脑清理。
- 只读排查不要构造 `JobStore`，不要运行 `recover/cleanup`；备份应在服务停止后完整复制数据目录，不公开真实数据库。

<a id="protocol"></a>
## HTTP v1 协议

这里只列稳定契约，具体 key/类型/边界以 `protocol.py`、Swift 类型与契约测试为准。服务关闭了自动 OpenAPI/Swagger 页面，不把 `/docs` 当成部署验证入口。

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/` | 服务健康；不代表模型已就绪 |
| GET | `/v1/capabilities` | 模型 ready、默认/支持精度、倍率、传输限制 |
| POST | `/v1/jobs` | 严格 JSON 清单，幂等创建 |
| PUT | `/v1/jobs/{id}/pages/{page}` | 完整 RGB PNG，尺寸/长度/hash 必须与清单一致 |
| POST | `/v1/jobs/{id}/commit` | 所有输入完整后入队 |
| GET | `/v1/jobs/{id}` | 页状态、错误和成功结果元数据 |
| GET | `/v1/jobs/{id}/pages/{page}/result` | 完整 PNG，无 Range；含 `X-Content-SHA256` |
| POST | `/v1/jobs/{id}/pages/{page}/ack` | `{"sha256":"..."}`，仅在手机持久化后发送 |
| POST | `/v1/jobs/{id}/retry` | 重排部分失败任务的失败页，不重算成功页 |
| POST | `/v1/jobs/{id}/cancel` | 显式取消 |

- `Content-Type`：JSON 请求为 `application/json`，上传为 `image/png`；不接受压缩 body。JSON 拒绝重复 key 和非有限数。
- `X-PicaX-Client-ID` 是普通任务分组标签，不是秘密。省略的手工客户端共用 `lan` 分组；不应拿它隔离不可信租户。
- 任务 ID 为规范 UUID，页 ID 固定 `e0000-p0000` 形式；不能传任意路径。上传内容不决定服务端文件名。
- 清单最多 2 MiB/4096 页；输入/回传限制与配额见[部署教程](LanSuperResolution.md#limits)。`maximumInputPixels` 是解码配置，不是模型显存保证。
- `precision` 缺失的旧任务固定 FP32；新任务可显式 `float32` 或 `bfloat16`。结果必须与清单精度完全相同，不是“只要属于允许集合”就能接受。
- `ready` 表示加载与身份核验成功，不代表任意尺寸可推理。能力里不包含全部页级诊断；成功页 `result` 才有实际实现和计时。

常见错误码：400/422 契约错误、404 任务不存在或分组不符、409 任务/精度冲突、410 结果已失效、413 容量超限、415 内容类型/编码不接受、429 队列/并发繁忙、503 模型未就绪、507 磁盘配额或实际空间不足。看响应 `error`，不要把所有 507 都解释为“删除旧任务”。

## 模型与数值边界

- 固定模型 ID、SHA、架构、RGB 通道、原生倍率、对齐同时核验。模型文件后缀和历史 ID 不说明实际 dtype。
- 外侧 reflect 对齐、整页调用、完整 native 输出形状和有限值检查必须保留；OCAB 内部展开使用原模型的 zero padding，不得混用。
- 4× 模型回传 2× 是原生 AI 后 Lanczos；不会缩小输入以躲开 OOM。实际 CUDA 分配失败与传输/解码限制分别报告。
- HAT 适配器仅安装到模型实例，严格依赖 Spandrel 0.4.2，不修改第三方包、全局类或 checkpoint。详见[HAT 优化说明](HATOptimization.md)。
- 输出先按有界行带 CPU → FP32 量化，保留原舍入/裁切语义；不能把 CPU 测试通过当作 BF16 CUDA 完全等价的证明。

## 修改时不能破坏的契约

1. 原下载和原图不可覆盖，失败/取消不能标为成功。
2. 模型、精度、倍率与清单身份固定，旧任务不因 CLI 新默认而改变。
3. 文件结果和数据库一致后才对外成功；客户端持久化后才 ACK。
4. 上传/查询/结果都保持有界校验；分组不是认证，不扩大部署到不可信网络。
5. 新结果诊断字段可选、向后兼容；当前 allocated/reserved 与历史 peak 不混用。
6. 不以关闭检查、提高阈值、隐式 CPU/模型/精度回退来隐藏失败。

协议、状态机、Swift 与 Python 任一侧改变，按[测试矩阵](Development.md#tests)同时验证对应另一侧。测试使用临时目录/合成图片，永远不借用真实用户库。
