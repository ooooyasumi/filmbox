# macOS 正式分发与凭据迁移

## 本次环境与缺口

开发机为 Apple Silicon、macOS 26.6.2，Swift 6.3。钥匙串查询没有发现有效的 Developer ID Application 身份。Apple 公证所需的 notarytool 钥匙串配置名称也尚未提供。macOS 15 机器和真实云盘测试账号待发布者安排。

## 构建流程

本地开发构建继续使用 `scripts/build-app.sh`。正式分发使用以下变量，值只引用钥匙串中的身份与配置名称。

```sh
export FILMBOX_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export FILMBOX_NOTARY_PROFILE='YOUR-NOTARYTOOL-PROFILE'
./scripts/build-distribution.sh
```

notarytool 配置由发布者使用 Apple 官方工具存入钥匙串。Apple ID、应用专用密码、API 私钥与证书私钥应在钥匙串或发布者的秘密存储中保管。脚本通过 profile 名称提交公证。

正式流程签名主程序、云盘引擎、两个 FFmpeg 工具和正式凭据组件，启用 Hardened Runtime 与安全时间戳。随后提交 Apple，要求结果为 Accepted，附加并验证票据，再执行 Gatekeeper 评估。最终 ZIP 在票据附加之后创建，避免发布公证前的旧 ZIP。返回的公证标识及哈希应写入发布记录。

## 固定登录组件

现有本地组件源码 `Tools/FilmboxCredentialHelper/main.swift` 及其冻结二进制按既有规则验证。新正式组件为 `Tools/FilmboxDistributionCredentialHelper/main.swift`，最低 macOS 15，标识 `com.filmbox.app.credential-helper.distribution.v1`，凭据服务 `com.filmbox.app.cloud.credentials.distribution.v1`。

正式组件冻结于 `~/Library/Application Support/Filmbox Distribution Signing/credential-helper-developer-id-v1/`。清单记录源码 SHA-256、证书 SHA-1、架构、最低系统和二进制 SHA-256。任一字段变化会停止复用，需安排新 profile 及迁移。主程序选择由包内 `FilmboxCredentialProfile=developer-id-v1` 明确决定。组件和主程序互相校验证书及标识。

从 0.6.25 本地签名升级到正式签名时，catalog 的路径、账号 ID、目录和整理记录继续沿用。新组件从自己的凭据服务读取，首次没有凭据会进入“需要重新登录”。用户在原账号的重新登录入口完成授权后，保存新凭据并恢复原资源库。旧本地服务的访问权限保持原边界，原本地签名组件仍按原冻结清单保存。

证书轮换、丢失签名身份和修改固定组件均需重新评估迁移。不得通过删除冻结目录来绕过身份变化检查。

## 实际验收项目

本次可独立检查源代码路由、不同 profile 的组件名称、最低系统、清单防篡改逻辑、本地同签名更新及模拟凭据状态。Developer ID 实际签名、公证 Accepted、stapler、Gatekeeper 首次下载启动和正式签名跨版本账号更新，均需有效分发身份后执行。

发布者应在 macOS 15 与当前较新系统各完成以下流程，逐项记录系统、设备、账号和证据。

- 从公开地址下载，保留正常下载隔离属性，首次解压启动。
- 从 0.6.25 的独立测试 catalog 升级，核对索引、影集和收藏。
- 确认需要重新登录时有对应入口，取消后仍保留账号和目录。
- 登录成功后读取原目录、缩略图、原图与视频，再退出并重开。
- 在同一正式签名 profile 下再次更新，核对凭据持续可读。

验证只可使用专用账号和合成媒体。完成记录放入本次发布验收文档。
