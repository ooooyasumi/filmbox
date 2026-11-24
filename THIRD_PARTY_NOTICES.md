# 第三方说明

菲林盒自有源码采用 AGPL-3.0-only，全文见根目录 `LICENSE`，各组件的许可边界见 `docs/LICENSING.md`。

## OpenList 与 CloudEngine

CloudEngine 提取并修改了 OpenList 提交 `e72822f5390f4272c9fe9da8cabba3c1a270182f` 的百度、夸克只读驱动，采用 AGPL-3.0-only。原始文件与版权归相应贡献者，完整许可见 `CloudEngine/LICENSE`，来源和修改说明见 `CloudEngine/UPSTREAM.md`。运行时使用 Go 标准库，其 BSD-3-Clause 声明随包提供。

客户端通过带认证的本机 HTTP 接口调用此独立组件。两个平台均随包提供对应源码和构建资料，应用的关于／设置页可找到源码。进程边界本身不能决定许可证的适用范围。

## FFmpeg

macOS 使用从官方未修改 FFmpeg 9.0.2 源码构建的 ffmpeg／ffprobe 独立工具，当前构建采用 LGPL-2.1-or-later，未启用 GPL、nonfree 或外部编解码库。工具未静态链接到 Swift 主程序。完整 LGPL 文本、源码归档、构建脚本、配置和二进制校验记录位于安装包 `Contents/Resources/Licenses/Codecs/`。

FFmpeg 的相关 JPEG 实现基于 Independent JPEG Group（IJG）的工作。该上游源码未修改。完整归属说明包含于 `Resources/Codecs/FFmpeg-LICENSE.md` 及随附上游源码。构建细节见 `docs/CODEC_RUNTIME.md`。

## Android 依赖

AndroidX／Compose／Media3、Kotlin／Coroutines、Coil 2.7.0、OkHttp 4.12.0、Okio、Guava、JSpecify、Accompanist 和 Gradle wrapper 采用 Apache-2.0。Android 平台与依赖版权归相应作者，版本、归属和全文入口见 `Android/docs/THIRD_PARTY.md` 与 APK 内许可页。

OkHttp 附带的 Public Suffix List 数据适用 MPL-2.0。完整 Mozilla 许可、原始 NOTICE 和可编辑规则源随 Android 安装包／完整源码提供，精确数据哈希见 `Android/third-party/publicsuffix/source.json`。

## 早期 React Bits 引用

早期照片叠放、轻微反光与胶片导航受到 React Bits 交互思路启发。0.6.25 及更早安装包中的 LineSidebar 移植按当时随附的 MIT + Commons Clause 声明处理。0.6.26 的日期悬停交互已改为独立原生实现，移除距离衰减及逐帧平滑移植代码。历史许可核对见 `docs/LICENSING.md`。

原项目和原作者的名称、标志及商标仍归其权利人。
