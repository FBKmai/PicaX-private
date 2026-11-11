# PicaX

[![License: MPL-2.0](https://img.shields.io/badge/License-MPL--2.0-blue)](LICENSE)
[![LAN tests](https://github.com/FBKmai/PicaX-private/actions/workflows/test-lan-super-resolution.yml/badge.svg?branch=iphone-duo-ios27)](https://github.com/FBKmai/PicaX-private/actions/workflows/test-lan-super-resolution.yml)
[![Documentation](https://github.com/FBKmai/PicaX-private/actions/workflows/test-documentation.yml/badge.svg?branch=iphone-duo-ios27)](https://github.com/FBKmai/PicaX-private/actions/workflows/test-documentation.yml)

PicaX 是使用 SwiftUI 构建的多漫画源阅读客户端，包含浏览、搜索、下载、离线阅读、备份，以及可选的 AI 超分功能。

**这里是 [FBKmai/PicaX-private](https://github.com/FBKmai/PicaX-private)，基于 [youshen2/PicaX](https://github.com/youshen2/PicaX) 维护的衍生版本，不是上游官方发行入口。** 本仓库增加了 iPhone Duo 适配、手机 Core ML 超分实验和局域网电脑超分；电脑端包含保留整页上下文的 HAT-L 显存优化及 FP32/BF16 选择。仓库名称中的 `private` 是历史命名，不代表访问权限或保密承诺。

## 从哪里开始

| 你的目标 | 入口 |
|---|---|
| 了解 App、手机与电脑分别做什么 | 下方“功能与运行方式”和[架构说明](Docs/Architecture.md) |
| 在 Windows/NVIDIA 电脑部署优化版超分 | [电脑超分安装与排障](Docs/LanSuperResolution.md) |
| 获取可连接电脑的手机包 | 下方“获取手机 App” |
| 修改代码、构建、运行测试 | [开发指南](Docs/Development.md)与[贡献说明](CONTRIBUTING.md) |
| 理解 HAT 优化与实测边界 | [HAT-L 优化说明](Docs/HATOptimization.md) |
| 研究手机内置 Core ML 模型 | [Core ML 来源、转换与历史验证](Docs/SuperResolution.md) |
| 安全使用、报告问题 | [安全说明](SECURITY.md) |

## 当前推荐版本

- **默认分支：`iphone-duo-ios27`**。本分支包含 HAT 优化提交 `60e5c37` 及其前置 BF16/HTTP 改动；新部署不需要再切换到历史修复分支。
- `fix/lan-http-direct` 是这些改动的历史开发分支；`main` 不是本仓库当前推荐的部署入口。
- 优化默认使用 `--hat-window-batch 128 --hat-attention-backend eager`。`sdpa` 为实验选项，不是默认，也不代表已经完成真实 CUDA 验证。
- 电脑端通用 CLI 默认 FP32；部署教程显式为 HAT-L 设置 BF16。手机提交时选择的精度优先，并固定在该任务内。
- [当前更新说明](RELEASE_NOTES.md)。验证状态和限制见各功能文档，不把“CI 通过”当作所有设备都已通过。

```sh
git clone --branch iphone-duo-ios27 https://github.com/FBKmai/PicaX-private.git
cd PicaX-private
```

## 功能与运行方式

### 漫画阅读

- 支持 PicACG、JMComic、NHentai、E-Hentai / ExHentai、Hitomi、绅士漫画等来源；来源可用性受对应平台影响。
- 多来源账号管理、浏览与分类、高级搜索、搜索表达式、搜索历史及常用搜索。
- 详情、评论、本地/云端收藏、屏蔽词、阅读历史、页级书签与阅读时长统计。
- 连续滚动、分页、左右阅读方向、整本阅读、缩放、预加载和批量阅读。
- 分章节下载、离线阅读、完整性检查、ZIP/CBZ/PDF 导入与 ZIP/PDF 导出。
- `.picax` 备份、PicaComic 数据导入、App 锁、网络代理及可选 Watch 配套应用。

### 三种图像处理路径，不要混淆

| 路径 | 在哪里计算 | 需要什么 | 主要边界 |
|---|---|---|---|
| 传统画质增强 | 手机/App | 不需要模型或电脑 | 是滤镜，不冒充 AI |
| 本机 AI 超分、下载后自动超分 | 手机 Core ML | 经批准并打包的手机模型 | 默认源码构建不带权重；GPU 曾有真机异常，保留仅 CPU 路径与警告；后台时间由 iOS 决定 |
| **电脑 AI 超分** | **自己的 Windows/NVIDIA 电脑，PyTorch/CUDA** | **电脑服务、核验后的权重、支持 HTTP/BF16 的手机版本** | **逐页整图处理；手机上传与收取需要前台，完整提交后电脑可独立运行** |

**使用电脑超分不要求 IPA 内置 Core ML 权重。** 构建审计显示 `engineering-build-no-models` 只表示没打包手机本机模型，不表示电脑超分不可用。下载后自动超分仍在手机运行，不会自动转发到电脑。

电脑模型包括 HAT-L、FDAT-XL、FDAT-M，以及未在本机验证的 DAT2 候选。HAT 优化不换 checkpoint、不缩小原图、不把漫画切成独立小图超分；只是调度模型原有的注意力窗口并降低输出临时缓冲峰值。RTX 5090 D v2 上的一组 34 页 BF16/4× 历史对照，从约 30 分 30 秒降至 6 分 37 秒；这不是其他显卡或任意尺寸的速度保证，方法与限制见[完整说明](Docs/HATOptimization.md)。

> **电脑服务是无加密、无密码的 HTTP。只能运行在可信局域网，不能开放公网、端口转发或公共隧道。** 客户端分组 ID 不是认证。详见[安全说明](SECURITY.md)。

## 获取手机 App

本衍生版本的构建入口是 [Build iPhone Duo unsigned IPA](https://github.com/FBKmai/PicaX-private/actions/workflows/build-iphone-duo.yml)，**不是上游仓库的 Releases**。截至 2026-11-11，本仓库没有长期维护的 GitHub Release 下载包。

1. 打开上述 Actions 页面，选择成功的 `iphone-duo-ios27` 构建，核对该次提交。历史 HTTP/BF16 兼容参考为[运行 42802024696](https://github.com/FBKmai/PicaX-private/actions/runs/42802024696)（`52aa2a3`）；历史产物可能过期，不把它作为永久下载地址。
2. 下载 `PicaX-iPhoneDuo-unsigned-<运行编号>` artifact，解压取得 IPA、`SHA256SUMS.txt` 和构建信息。下载 Actions 产物通常需要登录 GitHub；产物保留 **14 天**。
3. IPA **未签名，不能直接安装**。用自己的证书/描述文件签名后安装；重签后的 SHA-256 会变化。免费 Apple ID 签名通常有较短有效期，需要定期重签。
4. 若产物已过期，有本仓库写入权限的维护者可点击 **Run workflow**，分支选 `iphone-duo-ios27`，保持 `bundle_color_model=false`，即可重新构建适用于电脑超分的无内置模型 IPA。普通读者可以 fork 后启用 Actions；工作流需要能调度 `xcode-27` runner 且安装 Xcode 27.1 / iOS 27.1 模拟器。自己的仓库没有该 runner 时，按[开发指南](Docs/Development.md)在自己的 macOS/Xcode 环境构建，不能把一直 queued 当成构建成功。
5. 个人非商业 Core ML 彩色模型打包是另一条可选流程，涉及独立许可、hash 和验证门槛；见[Core ML 文档](Docs/SuperResolution.md)。电脑超分不需要开启它。

旧 HTTPS/配对版不能连接当前 HTTP 服务；没有精度选择的旧手机包可能拒绝 BF16 默认能力响应。请按[兼容性说明](Docs/LanSuperResolution.md#compatibility)更新，而不是通过更换电脑模型解决。

应用内“检查更新”目前仍查询上游 `youshen2/PicaX` 的 Release，**不能用它判断或升级本衍生版本**。本版本以此仓库的提交和 Actions 构建信息为准。

## 平台与构建要求

| 部分 | 要求与已知状态 |
|---|---|
| iOS 主应用 | 最低部署 iOS 15.2；本机候选 Core ML 推理需 iOS 16+ |
| Live Activity | iOS 16.1+；不提高主应用最低版本 |
| Watch 配套 | watchOS 9+；iPhone Duo 专用 IPA 不包含 Watch App |
| macOS / visionOS | 工程部署目标均为 26.0；不等于每个新功能都在这些平台做过真机验收 |
| Apple 开发 | 本分支推荐与 CI 一致的 **Xcode 27.1**；Duo 打包脚本要求 iOS SDK ≥27.1 和相应模拟器 |
| 电脑超分 | **Windows x64、CPython 3.11、兼容 CUDA 12.8 wheel 的 NVIDIA 驱动/GPU**；部署依赖文件只适用于这个组合 |

Windows 电脑服务不需要 Xcode；构建 iOS App 则需要 macOS/Xcode 或 GitHub Actions。Linux CI 测了 HTTP 与 CPU 小模型数值，不代表已验证 Linux/macOS/AMD 电脑 GPU 部署。已测显卡、尺寸和内存口径见[HAT 优化说明](Docs/HATOptimization.md)。

## 开发与贡献

- [开发指南](Docs/Development.md)：环境、代码地图、构建、测试矩阵和常见修改。
- [架构说明](Docs/Architecture.md)：手机/电脑边界、队列、持久化、恢复与协议。
- [贡献说明](CONTRIBUTING.md)：基于默认分支提交 PR、选择验证层级、报告问题时保护隐私。
- [电脑部署教程](Docs/LanSuperResolution.md)：从全新环境到首张结果，不依赖维护者的本机目录。

## 许可与来源

- 本项目代码使用 **Mozilla Public License 2.0**，见 [LICENSE](LICENSE)；保留上游项目及各第三方依赖的归属和各自许可。
- 电脑端允许列表中的 MangaJaNai/IllustrationJaNai 3.0.0 权重来自 the-database，适用 **CC-BY-NC-4.0**，与代码许可证不同；下载和运行需要显式确认非商业用途。权重不提交到 git。
- MangaJaNai V1 黑白手机模型的历史许可冲突尚未解决，不在个人彩色模型打包入口中启用。不要用代码的 MPL 或转换器的 Apache 许可代替权重许可。
- 漫画内容和账号来自对应来源，版权及服务条款属于相关权利方。请遵守当地法律、来源规则和模型许可；开源代码许可不授予漫画内容再分发权。

## 致谢

- [youshen2/PicaX](https://github.com/youshen2/PicaX)：本仓库的上游项目。
- [ccbkv/PicaComic](https://github.com/ccbkv/PicaComic)、[Pacalini/PicaComic](https://github.com/Pacalini/PicaComic)：多源客户端与功能设计参考。
- [tonquer/JMComic-qt](https://github.com/tonquer/JMComic-qt)：JMComic 图片重组实现参考。
- [EhTagTranslation/Database](https://github.com/EhTagTranslation/Database)：标签中文翻译数据。
- [the-database/MangaJaNai](https://github.com/the-database/MangaJaNai)、[Spandrel](https://github.com/chaiNNer-org/spandrel)：模型与架构支持，以及对应作者和贡献者。
