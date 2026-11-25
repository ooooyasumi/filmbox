# 发布检查清单

macOS 与 Android 独立编号，由根 `VERSION`、`Android/VERSION` 和 `release.json` 记录。行为变化修改对应版本和 CHANGELOG，历史产物留在各自版本目录。

## 源码检查

```sh
python3 scripts/check-release.py
python3 scripts/audit-source.py
python3 scripts/check-public-suffix-source.py
python3 scripts/generate-test-media.py
cd CloudEngine && go test ./...
```

macOS 执行 `swift run FilmboxCoreChecks` 和 `docs/BUILD.md` 中本次修改涉及的原生检查。Android 使用 JDK 17、SDK 35，执行 `Android/gradlew -p Android :app:testDebugUnitTest`。设备检查需要先构建云盘引擎和合成媒体，命令见 Android README。

## 候选构建

```sh
./scripts/build-app.sh release
./scripts/build-android.sh
python3 scripts/source-release.py --manifest build/source-build.json --archive build/filmbox-source.tar.gz
```

候选包包含完整源码、许可和构建对应记录。`source-build.json` 记录构建时的提交、工作区状态与源码文件树 SHA-256。公开发布前应提交源代码，用 `--public` 导出已确认许可且工作区整洁的源码归档。

正式 Mac 包执行 `scripts/build-distribution.sh`，完整依赖和迁移规则见 `DISTRIBUTION.md`。Android 正式包沿用发布者原有签名文件，私钥存放在仓库外。

## 发布前核对

- 主项目许可证已由负责人确认，包内全文、第三方归属和对应源码齐全。
- 正式 GitHub、下载与反馈地址可访问，许可证及隐私页可打开。
- 下载文件名、包内版本、最低系统、架构与更新说明一致。
- 源码提交和二进制发布记录对应，生成最终 `SHA256SUMS`。
- Mac 签名、公证 Accepted、票据、Gatekeeper 和实际升级通过。
- Android 签名证书与上一版本一致，实际覆盖安装保留整理记录。
- 用复制的损坏包和中断下载核验失败信息，安装帮助提供重新下载与校验方式。
- 真实账号与实体设备项目按 `CLOUD-ACCEPTANCE.md` 记录，待验证能力在网站和说明中可见。
- 检查源码归档中没有网站、宣传片、私人媒体、凭据、本机缓存或签名私钥。

公开入口配置后可运行 `python3 scripts/check-release.py --public --artifacts 发布目录 --site 网站版本目录`。此命令检查公开地址配置和发布回执，外部 URL 的实际连通性仍需通过浏览器或 HTTP 检查，并写入验收记录。

源码导出在解包后也可构建，须从该源码另跑核心检查和至少一个平台构建。最终分发应使用已验收的同一文件，发布后修改文档不应替换已公布二进制。

## 首次公开仓库

从带根 `LICENSE` 的干净源码快照建立独立的 GitHub 仓库。快照包括客户端、云盘引擎、构建脚本和文档截图。原开发历史包含早期设计资料和第三方移植，宣传网站及视频有独立目录。

取得正式地址后，在准备公开的独立仓库中运行 `scripts/configure-public-repository.py`，接通 README 的 Star 计数、检查状态、下载和反馈入口。提交地址配置后重新构建并验收。公开提交、包内源码文件树和最终发布回执必须一致。公开分发前按上方清单完成签名与公证验收。
