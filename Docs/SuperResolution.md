# 实验性 Core ML 超分：来源、转换与验证

## 当前状态和边界

首轮只支持用户**显式前台**试处理当前页或少量页面，不做整章、后台任务或自动逐页运行；原图必须保留。本仓库**不提交这两个模型的权重、`.mlpackage`、`.mlmodelc` 或现成有效 descriptor**，因此默认的 push 构建没有模型，AI 功能会显示缺少模型/不可用，而不是偷偷用旧锐化冒充 AI。另有一个手动、仅限个人非商业使用的彩色模型打包入口：工作流从已验证的 Actions artifact 下载彩色 `.mlpackage`，核对权重/包 hash 后，仅在该次构建的独立副本中把 `validated` 置为 true；黑白模型仍不打包（许可冲突未解决）。

截至 2026-11-08，最新构建为 [Actions run #42462504310](https://github.com/FBKmai/PicaX-private/actions/runs/42462504310)（commit `13d1d0813b176f864de98c8044c7fa5b201a99c8`）：Xcode 27.1 / iOS 27.1 SDK，175 项 iOS 模拟器测试及 18 项 Python 工具测试通过。未签名 IPA `PicaX-iPhoneDuo-unsigned-15` 的 SHA-256 为 `2e3b7aaee9ea171bdb29a46fe5085f495c322f3752fb56e898cef273408d95c7`；其资源审计仍为 `engineering-build-no-models`，不包含两个 `.mlpackage`，安装后 AI 功能仍会显示模型缺失。上一版构建 #6 的旧记录不再代表当前代码。

本机为 Windows / Python 3.9，无 Xcode/macOS。已下载官方原始归档、安全提取所选黑白和彩色 checkpoint 并独立核对下表的文件 hash；已完成真实权重加载、Core ML 整页转换和 macOS CPU 预测；**run 42461503524 的五个尺寸与三种 compute unit 隔离验证全部通过（见下文表格），但 iPhone Duo 真机画质/耗时/内存验收仍未完成**。手动 `Validate real Core ML super-resolution candidates` 工作流负责在隔离的 macOS runner 上执行真实转换；其产物始终为未批准状态，不会自动进入 IPA 或修改原 artifact 的 `validated`。个人打包入口只在目标构建目录的副本上批准彩色模型，见“个人非商业彩色模型的打包入口”。任何对外分发必须先核实具体权重许可；V1 尤其存在下面的许可冲突。

## 锁定来源和候选

- 黑白：[MangaJaNai V1 2× release 1.0.0](https://github.com/the-database/MangaJaNai/releases/tag/1.0.0)，tag 对应提交 [`5e9db8e5a26ef9336d6bc6baeebbe3b3ac740963`](https://github.com/the-database/MangaJaNai/tree/5e9db8e5a26ef9336d6bc6baeebbe3b3ac740963)。ESRGAN（Spandrel 中称 ESRGAN/RRDB）。上游的 [README](https://github.com/the-database/MangaJaNai/blob/d2f8f92dc75303c557ca2d7a507913eff512ff32/README.md) 指出 1200、1300、1400、1500、1600、1920、2048 是分别优化的**原始整页高度**，非屏幕宽度、下采样尺寸或 tile 高度。按实际要试的样本只转换所需档位，不预装全部；长条、裁图、异常比例先跳过。上游未在这里给出精确分档边界：可参考离原始整页高度最近的档位人工划定范围，但这不是上游保证的最佳阈值；应用实际只按已批准 descriptor 中的明确、不重叠范围匹配，无匹配时跳过。
- 彩色：[IllustrationJaNai V3detail 2× FDAT M unshuffle release 3.0.0](https://github.com/the-database/MangaJaNai/releases/tag/3.0.0)，tag 对应提交 [`d2f8f92dc75303c557ca2d7a507913eff512ff32`](https://github.com/the-database/MangaJaNai/tree/d2f8f92dc75303c557ca2d7a507913eff512ff32)。V3detail 保留纹理、**不清除**半色调噪声，某些图可能生成过多纹理；不能预断效果胜出。[Spandrel 0.4.2 的 FDAT 架构](https://github.com/chaiNNer-org/spandrel/blob/724cca389f28c38e1050689d4862a452fd644484/libs/spandrel/spandrel/architectures/FDAT/__init__.py)声明 `img_range=1` 并检测 unshuffle。
- 配置参考及下表的**逐个权重文件** SHA-256 来自独立第三方转换器 [`known_models.yaml`，提交 `68e3f51517e04433164c09d8505a409e26477905`](https://github.com/imxieyi/waifu2x-ios-model-converter/blob/68e3f51517e04433164c09d8505a409e26477905/known_models.yaml)，不是原作者签名的校验文件。对应的 [converter.py](https://github.com/imxieyi/waifu2x-ios-model-converter/blob/68e3f51517e04433164c09d8505a409e26477905/converter.py)、[model_loader.py](https://github.com/imxieyi/waifu2x-ios-model-converter/blob/68e3f51517e04433164c09d8505a409e26477905/model_loader.py)、[SPECS.md](https://github.com/imxieyi/waifu2x-ios-model-converter/blob/68e3f51517e04433164c09d8505a409e26477905/SPECS.md) 和 [requirements-janai.txt](https://github.com/imxieyi/waifu2x-ios-model-converter/blob/68e3f51517e04433164c09d8505a409e26477905/requirements-janai.txt) 给出架构/形状/精度。转换器代码许可证是 Apache-2.0，**不是模型权重许可证**；本项目脚本独立实现该路径，不运行下载的转换器。
- Spandrel [v0.4.2 tag `724cca389f28c38e1050689d4862a452fd644484`](https://github.com/chaiNNer-org/spandrel/tree/724cca389f28c38e1050689d4862a452fd644484) 的 [`MAIN_REGISTRY`](https://github.com/chaiNNer-org/spandrel/blob/724cca389f28c38e1050689d4862a452fd644484/libs/spandrel/spandrel/__helpers/main_registry.py) 已注册 ESRGAN 和 FDAT，不需 `spandrel_extra_arches` 或 release 里的旧 FDAT 补丁。另已只读检查与依赖锁文件 SHA-256 一致的 PyPI 0.4.2 wheel，确认脚本使用的顶层导出及 `SizeRequirements.check(width, height)` 存在；未安装或执行该 wheel，这只是静态接口核对，不证明真实转换可运行。
- `BuildScripts/SuperResolution/requirements-macos-arm64-py311.txt` 锁定 macOS arm64、CPython 3.11.9 的直接和传递 Python 依赖及 PyPI wheel SHA-256；核心版本为 PyTorch 2.6.0、torchvision 0.21.0、coremltools 8.3.0、Spandrel 0.4.2、NumPy 1.26.4、safetensors 0.4.5。为避免 PyTorch ≤2.5.1 的 weights-only RCE 漏洞 CVE-2025-32434，本锁定版本有意偏离上游推荐的 PyTorch 2.5.1/torchvision 0.20.1。coremltools 8.3 的已测试上限仅为 PyTorch 2.5.0，会对 2.6.0 发出版本警告；此组合的转换兼容性尚未验证，必须在 macOS 进行实测，若不兼容则阻塞而非退回有漏洞版本。在 macOS 的首轮实测中，该固定组合已成功完成两种架构的加载、转换和 CPU 预测；版本警告仍需保留，不能推断其他模型/compute unit 兼容。换架构或版本需要单独锁定并重新验证。工具链及 macOS/Xcode 版本会影响产物，不承诺不同机器逐字节相同。

| 模型文件名 | 第三方转换器公布的 checkpoint SHA-256 |
|---|---|
| `2x_MangaJaNai_1200p_V1_ESRGAN_70k.pth` | `43b784f674bdbf89886a62a64cd5f8d8df92caf4d861bdf4d47dad249ede0267` |
| `2x_MangaJaNai_1300p_V1_ESRGAN_75k.pth` | `15ca3c0f75f97f7bf52065bf7c9b8d602de94ce9e3b078ac58793855eed18589` |
| `2x_MangaJaNai_1400p_V1_ESRGAN_70k.pth` | `a940ad8ebcf6bea5580f2f59df67deb009f054c9b87dbbc58c2e452722f34858` |
| `2x_MangaJaNai_1500p_V1_ESRGAN_90k.pth` | `d91f2d247fa61144c1634a2ba46926acd3956ae90d281a5bed6655f8364a5b2c` |
| `2x_MangaJaNai_1600p_V1_ESRGAN_90k.pth` | `6f5923f812dbc5d6aeed727635a21e74cacddce595afe6135cbd95078f6eee44` |
| `2x_MangaJaNai_1920p_V1_ESRGAN_70k.pth` | `1ad4aa6f64684baa430da1bb472489bff2a02473b14859015884a3852339c005` |
| `2x_MangaJaNai_2048p_V1_ESRGAN_95k.pth` | `146cd009b9589203a8444fe0aa7195709bb5b9fdeaca3808b7fbbd5538f94c41` |
| `2x_IllustrationJaNai_V3detail_FDAT_M_unshuffle_40k_fp16.safetensors` | `8ff2ba0b970e6939f3711077f5260fcded16b8388a939a27f153c687ff5da3e0` |

上表不是 archive 的 hash，`convert.py` 不下载权重。独立的 `fetch_checkpoint.py` 只允许固定的官方发布 URL、归档大小及 hash，下载和提取目录必须各自为空、互不包含且位于项目之外；只提取所选 checkpoint，不执行归档内代码，拒绝路径穿越/链接，并将许可/README/NOTICE 条目写入来源报告。

2026-11-08 已核对：3.0.0 的 `IllustrationJaNai_V3detail.zip`（318641534 字节）实测 SHA-256 与 release API 的 `27749962bc934779f867730cdb10617e3d7475313f920a7a966c56b75dbdbeda` 相同；1.0.0 的 `MangaJaNai_V1_ModelsOnly.zip`（433383160 字节）实测为 `5156f4167875bba51a8ed52bd1c794b0d7277f7103f99b397518066e4dda7e55`，这是观察值，**不是原作者签名或 API 提供的 digest**。两归档未发现名称含 license/readme/notice/copying 的文件，这不能代替许可判断。所选 1200p 黑白权重（33709234 字节）和彩色 FDAT 权重（16198963 字节）的实际 SHA-256 均与上表相同；未加载权重或提取其他模型。

## 模型许可和分发阻塞

- **Manga V1 有冲突，不能将转换器的条目当作最终许可。** 1.0.0 tag 的上游 [LICENSE](https://github.com/the-database/MangaJaNai/blob/5e9db8e5a26ef9336d6bc6baeebbe3b3ac740963/LICENSE) 是 **CC BY-NC-SA 4.0**；仓库 [2024-06-12 的 `d373dcf7728a355bd5822d190a33162567bb4b41`](https://github.com/the-database/MangaJaNai/commit/d373dcf7728a355bd5822d190a33162567bb4b41) 将仓库 LICENSE 改为 **CC BY-NC 4.0**，而第三方转换器将 V1 权重标为 CC BY-NC 4.0。已检查实际归档目录，未发现附带许可/README/NOTICE 文件；未获得权利人确认新的许可是否明确覆盖旧 release 的 checkpoint。SA 条件不能擅自忽略。V1 descriptor 的 `license` 为明确的 `UNRESOLVED` 说明；此脚本只写项目外暂存目录，不自动放进 app bundle。**在核实确切权重授权、适用 SA/改作和预期 IPA 分发方式之前不得分发或启用。**
- **彩色 V3detail：** 3.0.0 tag 的[上游 LICENSE](https://github.com/the-database/MangaJaNai/blob/d2f8f92dc75303c557ca2d7a507913eff512ff32/LICENSE) 和转换器条目均为 [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/)。实际 release zip 中未发现附带许可/README/NOTICE 文件，分发前仍须核对实际 checkpoint 的许可、贡献者和项目/商店的分发方式；不能因为代码仓库许可证而推断商业分发权。
- 非商业条款限制以商业利益或金钱报酬为主要目的的使用；归属、许可链接、免责声明、变更标识等依适用许可保留。转换 Core ML 是修改/转换，分发时应注明原作者 the-database、原模型链接、确切许可、所做转换与修改，并履行可能适用的 SA 条款；这是工程提示，不是法律意见。未解决时仅能把模型视为未验证/不具备分发条件。

## 模型输入输出和分块

- 契约为固定 `MLMultiArray` 而不是图像特征：输入名 `input`、形状 `[1,3,128,128]`，输出名 `output`、形状 `[1,3,256,256]`，NCHW RGB、`float32` I/O、范围 `[0,1]`。脚本按上游包装 1 通道权重（RGB 求平均后复制至 3 通道），并在网络输出 clamp；具体检测到的通道/架构会记录在报告。透明度、方向和色域仍须应用独立处理和验证。
- 上游候选配置均为 `input-size: 128`、`shrink-size: 20`。这里 descriptor 的 `overlap = 20` **表示每侧裁掉的输入像素数**；不是相邻 tile 的总重叠。有效核心为 `128 - 2*20 = 88` 输入像素，邻接 tile 的输入重叠为 `40`；输出每边裁 `20*2 = 40` 像素、有效核心 `176×176`。页的最外边界使用 reflect padding（不重复边界像素），然后对有效核心按 2× 拼接。尤其需要验证小于 padding、奇数尺寸、页角和 1 像素等边界输入，不能假定任意系统的 reflect API 都具备相同行为。
- 这是上游候选配置，**不是已证实的无缝或真机画质结果**。模型尤其是注意力模型的整图结果可能与分块结果不同。2026-11-08 已完成合成页接缝/非接缝及极小页检查：单块小页通过，但两个 FP32 候选的多块页均失败（见下表），因此仍禁止批准或打包。真实漫画、色域/透明/方向及 device compute unit 验证仍待完成。
- `precision` 是 Core ML **中间计算精度**，不是输入/输出数据类型。Manga ESRGAN 上游要求 FP32，中间 FP16 曾在孤立边缘像素出现大误差；脚本拒绝 Manga FP16。彩色 FDAT 2× 上游采用 FP16 中间计算，但仅可作为候选，需分别测 FP32/FP16。FP32 不保证 ANE，速度/内存/画质取决于实际设备。
- 上游的 Spandrel 转换明确以 iOS 16 为最低目标。应用仍可保留 iOS 15.2 普通阅读，但 AI 的模型加载/推理必须限制 iOS 16+ 并在不满足时明确不可用。macOS CPU 数值预测不等于 iOS GPU/ANE 验证。

## 真实转换工作流与预先确定的数值标准

首次数值运行 [42447624740](https://github.com/FBKmai/PicaX-private/actions/runs/42447624740) 已完成真实权重加载、转换及 macOS CPU 预测：Manga 1200p FP32 的三样本最大绝对误差最高为 `0.0003440976`；彩色 FDAT FP32 为 `0.00000292063`，均通过预设转换阈值。彩色 FDAT FP16 的噪声样本平均绝对误差为 `0.0023595911`，超过 `0.5/255 ≈ 0.0019607843`，因此该候选失败（整个工作流也如实失败），不修改阈值强行通过。候选包仍为 `validated: false`；首次运行未验证接缝。

更新后的 `.github/workflows/validate-super-resolution.yml` 只对通过的 Manga 1200p FP32 和彩色 FDAT FP32 继续分块检查，不重新启用已拒绝的 FP16。固定 macOS arm64 / CPython 3.11.9 及 hash-locked wheel；每个候选使用独立输出目录，归档、权重、解释器和仓库互不混用。工作流只产生保留 7 天的私有 Actions 候选包/数值报告，不提交模型、不发布 Release、不自动批准资源。Manga 暂存范围仅为原始高度恰好 1200，不推定其他高度已验证。

第二轮真实分块运行 [42448585608](https://github.com/FBKmai/PicaX-private/actions/runs/42448585608) **失败**；小页、1×1、单行和单列均通过，但 216×344 多块合成页的结果如下（归一化 RGB 绝对误差）：

| FP32 候选 | 整页最大误差（上限 0.05） | 整页平均（上限 0.005） | 接缝区平均（上限 0.0075） | 结果 |
|---|---:|---:|---:|---|
| Manga 1200p ESRGAN | 0.37331814 | 0.01057981 | 0.02652843 | 拒绝 |
| Illustration V3detail FDAT | 0.16620493 | 0.00960159 | 0.00938205 | 拒绝 |

不能由第二轮结果单独断言是 Core ML 转换错误或单一接缝实现错误。第三轮同窗口诊断 [42453781175](https://github.com/FBKmai/PicaX-private/actions/runs/42453781175) 已完成：12 个相同窗口的 Core ML/PyTorch 最大差异分别为黑白 `0.0000127554`、彩色 `0.0000012815`，均通过转换门槛；**PyTorch 自身分块相对整页的误差几乎与 Core ML 相同**（黑白最大 `0.37331855`、接缝平均 `0.02652844`；彩色最大 `0.16620499`、接缝平均 `0.00938206`）。因此这些合成样本中的主要偏差来自当前 128/20 分块上下文/窗口策略，而非 Core ML 数值转换；这不是所有输入或 compute unit 的全面结论。

后续报告保留 **PyTorch 同窗口分块与整页**、**Core ML 分块与 PyTorch 同窗口分块** 两条基准及 PNG。不扩大上述门槛，也不因小页通过而批准整页模型。修复模型分块策略并重做相同门槛之后，才可进入许可/资源集成和真机验证。

在观察结果前固定工程数值阈值：FP32 最大绝对误差 `2/255`、平均绝对误差 `0.1/255`；彩色 FP16 分别为 `8/255`、`0.5/255`。这是转换误差的有限上界（相对 `[0,1]` 张量），**不是实际画质验收**。每个梯度、边线、噪声样本必须单独满足，出现非有限值或结构错误仍直接失败。不得因为某次失败而事后扩大阈值宣称通过；可改用更高计算精度候选并保留两份报告。整页/分块和真机门槛独立保留。

分块测试在观察结果前另定有限上界：整页最大绝对误差 `0.05`、平均 `0.005`，每个内接缝两侧共 4 个输出像素宽区域的平均误差 `0.0075`。用合成的非均匀多块页（216×344）、奇数小页、1×1、单行及单列，比较带 reflect 外延的 PyTorch 整页与真实 Core ML 128 tile / 每侧裁 20 的拼接结果；逐个记录接缝/非接缝误差，保留输入、整页基准和拼接 PNG。这个门槛意在发现实现错误或显著上下文差异，不代表肉眼无缝或漫画画质已验收；未通过仍不得启用。

## 整页（Full Page）单次推理路径

第三轮诊断表明，当前 128/20 分块相对整页的偏差主要来自有限上下文，而不是 Core ML 转换数值。因此新增独立的整页路径：对**原始整页**只调用一次 `MLModel.prediction`，不切块、不拼接，输出裁剪为原页的精确 2×。它只使用上文锁定的两个真实模型（MangaJaNai V1 ESRGAN / IllustrationJaNai V3detail FDAT），不使用传统锐化替代；原分块路径、测试和历史均保留，二者绝不互相冒充。

- **模型契约**：输入名 `input`、NCHW RGB、`float32`、范围 `[0,1]`，形状 `[1,3,H,W]`；输出名 `output`、`float32`，形状 `[1,3,2H,2W]`。H/W 为动态轴，但受模型转换时声明的 shape 约束限制。
- **补齐方式**：只在右侧和底部做与分块路径同语义的 reflect padding（周期 `(len-1)*2`，不重复边缘像素），对齐到 16 像素、最小边长 64、最大边长 2048、最多 2,000,000 输入像素。例如 1000×1500 → 1008×1504，999×1501 → 1008×1504；推理后只保留原页 2× 区域，输出严格为 2000×3000 / 1998×3002。补齐到对齐边界不等于改变页面尺寸，也不会把填充像素写入结果。
- **一次调用**：应用创建一个 `[1,3,H_pad,W_pad]` 的 `MLMultiArray`，填满后再调用一次 `prediction`。输出按 `MLMultiArray` 实际 strides 读取，先检查整个补齐画布的有限性，再裁剪到原页 2×；不会以 tile 结果拼接冒充整页。取消只在 Core ML 调用返回后检查，未完成/已取消的任务不会写 PNG 或报告成功。
- **资源与输出**：整页路径串行执行，同一时刻不运行多个整页。无损 PNG 写在应用自建的临时试处理目录，不覆盖下载原图；结果 PNG 与估算内存会随对比结果显示。该估算不是 Instruments 峰值。

### descriptor 扩展（向后兼容）

分块专用旧 descriptor 没有 `fullPage` 字段，解码为 `nil`，行为不变。整页 descriptor 增加可选的 `fullPage` 对象，例如：

```json
"fullPage": {
  "validated": false,
  "shapeMode": "range",
  "alignment": 16,
  "minimumWidth": 64,
  "minimumHeight": 64,
  "maximumWidth": 2048,
  "maximumHeight": 2048,
  "maximumPixels": 2000000,
  "estimatedWorkingBytesPerPixel": 2048
}
```

`shapeMode` 为 `range` 时仅接受声明的动态范围；为 `enumerated` 时必须同时提供对齐、去重且落在上下限内的 `enumeratedSizes`（每个 `[width,height]`），应用选择能覆盖原页的最小面积形状。`estimatedWorkingBytesPerPixel` 是保守规划系数（黑白 2048、彩色 1024），不是实测值。`validated` 只有在数值、尺寸和真机等人工门槛完成后才可由人修改；转换脚本始终写 `false`，不会因数值通过自动批准。

`fullPage` 存在但 `validated=false` 时，显式“整页”模式明确失败，不偷偷改走分块；“自动”模式可使用分块，但结果和日志必须显示实际模式及回退原因。整页尺寸超出声明范围、enumerated 列表无覆盖形状、或预算超限时，同样明确报错/回退，不伪造成功。

### 转换与隔离验证

整页转换由 `convert.py --full-page` 执行：`torch.export` 使用动态空间轴（ESRGAN 的派生维度为 2×，FDAT 对齐要求为 16×），优先导出 `RangeDim` flexible ML Program；若 flexible 转换失败，则记录原始错误并在固定对齐尺寸集合上改用 `EnumeratedShapes` fallback。转换前先在 128×192、256×384 和示例尺寸比较 exported program 与 eager 输出，再做一次 256×384 的 CPU_ONLY Core ML 与 PyTorch 整页比较（应用同款右侧/底部补齐与裁剪）。该比较使用预先固定的 FP32 阈值：最大绝对误差 `2/255 ≈ 0.00784313725490196`、平均绝对误差 `0.1/255 ≈ 0.000392156862745098`；**不得事后放宽**。非有限值、形状/类型错误或超出阈值都使转换失败，不生成可打包的“通过”结果。

FDAT 的窗口注意力在 forward 中用动态 SymInt 计算 `% window` 的补齐分支，并在末尾用依赖输入尺寸的动态切片裁剪输出；coremltools 8.3 无法降低该 `operator.mod` 和动态 crop 节点。整页契约要求每条边补齐到 alignment 的倍数，因此当 `alignment` 是 `PixelUnshuffle 倍数 × window`（本模型为 2×8=16）的整数倍时，这些分支和裁剪对合法输入恒为空。转换器在导出前将 `check_img_size`、`FastSpatialWindowAttention.forward` 与 `FDAT.forward` 替换为等价的免补齐/免裁剪形式，并在 128×192、256×384、示例尺寸逐一比较替换前后的 eager 输出（报告字段 `exportGraphSpecialization.originalVsSpecialized`，最大误差上限 `1e-6`）；比较失败即中止转换。其中窗口划分原实现使用 rank-6 的 `view`/`permute`，超过 Core ML 张量 rank 上限 5，替换实现改用 `pixel_unshuffle`/`pixel_shuffle` 的 rank-4 等价序列；unshuffle 后的通道序为 `c·ws² + iy·ws + ix`，因此 attention 看到的 token 顺序与通道顺序完全不变，同样由替换前后比较验证。该替换只在转换进程内、导出前生效，不改变权重、分块路径或数值阈值；报告同时记录 `inputMultiple`、window 和对齐要求。若 alignment 不满足整除要求，转换显式失败，不导出未经验证的图。

ML Program 的动态输出在 feature spec 中不写固定 shape。`check_full_page_spec` 因此把空输出 shape 记录为 `unspecified`（Core ML 在每次预测时取实际范围），但仍拒绝任何带具体数字的固定输出 shape；输入必须声明 flexible range 或 enumerated shapes。输出是否真的随页面尺寸变化，由后面每个尺寸的独立预测和完整 2× 裁剪结果证明，而不是由 spec 推断。

单次 256×384 冒烟不等于整页验证。独立命令按以下尺寸逐个运行：256×384、512×768、768×1152、1000×1500、999×1501。每个尺寸先生成 PyTorch eager 整页参考；每个 Core ML 预测在**独立子进程**中执行（默认墙钟 1500 s），父进程每 0.5 s 采样该子进程 RSS，超过内存上限（默认 12 GiB；0 表示不设限）即杀死并记录为 watchdog 失败；纯 CPU 的 Torch worker 还会在导入 Torch 前尽力设置 `RLIMIT_AS`，并如实记录是否生效及被平台硬限制截断的值（macOS 上该设置在部分 runner 会失败，不能视为已强制执行）。Core ML worker 不设置 `RLIMIT_AS`，因为图形框架会预留大段虚拟地址空间；其内存上限只由父进程 RSS watchdog 执行。记录加载/预测耗时、进程峰值 RSS、最大/平均/P99 误差、形状/类型/有限性和失败原因。一个进程 OOM 或超时不会终止其他尺寸或 compute unit 的实验。CPU_ONLY 是每个尺寸的必需数值门槛；`.all`/`.cpuAndGPU` 只在 256×384 与 1000×1500 追加采样，用于记录实际设备/后端表现。报告、输入和两侧 PNG 保留为 Actions 证据；`cpuOnly` 失败即工作流失败，GPU/ANE 的差异也不会被隐藏。

手动运行示例（在 macOS、已按锁定文件安装依赖并取得已核验权重后；输出目录必须已存在且为空）：

```sh
python -I BuildScripts/SuperResolution/convert.py \
  --model manga --manga-height 1200 --minimum-page-height 1200 --maximum-page-height 1200 \
  --weight /absolute/path/2x_MangaJaNai_1200p_V1_ESRGAN_70k.pth \
  --expected-sha256 43b784f674bdbf89886a62a64cd5f8d8df92caf4d861bdf4d47dad249ede0267 \
  --precision float32 --output-dir /absolute/empty/output \
  --max-abs-error 0.00784313725490196 --max-mean-error 0.000392156862745098 \
  --full-page --full-page-alignment 16 --full-page-max-side 2048 \
  --full-page-max-pixels 2000000 --full-page-timeout 1500 --full-page-memory-mb 12288

python -B BuildScripts/SuperResolution/validate_full_page.py validate \
  --model manga \
  --weight /absolute/path/2x_MangaJaNai_1200p_V1_ESRGAN_70k.pth \
  --expected-sha256 43b784f674bdbf89886a62a64cd5f8d8df92caf4d861bdf4d47dad249ede0267 \
  --package /absolute/empty/output/MangaJaNai_V1_1200p_2x_float32.mlpackage \
  --resource-name MangaJaNai_V1_1200p_2x_float32 \
  --output-dir /absolute/empty/output \
  --size 256x384 --size 512x768 --size 768x1152 --size 1000x1500 --size 999x1501 \
  --alignment 16 --max-side 2048 --max-pixels 2000000 \
  --timeout 1500 --memory-mb 12288 --units cpuOnly,cpuAndGPU,all \
  --all-units-at 256x384 --all-units-at 1000x1500 \
  --max-abs-error 0.00784313725490196 --max-mean-error 0.000392156862745098
```

`.github/workflows/validate-super-resolution-full-page.yml` 在 `iphone-duo-ios27` 分支相关文件推送或手动触发时，对黑白和彩色两个模型分别执行上述转换/隔离验证，并上传未批准的 `.mlpackage`、JSON 报告及 PNG。它只提供 macOS arm64 的工程证据，**不是 iPhone Duo 验收，也不是画质验收**。

### 2026-11-08 整页 Core ML 工程证据

[run 42461503524](https://github.com/FBKmai/PicaX-private/actions/runs/42461503524)（commit `ae2641b`，macOS arm64 / Xcode 27.1）的两个 job 均成功，`requiredPassed` 与 `informationalPassed` 均为 true。转换结果为 flexible `RangeDim`：输入声明 `1×3×64–2048×64–2048`，输出 feature spec 为空（`unspecified`），实际输出尺寸由下表每个尺寸的预测证明；没有使用 enumerated fallback。package SHA-256 含转换器写入的调试映射，不同 run 不保证相同。

| 模型 | 权重 SHA-256 | 本次 package SHA-256 | 256×384 CPU_ONLY max / mean / P99 |
| --- | --- | --- | --- |
| MangaJaNai V1 ESRGAN 2× FP32 | `43b784f674bdbf89886a62a64cd5f8d8df92caf4d861bdf4d47dad249ede0267` | `26f60f041dd0ed39896bb3ffce5d9b7d5f23821a11d19406e6d548d4e6687529` | 1.371e-05 / 7.099e-07 / 3.219e-06 |
| IllustrationJaNai V3detail FDAT M 2× FP32 | `8ff2ba0b970e6939f3711077f5260fcded16b8388a939a27f153c687ff5da3e0` | `94f6697f579a45e18fd9247b59e0fe236a52506b3e20807799747438a0b75b13` | 1.192e-06 / 1.307e-07 / 4.768e-07 |

阈值保持预定的 max `0.00784313725490196` / mean `0.000392156862745098`，未放宽。每个尺寸先由独立 Torch 进程生成参考，再在独立 Core ML 进程运行；峰值 RSS 是该 worker 的 `ru_maxrss`，不是整机峰值，也不包含所有系统/Core ML 分配。

MangaJaNai V1（ESRGAN 2×，缩放后输出为原页 2×）：

| 页面 | 补齐输入 | Torch 参考 (s) | CPU_ONLY max | mean | P99 | CPU_ONLY 预测 (s) | CPU_ONLY 峰值 RSS (MiB) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 256×384 | 256×384 | 24.0 | 1.371e-05 | 7.099e-07 | 3.219e-06 | 2.9 | 626.7 |
| 512×768 | 512×768 | 129.0 | 1.365e-05 | 7.220e-07 | 3.278e-06 | 12.7 | 1259.3 |
| 768×1152 | 768×1152 | 732.6 | 1.359e-05 | 7.261e-07 | 3.278e-06 | 29.2 | 2319.8 |
| 1000×1500 | 1008×1504 | 1254.0 | 1.520e-05 | 7.275e-07 | 3.278e-06 | 31.0 | 3743.6 |
| 999×1501 | 1008×1504 | 1062.8 | 1.591e-05 | 7.261e-07 | 3.293e-06 | 27.6 | 3743.8 |

IllustrationJaNai V3detail FDAT M（导出的内部 4× / 有效 2×，要求输入边长为 16 的倍数）：

| 页面 | 补齐输入 | Torch 参考 (s) | CPU_ONLY max | mean | P99 | CPU_ONLY 预测 (s) | CPU_ONLY 峰值 RSS (MiB) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 256×384 | 256×384 | 3.8 | 1.192e-06 | 1.307e-07 | 4.768e-07 | 1.8 | 816.6 |
| 512×768 | 512×768 | 20.0 | 5.066e-06 | 3.512e-07 | 1.609e-06 | 7.6 | 1521.1 |
| 768×1152 | 768×1152 | 55.8 | 1.621e-05 | 1.030e-06 | 4.351e-06 | 16.4 | 2758.3 |
| 1000×1500 | 1008×1504 | 120.5 | 3.412e-05 | 2.305e-06 | 9.656e-06 | 30.4 | 3959.6 |
| 999×1501 | 1008×1504 | 106.5 | 3.543e-05 | 2.374e-06 | 9.865e-06 | 28.2 | 4100.4 |

在 256×384 与 1000×1500 追加的 `cpuAndGPU` / `.all` 采样也全部 passed，且误差数值与同一尺寸的 `cpuOnly` **完全相同**（例如黑白 1000×1500 三者 max 均为 1.520e-05；彩色 1000×1500 三者 max 均为 3.412e-05）。macOS 上这不证明使用 ANE，也不能推断 iPhone Duo 的后端选择或性能。

内存保护：父进程每 0.5 s 采样 worker RSS 并在超过 12 GiB 时杀死；本 run 未触发。worker 内尽力设置 `RLIMIT_AS` 在 macOS runner 上返回 `applied: false`（`ValueError: current limit exceeds maximum limit`），报告如实记录，因此该 run 的实际强制保护是父进程 watchdog，而不是 worker 内的地址空间限制。

视觉证据：artifact 保留每个尺寸的 input / torch / coreml PNG。下载 run 42461503524 产物后本地比较 256×384 与 1000×1500 的 Torch 与 CPU_ONLY PNG（512×768、2000×3000），逐像素 uint8 最大差为 1；黑白非零像素比例约 0.00017、彩色约 0.0006，缩略图目视一致。它们使用合成校准图，不是真实漫画页画质验收，也不能替代 iPhone Duo 真机测试。

### 应用内模式、预算和计算单元

- 对比页新增“整页（单次推理）/ 分块（128）/ 自动（整页优先）”选择，以及“全部（系统选择）/ CPU + GPU / 仅 CPU”计算单元选择。结果显示请求模式、实际模式、实际模型/版本/精度、输入/输出尺寸、补齐后的输入、耗时和回退原因；不能把分块结果标成整页。
- 整页规划预算单独计算：`sourceRaster = max(bytesPerRow × height, pagePixels × 4)`；`inputBytes = alignedPixels × 12`（3 × FP32）；`workingBytes = alignedPixels × estimatedWorkingBytesPerPixel`；`outputBytes = pagePixels × 16`（2× RGBA）；`estimate = sourceRaster + inputBytes + workingBytes + outputBytes × 4 + 64 MiB + 128 MiB`。估算超过 4 GiB 或物理内存的一半即拒绝；临时存储另要求 `outputBytes × 2 + 32 MiB`。这些是保守规划值，不是实测峰值，也不包括所有 Core ML/系统分配。
- `.all` 只表示交给系统选择，**不保证使用 Neural Engine**。必须如实记录 `cpuAndGPU`/`.all` 的失败、回退、耗时和峰值；CPU_ONLY 才是指定数值门槛。macOS CI 成功不能推断 iPhone Duo 的成功。

### 尚未完成的验收

本轮实现尚未在 iPhone Duo 真机上运行。仍需在目标设备上测量实际峰值内存、各 compute unit 的耗时/稳定性、OOM 行为，并用有代表性的黑白文字、网点、彩色纹理页面做视觉对比；长条、极端比例、奇数尺寸和极小页仍需逐项确认。未获得这些证据前，不得宣称“真机整页可用”或“画质已通过”。

## 个人非商业彩色模型的打包入口

这一入口只面向“自己签名、自己安装、非商业使用”，不改变默认构建策略，也不表示模型已通过 iPhone Duo 验收。权重不进入 git；工作流每次从 Actions artifact 重新取得并核对。

**前置条件**

- 彩色模型：IllustrationJaNai V3detail FDAT M 2×，权重 SHA-256 `8ff2ba0b970e6939f3711077f5260fcded16b8388a939a27f153c687ff5da3e0`，package SHA-256 `94f6697f579a45e18fd9247b59e0fe236a52506b3e20807799747438a0b75b13`，来自 run [42461503524](https://github.com/FBKmai/PicaX-private/actions/runs/42461503524) 的 artifact `PicaX-full-page-color-unapproved-5`（保留 14 天；过期后需重新运行验证或改填新的 run/artifact）。
- 许可：上游 the-database / [MangaJaNai 3.0.0](https://github.com/the-database/MangaJaNai/releases/tag/3.0.0)，[CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/)。只允许个人非商业使用；不得公开分发、出售或用于商业目的，不得暗示原作者背书。Core ML 转换属于修改/转换，打包的 `SuperResolutionAttribution.txt` 会记录原作者、来源、许可链接及转换/图优化改动。
- 黑白模型不在此入口内：MangaJaNai V1 1.0.0 的 CC BY-NC-SA 4.0 与后续 CC BY-NC 4.0 冲突尚未解决。

**触发方式**

在 GitHub Actions 手动运行 `Build iPhone Duo unsigned IPA`，分支选 `iphone-duo-ios27`，设置：

- `bundle_color_model` = true
- `model_run_id` = `42461503524`（或包含同一 artifact 的新 run）
- `model_artifact` = `PicaX-full-page-color-unapproved-5`
- `xcode_version` 默认 `27.1`

工作流会：

1. 用 `gh run download` 下载指定 artifact；
2. 运行 `BuildScripts/SuperResolution/stage_bundle_model.py`，核对 descriptor 的 preset/license/precision/geometry/fullPage 契约、权重 SHA 和 package SHA，拒绝已批准、嵌套或多份 descriptor，以及不匹配的包；
3. 只在 `build/SuperResolutionBundle/` 的副本中写入 `validated: true`、`fullPage.validated: true` 和 `bundleApproval`（记录 run/artifact/package SHA）；原 artifact 不变；
4. 在构建后用 `xcrun coremlc compile ... --deployment-target 16.0 --platform ios` 编译 `.mlpackage`，把 `.mlmodelc`、descriptor 和归属说明放到 `.app` 顶层；不改动 Xcode 工程，也不提高 App 的 iOS 15.2 最低版本；
5. 运行资源审计；成功时状态为 `validated-models-declared`，IPA artifact 名称带 `-color` 后缀。

命令行等价触发（需要本机 `gh` 已登录且有 `actions: read`）：

```sh
gh workflow run build-iphone-duo.yml --ref iphone-duo-ios27 \
  -f bundle_color_model=true \
  -f model_run_id=42461503524 \
  -f model_artifact=PicaX-full-page-color-unapproved-5
```

**签名和安装**

Actions 产物是**未签名 IPA**，不能直接安装。下载 artifact（例如 `PicaX-iPhoneDuo-unsigned-<run>-color`），解压得到 `PicaX-iPhoneDuo-unsigned.ipa`，再用你自己的证书/描述文件通过全能签等工具重签。免费 Apple ID 的签名通常 7 天过期，需要在设备上重新签名安装；重签后的 IPA SHA 会与未签名 artifact 不同。安装前可在 IPA 内确认以下顶层文件存在：

```text
Payload/PicaX.app/IllustrationJaNai_V3detail_FDAT_M_2x_float32.mlmodelc/
Payload/PicaX.app/IllustrationJaNai_V3detail_FDAT_M_2x_float32.superresolution.json
Payload/PicaX.app/SuperResolutionAttribution.txt
```

**安装后仍必须验证**

进入阅读器 → 画质增强 → 本页 AI 试处理，选择彩色模型、整页模式，确认界面显示实际模型、实际模式“整页（单次推理）”、输入/输出尺寸、耗时和回退原因。若显示模型缺失，先检查 IPA 顶层资源和签名工具是否保留了 `mlmodelc`。macOS CI 的数值通过不等于 iPhone Duo 真机通过：仍需在设备上测量峰值内存、OOM、各 compute unit 的耗时和实际画质；`.all` 只是系统选择，不保证使用 Neural Engine。彩色模型的 CPU_ONLY 已在五个尺寸验证，`cpuAndGPU`/`.all` 只在 256×384 与 1000×1500 采样；真机长页和极端尺寸仍可能拒绝或失败，失败时应显示原因并保留原图。

## 在 macOS 暂存转换

请先独立确认权重来源及许可；只获取实际需要的 checkpoint，不要将整个模型仓库、无关模型或读者漫画加入项目。将每个下载文件放独立空目录，安全检查归档及其中许可后只取所需文件；避免路径穿越/链接，不在下载或解压目录执行代码。使用受信任的 Python 环境，从另一个安全工作目录运行，所有输入使用绝对路径。脚本不提供不安全 pickle 回退：先将同一文件字节读入内存、核对调用者给出的 SHA 与上表锁定值及实测 SHA，再对 `.pth` 调用 `torch.load(..., weights_only=True, map_location="cpu")`；彩色使用 safetensors。PyTorch 2.6.0 修复了已知的 CVE-2025-32434，但 `weights_only` 和 safetensors 也不是运行不可信内容的完整沙箱；绝不能接受任意 hash 或关闭核验。已知 hash 来自第三方、不是作者签名，也不能替代信任及隔离。

以下为待 macOS 验证的示例流程。`REPO`、`WEIGHT`、数值阈值和黑白的整页范围必须由操作者实际填写；阈值应在查看结果之前根据验收计划确定，示例故意不预设允许误差。请在可信的空工作目录内执行，不要从下载目录或项目 bundle 工作目录运行解释器。

```sh
# 仅示意；这些目录各不相同，WEIGHT 指向已经取得并核验来源的单个文件。
REPO=/absolute/path/to/PicaX-private
WEIGHT=/absolute/path/to/isolated-download/2x_IllustrationJaNai_V3detail_FDAT_M_unshuffle_40k_fp16.safetensors
OUT=/absolute/path/to/separate-empty-output-directory
# 使用可信渠道安装的 macOS arm64 CPython 3.11.9。
python3.11 -m venv /absolute/path/to/separate-venv
PY=/absolute/path/to/separate-venv/bin/python
"$PY" -I -m pip install --require-hashes --only-binary=:all: \
  -r "$REPO/BuildScripts/SuperResolution/requirements-macos-arm64-py311.txt"
"$PY" -I -m pip check
# 两个阈值必须先根据验收计划填为有限非负数；示例中不假造通过标准。
MAX_ABS_ERROR=  # 例如由验收人员选定，不要留空
MAX_MEAN_ERROR= # 同上
"$PY" -I "$REPO/BuildScripts/SuperResolution/convert.py" \
  --model color --weight "$WEIGHT" \
  --expected-sha256 8ff2ba0b970e6939f3711077f5260fcded16b8388a939a27f153c687ff5da3e0 \
  --precision float16 --output-dir "$OUT" \
  --max-abs-error "$MAX_ABS_ERROR" --max-mean-error "$MAX_MEAN_ERROR"
```

黑白以 1200p 为例，将上面的执行命令改为以下参数；其余档位选择表中对应名称和 SHA。范围只能填经样本/策略确定的正整数，不能互相重叠，也不能假称是上游界限。脚本会检查本次输出目录内已有的黑白 descriptor 范围；来自不同输出目录、未来被合并进 app 的文件仍须人工整体核对。特别地，如果缺失某个档位，不应为了自动匹配而悄悄扩大另一个模型的有效范围。

```sh
WEIGHT=/absolute/path/to/isolated-download/2x_MangaJaNai_1200p_V1_ESRGAN_70k.pth
MIN_HEIGHT=  # 操作者选择，不能为空
MAX_HEIGHT=  # 操作者选择，不能为空
"$PY" -I "$REPO/BuildScripts/SuperResolution/convert.py" \
  --model manga --manga-height 1200 \
  --minimum-page-height "$MIN_HEIGHT" --maximum-page-height "$MAX_HEIGHT" \
  --weight "$WEIGHT" --expected-sha256 43b784f674bdbf89886a62a64cd5f8d8df92caf4d861bdf4d47dad249ede0267 \
  --precision float32 --output-dir "$OUT" \
  --max-abs-error "$MAX_ABS_ERROR" --max-mean-error "$MAX_MEAN_ERROR"
```

脚本要求输出路径与下载目录互不包含，且都在项目外；不覆盖同名产物。它对固定大小输入先对比 PyTorch eager 与 trace，再比较同一合成 RGB 梯度、线条/边缘和固定种子噪声的 PyTorch 与 Core ML CPU 输出。每个样本记录 max、mean、p99 绝对误差、输出范围和是否符合调用者预设阈值；输出形状、数据类型、有限性或数值不符合则失败。报告同时记录环境、固定依赖版本、脚本及权重 hash、模型包内容 hash、精度及待验项。失败退出非零，不把结果当通过。转换失败后若留有不完整包或报告，请检查后换一个新的空暂存目录重跑。

每次输出至多包含 `<resourceName>.mlpackage`、`<resourceName>.superresolution.json` 和 `<resourceName>.validation.json`。输入/输出名、倍率、尺寸、来源、hash 和计算精度写进 descriptor；`resourceName` 无扩展名。脚本**始终生成 `validated: false`**，即便三个数值样本通过，原因是其未覆盖整页拼接、许可与真机验收；不会因为通过数值阈值而标记已验证。数值失败但包已保存时也可能留下 `validated: false` 的 descriptor；不要将其打包或手工启用。

## 完成资源集成前的门槛

1. 审核每个实际 checkpoint 的许可及来源；解决 V1 的 SA/非 SA 冲突，确认目标分发/授权，保留完整归属和变更说明。核实及记录每个权重 hash；Manga 相关的所有许可未确认前禁止打包。
2. 在固定 macOS 工具链实际转换并核对报告：所有 eager/trace 与 CPU Core ML 比较通过预先选择的阈值；包的 hash 与报告对应。各档 range 正确、互不重叠，只有样本所需档位；在没有匹配/经过批准的范围时跳过，不从未安装的档位推断已安装模型。FP16/FP32 彩色候选应分目录比较，最终 bundle 只放一个经批准的彩色 descriptor，避免候选歧义。
3. 完成非均匀合成整页与分块的误差/接缝比较、边角/奇数页/小页测试，以及 RGB/灰度/透明/方向/色域测试。整页路径还需在要求的每个尺寸上用 CPU_ONLY 与同一补齐输入的 PyTorch 整页结果比较，并在追加样本上记录 GPU/`.all` 的真实行为；不能仅凭 CPU 数值或输出尺寸宣称真机画质通过。
4. 只有完成上述许可与工程核验并经人工审核、保留证据后，才能人工更新 descriptor 的确切许可和 `validated`，将模型和对应 `*.superresolution.json` 作为应用资源加入 Xcode，用于后续真机试处理。`validated` 仅声明工程和许可门槛已通过，**不等于用户已确认实际阅读画质提升**。当前描述文件仅接受确切的 `CC-BY-NC-4.0` 或 `CC-BY-NC-SA-4.0`；这只是声明检查，不独立证明实际权重授权。资源基名只使用 ASCII 字母、数字、下划线或连字符，特征名固定 `input`/`output`，来源必须是含有效主机名的 HTTPS URL。iPhone 包内的 descriptor 和对应 `.mlmodelc` 必须作为主应用顶层资源，不能仅放在嵌套文件夹或其他 bundle 内。每个模型 ID、资源名唯一，黑白闭区间不得重叠，彩色只启用一个候选；彩色通常不填高度范围，若填写也必须是完整、为正且有序的上下界。必须在 macOS 核实项目最低部署 iOS 15.2 与模型最低 iOS 16 的资源编译兼容性；必要时将经相应工具链编译的 `.mlmodelc` 作为资源集成，不能为通过构建擅自提高整个 App 的最低系统版本。个人非商业彩色入口采用构建后 `xcrun coremlc` 编译并复制顶层资源的路径：`stage_bundle_model.py` 只修改该次构建的副本，不改原 artifact 或 Xcode 工程。任何步骤未通过则继续显示不可用/原图，原图不可覆盖。
5. `BuildScripts/verify-super-resolution-bundle.py` 会在 iPhone 打包前审计已编译资源和描述契约，并将 `SuperResolutionModels.json` 随构建产物提供。没有模型时明确标记 `engineering-build-no-models`，这类 IPA 只是工程验证版，**不是已完成 AI 画质验证的交付物**。存在未验证、许可未解决、缺少编译资源或选择有歧义的描述时阻止打包。资源审计不能替代数值、真机、签名或独立许可验证。

6. 有模型的试验 IPA 安装后，才进行用户真机门槛：在目标 iPhone、目标 compute unit 和代表性的黑白文字、网点、彩色纹理页面进行画质、耗时、实际峰值内存和存储验收。对比页显示的内存是图像工作预算估算，不是实测峰值，也不包括无法在此约束的全部 Core ML/系统分配；实际峰值需用 Xcode Instruments 等工具测量。用户确认收益后再进入整章队列和后台续跑阶段。

## 工程验证与操作入口

- 阅读器 → 画质增强 → **原图对比 / 本页 AI 试处理**；不必先开启传统锐化。支持原图、传统滤镜和手动黑白/彩色 AI；双指缩放、单指移动、拖动分割线，两侧共用源坐标。`1:1 原图像素` 以屏幕物理像素对齐原图像素，右侧 AI 同位置对应 2× 输出。原图读取、输入和输出像素及实际模型/计算精度均明确展示。
- 仅前台显式运行当前页，离开对比页或 App 进入非活跃状态时取消；Core ML 单块预测不能强制中断，会在当前块结束后检查取消。取消/失败/超限均不是 AI 成功，原图不覆盖，预设变更不复用旧结果。
- 当前源图对比最多 1200 万像素、单边 16384、编码数据 64 MiB，并检查解码副本预算；AI 另有更保守的输出和图像工作预算，可能跳过仍可普通阅读的较大页面。推理单 worker；整页模式为一次动态尺寸预测，分块模式保留 128 输入 tile / 每侧裁 20；输出为临时独立目录内无损 PNG，不进入原下载枚举、导出和备份，离开时清理。暂不承诺重启恢复。
- 原图对比的 64 MiB 编码上限在本地/便携下载文件、磁盘缓存及 HTTP 流累积时执行；有界请求不与无上限或不同上限的请求合并。EH 的 HTML/API/图片/重试沿用同一上限并保留鉴权与 Referer，取消或超限不重试。代理不绕行直连：其 HTTP codec 在 Content-Length、chunked 和 EOF 路径先实施每次请求的 body 限额（内部限额头不发送到源站，重定向仍携带策略），上层再限制返回数据；不能只依赖 URLSession 在代理完整缓冲之后检查。超限不删除合法缓存/原文件，不当作损坏重新下载。该限额是返回编码数据的上界，不是整个进程/系统缓冲区的峰值内存保证。
- 普通阅读采用独立的显示预算（最多约 2400 万 RGBA 像素、长边 65536），不因 AI 的源图上限而拒绝本可降采样显示的长页。JM 仍需解码原始位图来重排，先估算源解码和显示副本（256 MiB 工作预算），只生成显示尺寸的重排结果；极端页仍明确跳过，不回退显示乱序图片。此估算不替代 Instruments 实测。
- 工程版不包含模型时，先验证源图链路、传统模式、可信对比、缺模型/取消等状态；这不代表已验证 AI 画质。保留 iOS 15.2 普通阅读，候选模型推理需要 iOS 16+。

纯逻辑自检（无需 PyTorch/Core ML，不能代替上述门槛）：

```sh
python3 -I -B "$REPO/BuildScripts/SuperResolution/test_convert.py"
python3 -I -B "$REPO/BuildScripts/test-super-resolution-bundle.py"
```
