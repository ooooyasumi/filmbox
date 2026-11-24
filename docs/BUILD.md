# 本地构建

开发构建使用 Python 3.11+、Swift 6.2、macOS 26 SDK，以及 Go 1.23 或更新版本；生成的应用支持 Apple Silicon、macOS 15 Sequoia 或更新版本。当前在 macOS 26 的 Command Line Tools 环境构建，不要求用户安装开发工具。云盘组件仅使用 Go 标准库，没有额外模块依赖。

## 检查与打包

```sh
swift run FilmboxCoreChecks
./scripts/check-behavior.sh
./scripts/check-grid-transition.sh
./scripts/check-media.sh
./scripts/check-performance.sh
./scripts/check-cloud-backend.sh
./scripts/check-search-input.sh
./scripts/check-filters.sh
./scripts/check-focused-download.sh
./scripts/check-browse-photo.sh
./scripts/check-original-cache.sh
./scripts/check-viewer-loading.sh
./scripts/check-viewer-filmstrip.sh
./scripts/check-cloud-preview.sh
# 高清静帧回归需要开发机 FFmpeg 生成本机测试视频
./scripts/check-original-previews.sh
./scripts/check-interaction.sh
./scripts/check-grid-selection.sh
./scripts/check-double-click.sh
./scripts/check-timeline.sh
./scripts/check-playback.sh
# 流播回归需要开发机 FFmpeg（带 lavfi），只生成本机临时视频
./scripts/check-streaming.sh
./scripts/check-formats.sh
./scripts/check-web-playback.sh
./scripts/check-cloud.sh
./scripts/check-cloud-index.sh
./scripts/check-index-feedback.sh
./scripts/check-cloud-transfers.sh
./scripts/check-cloud-keychain.sh
./scripts/check-cloud-login.sh
./scripts/check-stable-signing.sh
./scripts/check-credential-helper.sh
./scripts/check-credential-client.sh
./scripts/check-credential-client.sh --macos15
./scripts/check-compatibility.sh
./scripts/check-library-ux.sh
./scripts/check-media-feedback.sh
./scripts/check-cloud-webm-intent.sh
./scripts/build-app.sh release
```

标准 Swift Testing 源码保留在 `Tests/FilmboxCoreTests`；仅有 Command Line Tools 时使用上述独立检查。交互检查创建不可见的真实原生相册容器，覆盖连续卷滚动范围、虚拟化、选择保留、窗口尺寸变化、筛选与缩放；不向电脑发布输入事件。

网格选择检查直接编译实际 MediaGrid，使用隐藏原生窗口验证单击选择、双击打开、显式多选、范围选择、键盘、辅助功能和右键范围。复制行为检查使用独立命名剪贴板与临时文件，不修改系统剪贴板。

拖选检查使用实际轨迹几何和两个容器的鼠标处理器，验证快速跨图、回扫、原选择保留、过期手势取消及自动滚动。自动滚动直接执行真实单帧 scroll-and-paint 方法，未向桌面发布鼠标事件；Option 文件拖动只检查入口分支，不启动系统拖放会话。

连续日期尺检查复用 Debug 应用对象，验证真实文档定位与压缩日期比例的双向映射、密集日与跨年长度、同日内连续位移、年份位置、标签命中与辅助功能，以及窄尺绘制不会覆盖周围内容。网格视频检查使用无音轨临时视频，真实验证时间推进、独立播放控件、单会话释放及重复空闲更新不触发界面循环。

播放检查直接编译实际组件，原生编码临时 H.264 视频与静音 AAC 音轨，验证自动播放、声音状态、暂停、循环、失败恢复和窗口可见性。真实视频层检查使用从不置前的不可见原生窗口，不操作前台或用户媒体；仅检查静音属性，未测试扬声器实际出声。

脚本从根目录 `VERSION` 读取版本，构建 Release、生成图标、组装 `build/Filmbox.app` 并检查签名。0.6.5 起主程序使用稳定的本地证书及 Hardened Runtime，另复制字节不变的专用凭据组件；两者签名证书必须一致。全部校验通过后才替换输出目录中的旧应用，不会自动启动。开发构建使用 `./scripts/build-app.sh debug`。

可用绝对路径 `FILMBOX_BUILD_DIR` 指定独立输出目录，先完成候选包校验，再正常退出运行中的旧版后替换正式应用。

打包先调用 `build-codec-runtime.sh`，校验并复用或从官方固定源码构建 arm64 `ffmpeg`／`ffprobe`，不使用 Homebrew 库。首次下载源码约 11 MB，独立工具约 20.53 MiB；工具、完整对应源码、配置及许可一同进入应用，详见 [CODEC_RUNTIME](CODEC_RUNTIME.md)。格式检查只用合成夹具，覆盖无封面取帧、元数据修复、缓存与本机 Range 协议；WebM 检查使用隐藏 WKWebView，真实验证帧、时间推进、跳转与后台位置保留。

压缩包可由最终已验收应用生成：

```sh
ditto -c -k --sequesterRsrc --keepParent build/Filmbox.app build/Filmbox-0.6.26.zip
```

最终须核对产物 Info.plist 的版本和签名，并使用该产物完成窗口复验。不能仅凭 `VERSION` 或编译成功判断交付完成。当前记录见 [ACCEPTANCE](ACCEPTANCE.md)。

0.6.7 的云盘指引仅使用原生文字步骤，不再打包教程截图。首次添加与重新登录分别说明，登录后的目录选择界面保持独立。

## 数据与验收隔离

