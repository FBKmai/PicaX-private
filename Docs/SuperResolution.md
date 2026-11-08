# 实验性 Core ML 超分：来源、转换与验证

## 当前状态和边界

首轮只支持用户**显式前台**试处理当前页或少量页面，不做整章、后台任务或自动逐页运行；原图必须保留。本仓库**没有随代码提供这两个模型的权重、`.mlpackage`、`.mlmodelc` 或现成有效 descriptor**。因此未自行取得合规权重并完成转换、验证、资源集成之前，AI 功能会显示缺少模型/不可用，而不是偷偷用旧锐化冒充 AI。

截至 2026-11-08，已通过 [Actions 工程构建 #6](https://github.com/FBKmai/PicaX-private/actions/runs/42445750760)：Xcode 27.1 / iOS 27.1 SDK，145 项 iOS 模拟器测试及 20 项 Python 工具测试通过。未签名 IPA 的提交为 `6c558161a66e7374c2e8f77d6aef92e1a19d804c`，SHA-256 为 `4a629cab5951693e89a4115551369749b3344b3767baff7488cf807f3c327cf9`；已独立核对 ZIP CRC、构建提交和 SDK。该包的资源审计仍为 `engineering-build-no-models`，不是 AI 可用版，安装前需要签名。

本机为 Windows / Python 3.9，无 Xcode/macOS。已下载官方原始归档、安全提取所选黑白和彩色 checkpoint 并独立核对下表的文件 hash；**尚未完成真实权重加载、Core ML 转换、macOS 预测、拼接或真机画质/耗时/内存验证**。新增的手动 `Validate real Core ML super-resolution candidates` 工作流负责在隔离的 macOS runner 上执行真实转换；其产物一律保持未批准，不会自动进入 IPA 或修改 `validated`。任何资源分发必须先核实具体权重许可；V1 尤其存在下面的许可冲突。

## 锁定来源和候选

- 黑白：[MangaJaNai V1 2× release 1.0.0](https://github.com/the-database/MangaJaNai/releases/tag/1.0.0)，tag 对应提交 [`5e9db8e5a26ef9336d6bc6baeebbe3b3ac740963`](https://github.com/the-database/MangaJaNai/tree/5e9db8e5a26ef9336d6bc6baeebbe3b3ac740963)。ESRGAN（Spandrel 中称 ESRGAN/RRDB）。上游的 [README](https://github.com/the-database/MangaJaNai/blob/d2f8f92dc75303c557ca2d7a507913eff512ff32/README.md) 指出 1200、1300、1400、1500、1600、1920、2048 是分别优化的**原始整页高度**，非屏幕宽度、下采样尺寸或 tile 高度。按实际要试的样本只转换所需档位，不预装全部；长条、裁图、异常比例先跳过。上游未在这里给出精确分档边界：可参考离原始整页高度最近的档位人工划定范围，但这不是上游保证的最佳阈值；应用实际只按已批准 descriptor 中的明确、不重叠范围匹配，无匹配时跳过。
- 彩色：[IllustrationJaNai V3detail 2× FDAT M unshuffle release 3.0.0](https://github.com/the-database/MangaJaNai/releases/tag/3.0.0)，tag 对应提交 [`d2f8f92dc75303c557ca2d7a507913eff512ff32`](https://github.com/the-database/MangaJaNai/tree/d2f8f92dc75303c557ca2d7a507913eff512ff32)。V3detail 保留纹理、**不清除**半色调噪声，某些图可能生成过多纹理；不能预断效果胜出。[Spandrel 0.4.2 的 FDAT 架构](https://github.com/chaiNNer-org/spandrel/blob/724cca389f28c38e1050689d4862a452fd644484/libs/spandrel/spandrel/architectures/FDAT/__init__.py)声明 `img_range=1` 并检测 unshuffle。
- 配置参考及下表的**逐个权重文件** SHA-256 来自独立第三方转换器 [`known_models.yaml`，提交 `68e3f51517e04433164c09d8505a409e26477905`](https://github.com/imxieyi/waifu2x-ios-model-converter/blob/68e3f51517e04433164c09d8505a409e26477905/known_models.yaml)，不是原作者签名的校验文件。对应的 [converter.py](https://github.com/imxieyi/waifu2x-ios-model-converter/blob/68e3f51517e04433164c09d8505a409e26477905/converter.py)、[model_loader.py](https://github.com/imxieyi/waifu2x-ios-model-converter/blob/68e3f51517e04433164c09d8505a409e26477905/model_loader.py)、[SPECS.md](https://github.com/imxieyi/waifu2x-ios-model-converter/blob/68e3f51517e04433164c09d8505a409e26477905/SPECS.md) 和 [requirements-janai.txt](https://github.com/imxieyi/waifu2x-ios-model-converter/blob/68e3f51517e04433164c09d8505a409e26477905/requirements-janai.txt) 给出架构/形状/精度。转换器代码许可证是 Apache-2.0，**不是模型权重许可证**；本项目脚本独立实现该路径，不运行下载的转换器。
- Spandrel [v0.4.2 tag `724cca389f28c38e1050689d4862a452fd644484`](https://github.com/chaiNNer-org/spandrel/tree/724cca389f28c38e1050689d4862a452fd644484) 的 [`MAIN_REGISTRY`](https://github.com/chaiNNer-org/spandrel/blob/724cca389f28c38e1050689d4862a452fd644484/libs/spandrel/spandrel/__helpers/main_registry.py) 已注册 ESRGAN 和 FDAT，不需 `spandrel_extra_arches` 或 release 里的旧 FDAT 补丁。另已只读检查与依赖锁文件 SHA-256 一致的 PyPI 0.4.2 wheel，确认脚本使用的顶层导出及 `SizeRequirements.check(width, height)` 存在；未安装或执行该 wheel，这只是静态接口核对，不证明真实转换可运行。
- `BuildScripts/SuperResolution/requirements-macos-arm64-py311.txt` 锁定 macOS arm64、CPython 3.11.9 的直接和传递 Python 依赖及 PyPI wheel SHA-256；核心版本为 PyTorch 2.6.0、torchvision 0.21.0、coremltools 8.3.0、Spandrel 0.4.2、NumPy 1.26.4、safetensors 0.4.5。为避免 PyTorch ≤2.5.1 的 weights-only RCE 漏洞 CVE-2025-32434，本锁定版本有意偏离上游推荐的 PyTorch 2.5.1/torchvision 0.20.1。coremltools 8.3 的已测试上限仅为 PyTorch 2.5.0，会对 2.6.0 发出版本警告；此组合的转换兼容性尚未验证，必须在 macOS 进行实测，若不兼容则阻塞而非退回有漏洞版本。此环境尚未在 macOS 安装/验证；换架构或版本需要单独锁定并重新验证。工具链及 macOS/Xcode 版本会影响产物，不承诺不同机器逐字节相同。

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
- 这是上游候选配置，**不是已证实的无缝或真机画质结果**。模型尤其是注意力模型的整图结果可能与分块结果不同。需对非均匀合成页比较整图与多块拼接的接缝及非接缝误差，并检查实际漫画图像、页面边界和 device compute unit；尚未运行这些验证。
- `precision` 是 Core ML **中间计算精度**，不是输入/输出数据类型。Manga ESRGAN 上游要求 FP32，中间 FP16 曾在孤立边缘像素出现大误差；脚本拒绝 Manga FP16。彩色 FDAT 2× 上游采用 FP16 中间计算，但仅可作为候选，需分别测 FP32/FP16。FP32 不保证 ANE，速度/内存/画质取决于实际设备。
- 上游的 Spandrel 转换明确以 iOS 16 为最低目标。应用仍可保留 iOS 15.2 普通阅读，但 AI 的模型加载/推理必须限制 iOS 16+ 并在不满足时明确不可用。macOS CPU 数值预测不等于 iOS GPU/ANE 验证。

## 真实转换工作流与预先确定的数值标准

手动运行 `.github/workflows/validate-super-resolution.yml`，依次尝试 Manga 1200p FP32、彩色 FDAT FP32 和 FP16。固定 macOS arm64 / CPython 3.11.9 及 hash-locked wheel；每个候选使用独立输出目录，归档、权重、解释器和仓库互不混用。工作流只产生保留 7 天的私有 Actions 候选包/数值报告，不提交模型、不发布 Release、不自动批准资源。Manga 暂存范围仅为原始高度恰好 1200，不推定其他高度已验证。

在观察结果前固定工程数值阈值：FP32 最大绝对误差 `2/255`、平均绝对误差 `0.1/255`；彩色 FP16 分别为 `8/255`、`0.5/255`。这是转换误差的有限上界（相对 `[0,1]` 张量），**不是实际画质验收**。每个梯度、边线、噪声样本必须单独满足，出现非有限值或结构错误仍直接失败。不得因为某次失败而事后扩大阈值宣称通过；可改用更高计算精度候选并保留两份报告。整页/分块和真机门槛独立保留。

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
3. 完成非均匀合成整页与分块的误差/接缝比较、边角/奇数页/小页测试，以及 RGB/灰度/透明/方向/色域测试。不能仅凭 CPU 数值或输出尺寸宣称真机画质通过。
4. 只有完成上述许可与工程核验并经人工审核、保留证据后，才能人工更新 descriptor 的确切许可和 `validated`，将模型和对应 `*.superresolution.json` 作为应用资源加入 Xcode，用于后续真机试处理。`validated` 仅声明工程和许可门槛已通过，**不等于用户已确认实际阅读画质提升**。当前描述文件仅接受确切的 `CC-BY-NC-4.0` 或 `CC-BY-NC-SA-4.0`；这只是声明检查，不独立证明实际权重授权。资源基名只使用 ASCII 字母、数字、下划线或连字符，特征名固定 `input`/`output`，来源必须是含有效主机名的 HTTPS URL。iPhone 包内的 descriptor 和对应 `.mlmodelc` 必须作为主应用顶层资源，不能仅放在嵌套文件夹或其他 bundle 内。每个模型 ID、资源名唯一，黑白闭区间不得重叠，彩色只启用一个候选；彩色通常不填高度范围，若填写也必须是完整、为正且有序的上下界。必须在 macOS 核实项目最低部署 iOS 15.2 与模型最低 iOS 16 的资源编译兼容性；必要时将经相应工具链编译的 `.mlmodelc` 作为资源集成，不能为通过构建擅自提高整个 App 的最低系统版本。该脚本不执行集成、不修改 Xcode 工程、不运行远程构建。任何步骤未通过则继续显示不可用/原图，原图不可覆盖。
5. `BuildScripts/verify-super-resolution-bundle.py` 会在 iPhone 打包前审计已编译资源和描述契约，并将 `SuperResolutionModels.json` 随构建产物提供。没有模型时明确标记 `engineering-build-no-models`，这类 IPA 只是工程验证版，**不是已完成 AI 画质验证的交付物**。存在未验证、许可未解决、缺少编译资源或选择有歧义的描述时阻止打包。资源审计不能替代数值、真机、签名或独立许可验证。

6. 有模型的试验 IPA 安装后，才进行用户真机门槛：在目标 iPhone、目标 compute unit 和代表性的黑白文字、网点、彩色纹理页面进行画质、耗时、实际峰值内存和存储验收。对比页显示的内存是图像工作预算估算，不是实测峰值，也不包括无法在此约束的全部 Core ML/系统分配；实际峰值需用 Xcode Instruments 等工具测量。用户确认收益后再进入整章队列和后台续跑阶段。

## 工程验证与操作入口

- 阅读器 → 画质增强 → **原图对比 / 本页 AI 试处理**；不必先开启传统锐化。支持原图、传统滤镜和手动黑白/彩色 AI；双指缩放、单指移动、拖动分割线，两侧共用源坐标。`1:1 原图像素` 以屏幕物理像素对齐原图像素，右侧 AI 同位置对应 2× 输出。原图读取、输入和输出像素及实际模型/计算精度均明确展示。
- 仅前台显式运行当前页，离开对比页或 App 进入非活跃状态时取消；Core ML 单块预测不能强制中断，会在当前块结束后检查取消。取消/失败/超限均不是 AI 成功，原图不覆盖，预设变更不复用旧结果。
- 当前源图对比最多 1200 万像素、单边 16384、编码数据 64 MiB，并检查解码副本预算；AI 另有更保守的输出和图像工作预算，可能跳过仍可普通阅读的较大页面。推理单 worker，128 输入 tile / 每侧裁 20；输出为临时独立目录内无损 PNG，不进入原下载枚举、导出和备份，离开时清理。暂不承诺重启恢复。
- 工程版不包含模型时，先验证源图链路、传统模式、可信对比、缺模型/取消等状态；这不代表已验证 AI 画质。保留 iOS 15.2 普通阅读，候选模型推理需要 iOS 16+。

纯逻辑自检（无需 PyTorch/Core ML，不能代替上述门槛）：

```sh
python3 -I -B "$REPO/BuildScripts/SuperResolution/test_convert.py"
python3 -I -B "$REPO/BuildScripts/test-super-resolution-bundle.py"
```
