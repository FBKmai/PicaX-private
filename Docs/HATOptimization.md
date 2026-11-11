# HAT-L 整页显存优化与验证记录

[首页](../README.md) · [部署教程](LanSuperResolution.md) · [开发与测试](Development.md#tests)

## 当前交付配置

本仓库在同一 HAT-L checkpoint 上调度内部独立注意力窗口，降低中间张量峰值，**不是换模型、缩小原图、把漫画切成独立小图超分再拼接，或提前拒绝大图**。

| 项目 | 固定值/默认值 |
|---|---|
| 代码基线 | HAT 最终优化提交 `60e5c374e208f53563653c950f3324a249151789`，默认分支包含它 |
| 模型 ID | `illustrationjanai-v3detail-hat-l-4x-float32`，后缀是历史身份，不代表实际 dtype |
| checkpoint | `4x_IllustrationJaNai_V3detail_HAT_L_28k_bf16.safetensors` |
| SHA-256 | `38c00c9ff871ae292617ae1127edc150f81c4e0f8f98685e48ff9c9cd87fba3b` |
| 允许列表/许可 | `DesktopServer/picax_lan/models.py`；the-database / MangaJaNai 3.0.0，CC-BY-NC-4.0 |
| 原生倍率/对齐 | 原生 4×、输入 reflect 对齐 64、输出裁回原页倍率 |
| 推荐已验证路径 | `--model-precision hat-l=bfloat16 --hat-window-batch 128 --hat-attention-backend eager` |
| 实现标记 | `attentionImplementation = hat-window-batched-v2` |

HAT 适配器也支持 FP32，但本文大页性能对照是 BF16；不能将这些数值当作 FP32 数据。通用 CLI 仍默认 FP32；教程显式设置 BF16。`--hat-window-batch 0` 是原版诊断路径，不是优化或自动回退。

## 改了什么，没改什么

实现位于 `DesktopServer/picax_lan/hat_memory.py` 和 `inference.py`。

1. **注意力按窗口分批。** 同一 query 可见的 K/V 不变，普通/移位注意力保持原缩放、QK、relative-position bias、有限值 `0 / -100` mask、softmax、V 顺序。每次 attention score 的窗口数不超过批次。
2. **紧凑 shift mask。** 保存 `[num_windows, window_tokens]` 区域标签，每批才展开原来的 mask，不生成全页稠密 N×N mask。
3. **有界 OCAB K/V。** 整页 norm/QKV 保留；`Tensor.unfold` 仅创建网格视图，先 gather 当前有限窗口再物化，禁止先对整页 `nn.Unfold` 后再切批。OCAB 边缘仍为原版**零填充**，不同于输入外侧 reflect。
4. **保留完整线性 GEMM 形状。** QKV 和输出 projection 不按窗口拆小。真实 BF16 对照发现，改变 GEMM 行数可能选择不同 CUDA 内核并改变舍入；v2 只分批二次规模的注意力运算。
5. **有界输出临时缓冲。** 最多 128 行从 GPU 搬到 CPU，再转 FP32/clamp/rint/量化，填入预分配 uint8 图；保留完整 native 输出形状与有限值检查、PNG 舍入/裁切、Lanczos 回传。
6. **有条件的页尾缓存维护。** 在编码完成且输出张量释放之后，仅当 reserved 超过设备物理显存 80%，且至少 1 GiB 是闲置缓存时释放空闲块。普通 cache 继续复用；模型不重载，窗口循环内不做同步或清缓存。

整页卷积、全局通道平均池化、移位/反移位、残差、MLP、上采样、checkpoint/模型 ID/倍率/精度保持不变。适配器严格限定 Spandrel **0.4.2** 和实际 HAT 结构，以实例级 MethodType 安装；不修改 site-packages 或第三方全局类，training/开启梯度的调用会被拒绝。

**80% 条件不是 VRAM 分配上限**：不限制活张量、不估算后拒绝输入、不调用 `set_per_process_memory_fraction`。仍可能有单页共享显存峰值，不能宣称完全零 spill 或任意尺寸都可用。

### 为什么峰值能降低

以 960×1600 对齐输入、6000 个窗口、16×16 query、24×24 K/V、6 heads、BF16 为例：原版单个 OCAB score `[6000,6,256,576]` 约 **9.888 GiB**；128 窗口的同一张量约 **216 MiB**。这只是一个中间张量，**不是总显存预测**。整页特征、QKV、上采样、输出以及 allocator 缓存仍占用内存并随输入增长。

## 真实 CUDA/BF16 验证：2026-11-11

以下为维护过程中取得的**脱敏测量摘要**，不是承诺硬件下限或独立公开数据集基准。私人原图、输出、任务 ID/数据库、原始报告和日志不随仓库发布，其他人不能直接取得原 34 页复跑；可使用自己的合法样本验证。

### 环境与方法

- Windows 11，NVIDIA RTX 5090 D v2，总显存 24455 MiB；系统 RAM 约 30.8 GiB。
- PyTorch `2.11.0+cu128` / CUDA 12.8 / Spandrel `0.4.2`，同一允许列表权重、BF16、完整输入、原生与回传均 4×。
- 主样本为 34 页，最大原页 **960×1616**；另有 2 张其他页与 2 次重复探针，共 38 次最终验证。只运行一个模型 worker，不与另一模型并发。
- 旧耗时来自这些页此前保存的生产逐页记录；新版使用相同源文件并验证 SHA，顺序重新处理，逐页与保留的旧输出比较。
- 预先设定 8-bit PNG 差异门槛：max ≤2/255、mean ≤0.1/255。失败即停，未通过修改实现，不放宽阈值。
- `seconds` 为解码、准备、模型、量化/编码及条件缓存清理的逐页总耗时之和，不含模型加载、额外对照 PNG 解码或手机传输。不是任务创建到最终 ACK 的墙钟。

### 最终结果

| 指标 | 旧版历史记录 | 最终优化版 |
|---|---:|---:|
| 34 页逐页总耗时之和 | 1829.968 s（约 30 分 30 秒） | 397.110 s（约 6 分 37 秒） |
| 平均每页 | 53.823 s | 11.680 s |
| 中位每页 | 52.633 s | 11.617 s |
| 单页峰值 allocated 范围 | 24.028–29.727 GiB | 6.402–7.905 GiB |
| 34 页耗时比 | 基准 | **约 4.61×** |
| 38 次最终 PNG 对照 | 旧结果基准 | 全部 max=0、mean=0，8-bit 像素一致 |

同一机器后续恢复了另一个队列的 149 页，全部成功并由手机 ACK；其结果均记录 BF16 与 v2，实现了长队列运行的补充证据。它不是另一显卡/其他模型的验证，也不是所有漫画画质验收。

### 功耗、共享内存与缓存

主 34 页按每秒采样汇总（393 个样本，可能漏掉更短峰值，且页内包含后处理）：

- 平均 GPU 功耗约 **387.9 W**，峰值 **470.38 W**；没有修改驱动、频率或功耗上限。
- 进程 shared GPU memory 平均约 **0.174 GiB**、峰值 **3.271 GiB**；不是始终为零。
- 整机 GPU 显存使用采样峰值 **23861 MiB**，包含非 PyTorch/桌面等占用，不能与 `peakAllocatedBytes` 混用。
- 系统可用 RAM 最低约 **13.98 GiB**。
- 主 34 页释放输出后的 live allocated 约 **90 MiB**，没有逐页累计。38 次共 14 次触发条件 cache 维护，总耗时约 **1.844 s**；触发后 reserved 约 **0.100 GiB**，模型仍驻留。

此前旧服务运行中的短采样约 160 W、shared 约 14.4 GiB，但它来自另一组早上的活跃页，**不是上述 34 页的同步旧版功耗 A/B**。不能据此计算严格能效倍率。allocated 已包含在 reserved 内，两者不相加，也都不是 WDDM 物理驻留量。

### 保留失败经验，避免再次引入

- v1 将线性层也分批，小模型 CPU 测试通过，但第一张真实 BF16 页 max PNG 差异达到 13/255，按门槛停止；恢复完整 QKV/proj GEMM 形状后消除该差异。
- 单独分批注意力已降低 live 峰值，但混合尺寸下 cache 可持续累计到 shared，拖慢后页。串行短 A/B 确认条件页尾释放闲置块有效之后才集成，未把“每页无条件清缓存/重载模型”作为加速策略。
- PNG 对照相同只是该组最终 8-bit 结果相同，不是所有内部浮点张量逐 bit 相同，也不是所有设备/输入的数学等价证明。

## 自动化证据与尚未覆盖项

基线提交 `60e5c37` 的 [Actions 42946842512](https://github.com/FBKmai/PicaX-private/actions/runs/42946842512) 已通过：

- Windows/Linux stdlib 契约与真实 loopback HTTP（无 AI 权重）；
- Linux CPU 小型 HAT 原版/优化数值与有界 matmul/gather，FP32 `atol=rtol=2e-5`；
- 输出量化、mask、OCAB padding/order、尾批和完整线性 shape 等回归。

**没有声称已覆盖**其他显卡/驱动、所有图片尺寸、所有权重、训练模式、FP16/FP8、真实 SDPA 后端或所有手机网络组合。性能数字是有限样本的单机历史对照，不排除时间/系统背景负载的影响。

`--hat-attention-backend sdpa` 为实验路径：真实参数检查 fused backend，head_dim 30 补零到 32、保持原 scale 并裁回，强制排除 MATH fallback。不支持会明确报错并提示 eager。CPU 受控模拟不是 fused CUDA 证据，不能把它设为默认或宣称已获得 FlashAttention 加速。

## 自己复核或修改实现

1. 先核对正确源码、checkpoint SHA、版本与实际 precision，按[部署教程](LanSuperResolution.md)处理一张小图。
2. 查看成功页结果：`attentionImplementation`、`attentionWindowBatch`、`attentionBackend`、`precision`、`nativeScale` 与 `deliveryScale`。
3. 需要原版对照时，**仅选可负担的小图**显式用 `--hat-window-batch 0`，分别写入新的隔离目录；不要用大原页把生产机器再次推入分页。
4. 对照必须使用同一原图、同一权重、精度、倍率、输出裁切与舍入。阈值在观察之前选定，失败时保留报告并修实现，不改门槛掩盖差异。
5. 重复/交替尺寸检查页尾基线，分开记录 allocated/reserved、WDDM dedicated/shared、进程/系统内存、页耗时。128 不保证在所有设备最快；64/256/512 的比较是新的手动实验，不是已经完成的 sweep。
6. 真实验证是重型操作，避开生产 GPU 任务；命令入口和分层验证见[开发指南](Development.md#tests)。所有输出保存在自己的隔离目录，公开分享前移除私人内容。

阶段元数据包括 `modelSeconds`（CUDA 事件）、`modelWallSeconds`（模型调用/有限值校验墙钟）、`postprocessSeconds`、`memoryStages.pageStart/modelEnd/outputReleased`；触发缓存维护时新增 `cacheMaintenance` 与 `memoryStages.cacheReleased`。peak 不因当前清理而回写为零。源码更新不会热替换运行 worker，应在任务完成、安全停止后重启；不需要为这项优化重打手机 IPA。