0.5.0 增加 `build-cloud-engine.sh`：构建锁定来源的 OpenList 衍生 helper，运行 Go 测试，生成完整对应源码包，并随应用签名和打包。详细接口、授权依赖和源码位置见 [CLOUD_ENGINE](CLOUD_ENGINE.md)。云盘原生检查仅使用随机测试账号、独立目录与本机只读 WebDAV，结束删除测试钥匙串记录。真实账号与用户原片不进入自动检查。

正式应用标识为 `com.filmbox.app`，中文名“菲林盒”。本轮文件管理窗口 QA 使用独立 bundle、catalog 与复制的合成媒体 `.build/ManagementQAMedia`；夹具与诊断探针不进入 Release 包。真实资料库升级前备份 catalog，原片只读复验。

- 旧 catalog 缺少隐藏和影集字段时按空集合加载；损坏记录须报告并保留，不能静默重置。
- 沿用已有缩略图缓存，升级无需清空。磁盘缓存默认上限 2 GB，可选 512 MB / 2 GB / 8 GB。
- 文件操作回归只对临时夹具执行，系统废纸篓检查恢复自己的测试文件后清理夹具，不操作用户原件。
- 退出等待正在进行的文件操作完成记录迁移及保存，期间不启动新操作。

需要不含私人照片的测试素材，可运行 `swift scripts/make-fixtures.swift`。脚本仅在 `.build/Fixtures` 创建测试图片、视频与子文件夹，重新运行覆盖同名夹具；应用不自动加载这些素材。

当前未启用 App Sandbox。本地构建已启用 Hardened Runtime，仍不代表 Developer ID 分发或 Apple 公证，正式分发流程见 [DISTRIBUTION](DISTRIBUTION.md)，需要发布者的 Developer ID 与 notarytool 配置。

0.6.0 的索引规模回归可用 `FILMBOX_INDEX_SCALE=1 ./scripts/check-cloud-index.sh`，使用十万媒体、一千余目录的合成响应，不连接真实网盘。独立 Debug UI bundle 可通过 Info.plist 的 FilmboxDevelopmentCatalog 与 FilmboxDevelopmentCache 隔离索引、原件及预览缓存，Release 忽略这些入口。

钥匙串回归仅使用随机测试项，结束清理，不读取正式账号。`check-stable-signing.sh` 是负向边界验证：同一本地自签证书的不同主程序仍可能被 cdhash 分区隔离；它不是跨版本保留的正向证明。`check-credential-helper.sh` 才验证固定组件在不同主程序间连续读写，以及拒绝未授权调用；`check-credential-client.sh` 验证实际 Release CloudCredentialVault 到该组件的完整调用。

## 本地签名与固定凭据组件

`prepare-local-signing.py` 首次创建代码签名专用证书及独立加密钥匙串，位于 `~/Library/Application Support/Filmbox Development Signing/`。随机解锁密码保存到登录钥匙串，通过私有标准输入调用系统工具，不进入进程参数、环境或日志；仓库与应用包不含私钥或密码。脚本不添加系统信任，不修改云盘凭据或其他用户钥匙串项的访问权限。构建时临时把专用钥匙串加入搜索列表，结束仅移除自己加入的条目。身份文件不完整时停止构建，不能静默生成替代身份。

`build-credential-helper.py` 首次编译并签名 `Tools/FilmboxCredentialHelper/main.swift`，保存组件及公开校验清单到上述目录的 `credential-helper-v1/`。后续只校验并复制，不重新编译或签名，保留其钥匙串 cdhash 身份。源码、证书、架构或文件内容不匹配时停止；未来组件更新必须设计显式迁移，不能删除此目录后直接覆盖。主程序及组件随应用提供签名和源码，主程序在写入私有管道前验证组件，组件校验实际父进程的身份、证书及运行时保护；不开放凭据端口。

旧版临时签名的钥匙串项不放宽权限，升级后由用户重新登录一次，之后新凭据由固定组件保管。`FILMBOX_SIGN_IDENTITY` 可指定主程序身份，但与现有组件证书不同会在替换旧应用之前失败；切换 Developer ID 不是直接改变量即可完成，须同时安排组件与凭据迁移。

## macOS 15 兼容包

0.6.22 起 SwiftPM、应用声明及视频工具均以 macOS 15.0 为最低版本。查看器玻璃效果通过系统版本判断，仅在 macOS 26 调用；旧系统使用原生材质。`check-app-compatibility.py` 在替换产物之前核对主程序、FFmpeg、云盘及兼容登录组件的真实 Mach-O 最低版本、arm64架构、系统动态依赖和玻璃接口弱链接，避免只改 Info.plist 造成虚假兼容。

原有 `credential-helper-v1` 保持逐字节不变，仅供 macOS 26 的既有安装使用。`build-credential-helper.py --macos15` 在独立 `credential-helper-macos15-v1/` 冻结另一份同协议、同父进程验证要求的兼容组件；不覆盖或重新签名旧组件，不修改钥匙串权限。macOS 15 使用兼容组件，并保存不含秘密的选择标记，升级系统后继续使用相同组件；已有 macOS 26 安装继续使用原组件。包内旧组件的26.0限制属于这个有明确版本分流的兼容例外，不能作为macOS 15的登录路径。

兼容客户端检查仅在临时编译副本中注入系统版本15与独立偏好域，真实验证 Release Vault 的写入、读取、刷新、缺少组件时关闭访问及清理。测试不读取正式账号。静态版本审计与在macOS 26执行通过不能替代macOS 15.8.1实机验证，发布记录应明确区分。
