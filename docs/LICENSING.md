# 许可证边界

## 主项目

菲林盒的 macOS 与 Android 自有代码、构建脚本和测试代码依据 GNU Affero General Public License 第 3 版授权，SPDX 标识为 `AGPL-3.0-only`。许可证全文见根目录 [`LICENSE`](../LICENSE)。第三方组件适用下列各自许可证。

## 组件核对

| 范围 | 适用许可 | 对应源码与声明 |
| --- | --- | --- |
| macOS 主应用、自有 Kotlin Android 代码、构建和测试代码 | AGPL-3.0-only | 根 `LICENSE` 与源码归档 |
| CloudEngine 及选取的 OpenList 衍生驱动 | AGPL-3.0-only | `CloudEngine/LICENSE`、`UPSTREAM.md`、`upstream/OpenList/` |
| Mac 独立 ffmpeg／ffprobe | LGPL-2.1-or-later，当前构建未启用 GPL 或 nonfree | `Resources/Codecs/`，应用内完整上游源码与配置 |
| AndroidX、Compose、Media3、Kotlin、Coroutines、Coil、OkHttp、Gradle wrapper | Apache-2.0 | `Android/docs/THIRD_PARTY.md`、APK 内 Apache 许可 |
| Android 的 Public Suffix List 数据 | MPL-2.0 | `Android/third-party/publicsuffix/` 与 APK 许可页 |
| Go runtime | BSD-3-Clause | Android 与 Mac 安装包内 Go 许可 |
| 品牌几何、SVG 与合成测试素材生成器 | 主项目许可证 | `design/lighttable-v1.1/`、测试素材脚本 |

## React Bits 处理

macOS 0.6.25 及更早版本的日期导航保留了 LineSidebar 移植，包括距离衰减、平滑曲线、逐帧指数平滑和联动变换。所引用版本的许可证是 MIT + Commons Clause，包含对组件及移植版本再分发的限制，不能直接把这一部分改标为普通 MIT 或 AGPL。

0.6.26 已移除这套悬停距离算法与联动动画，使用原生命中区域高亮。保留的日期压缩、滚动、年份分界和辅助功能由菲林盒自身实现。当前运行时代码与源码交付中没有 React、React Bits JavaScript 或 CSS。旧版本安装包和原开发 Git 历史保留原声明。

公开源码导出采用当前文件快照，避免把早期设计位图、媒体、开发缓存及旧移植版本一并推送。若希望公开完整开发历史，需要额外审查历史中每个版本的许可与资料，本次保留原本地历史。

## 对应源码

两个客户端安装包提供主项目完整源码归档、源提交、文件树 SHA-256 与第三方许可。云盘组件另保留独立源码归档。FFmpeg 工具同时附准确源码包、构建脚本、配置、版本及哈希。构建签名所需私钥由发布者保管，构建脚本说明签名和凭据组件身份。

相关原始资料见 [React Bits 许可](https://github.com/DavidHDev/react-bits/blob/main/LICENSE.md)、[AGPL 3.0](https://www.gnu.org/licenses/agpl-3.0.html)、[FFmpeg 许可说明](https://ffmpeg.org/legal.html)。
