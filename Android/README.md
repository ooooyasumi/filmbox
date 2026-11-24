# 菲林盒 Android

原生 Kotlin / Jetpack Compose 应用，与 macOS 版共用品牌、配色和云盘连接引擎。当前 Android 版本为 **0.4.1**，独立编号。

支持 Android 11+、arm64 手机和平板。使用系统相册授权和系统文件夹选择器，不要求所有文件访问权限。手机点按打开照片，长按进入多选；照片流围绕双指中心连续调整密度，松手后吸附到相邻档位，以行内日期按天、周、月、年分隔。图片查看器只用手势缩放和拖动，支持双击缩放与左右切换，横屏默认全屏，轻点收放覆盖式工具栏。

## 工程

- `app/src/main/java/com/filmbox/app`：界面、索引、整理记录、缓存、播放及云盘连接。
- 本地照片和视频通过 MediaStore 访问，额外文件夹通过系统 SAF 持久授权访问。
- 元数据与收藏、隐藏、影集分别存储；刷新比较完整快照后只更新变化记录。
- 云盘索引通过 WorkManager 持久调度，每个文件夹完成后保存检查点；前台显示真实项目数与目录数，回到软件后重新接续进度。系统强制停止时不能继续运行，重新打开后恢复调度；厂商省电策略可能延后后台任务。
- 云盘复用仓库 `CloudEngine` 的百度、夸克和 WebDAV 驱动，以独立本机进程运行，不需要用户部署服务器。
- 云端缩略图只加载浏览附近的内容，聚焦图片才下载原图，移开取消尚未完成的下载。视频支持按需流式播放。
- 原图缓存上限 2 GiB，缩略图和高清静帧分别有 256 MiB 预算。清除缓存不影响原文件或整理记录。
- 照片流使用单层画布，只排布视口及少量余量，最密集档位为按年总览；悬浮日期随浏览更新。本地小图优先复用系统缩略图，预览最多四路读取，从左上角向外扩散，覆盖全部可见照片并在上下各预取最多 12 项。
- 设置为独立页面，外观、浏览、云盘、存储、帮助、关于分别进入；工具栏避让系统栏与开孔，临时提示在屏幕底部显示。

构建：JDK 17、Android SDK 35、Go 1.23+、Python 3.11+，在 `Android/local.properties` 配置 `sdk.dir`，执行根目录 `scripts/build-android.sh`。本机路径、签名密钥和生成的二进制不入库。

启动图标与 Mac 正式版共用 `design/lighttable-v1.1/identity-spec.json`。更新品牌规范后执行 `python3 scripts/generate-android-icon.py`，构建时会检查 Android 资源是否同步。Android 自适应图标只交由系统处理外轮廓，内部图形比例、留白与配色保持一致。

Android 客户端自有代码采用 [AGPL-3.0-only](../LICENSE)。客户端和云盘组件的对应源码与许可随 APK 提供，可在「设置」查看和导出。上游来源和修改说明见 [CloudEngine](../CloudEngine/UPSTREAM.md)，依赖许可见[第三方说明](docs/THIRD_PARTY.md)。

Android 权限依据：[媒体访问](https://developer.android.com/training/data-storage/shared/media)、[Android 14 部分照片授权](https://developer.android.com/about/versions/14/changes/partial-photo-video-access)。

## 使用与边界

手机点按打开、长按多选，查看器长按打开操作菜单；资源库长按可重新加载、改名、调整顺序或移除。原文件修改使用 Android 的写入许可；移到回收站由系统确认。只读文件夹可能无法修改，云盘资源目前只读。系统相册项目使用系统回收站；额外文件夹中的删除目前交由系统文件管理器处理。

支持系统可以解码的照片和视频；不同设备的 HEIF、RAW、HDR 与视频编码支持取决于系统。无法预览的本地文件可以通过“打开方式”交给其他应用。

百度授权入口沿用 PC 版的 OpenList 授权页；夸克使用独立 WebView 登录，也提供手动连接。WebDAV 当前使用 HTTPS 地址。百度、夸克真实账号与各品牌手机尚未完成实测，自动云盘检查以隔离 WebDAV 服务验证索引、权限隔离及文件读取。

收藏、隐藏与影集保存在手机本机，当前不与 macOS 自动同步。原图“下载”表示应用缓存，受 2 GiB 上限及清理操作影响；需要长期保留时，通过系统分享保存到其他位置。

浏览交互与索引机制见 `docs/MOBILE-UX.md`；连接错误与恢复规则见 `../docs/RECOVERY.md`。

## 验证

`gradle :app:testDebugUnitTest :app:connectedDebugAndroidTest` 检查逻辑及设备端行为。正式签名包使用自带 `com.filmbox.qa.ReleaseProbe` 进行黑盒验收，仅通过系统公开界面操作，不依赖被优化的应用内部类。发布前执行 `scripts/check-android-package.py` 检查签名、系统版本、架构、原生组件对齐及私密文件排除。

本次使用 Android 15 / API 35、arm64 模拟器；未连接真实 Android 手机。测试素材为程序生成图案，不随正式 APK 分发，也不使用 Mac 的个人资源库。

正式包使用本机独立 Android 签名，密钥保存在仓库外。后续同包升级必须继续使用同一签名；不要删除或公开签名文件。
