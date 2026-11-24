# 第三方组件

AndroidX / Jetpack Compose / Media3：Android Open Source Project，Apache License 2.0。 https://android.googlesource.com/platform/frameworks/support/

Coil 2.7.0：Coil contributors，Apache License 2.0。 https://github.com/coil-kt/coil

OkHttp 4.12.0：Square, Inc. / contributors，Apache License 2.0。 https://github.com/square/okhttp

Kotlin / kotlinx.coroutines：JetBrains / contributors，Apache License 2.0。 https://github.com/Kotlin/kotlinx.coroutines

Go runtime：The Go Authors，BSD 3-Clause。 https://go.dev/LICENSE

Filmbox Cloud Engine：AGPL-3.0-only，部分源自 OpenList。完整对应源代码、原始文件、版权和许可证在 APK 的 `assets/cloud-source.tgz` 以及仓库 `CloudEngine/` 中。设置中可导出源代码；不以进程分离为由免除许可证义务。

Apache-2.0、Go BSD 和引擎 AGPL 全文包含在 APK 内，可在设置阅读。Android 测试视频为本仓库原有合成图案与正弦音频，说明见 `app/src/androidTest/assets/README.md`。

主应用许可与完整源码由根项目的发布流程加入 APK，可在“设置 → 关于 → 开源许可／导出源代码”查看。源码对应记录位于 `source-build.json`。Android 发布不包含 FFmpeg 或 React Bits 运行时。


## 传递依赖与数据

Okio 3.9.0、Google Guava 33.3.1-android／failureaccess 1.0.2、JSpecify 1.0.0、Accompanist DrawablePainter 0.32.0 使用 Apache-2.0。Guava 许可来自其 POM parent，运行时依赖树可用 Gradle 的 `:app:dependencies --configuration releaseRuntimeClasspath` 核对。

OkHttp 4.12.0 附带的 Public Suffix List 数据单独适用 MPL-2.0。APK 许可页包含 Mozilla 许可全文和该资源原始 NOTICE。该次二进制的可编辑规则源、原始归属及数据哈希保存在 `third-party/publicsuffix/`，并随主项目完整源代码一起导出。执行 `python3 scripts/check-public-suffix-source.py` 可核对规则源与打包数据负载完全一致。未把这部分数据统一改标为 Apache 或主项目许可。
