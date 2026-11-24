# 内置云盘核心

菲林盒的云盘辅助进程复用 OpenList 的百度网盘、夸克网盘驱动逻辑，
并提供通用 WebDAV 接入。无需用户安装 OpenList、配置服务端口或挂载磁盘。
这是只读资源库版本：本地收藏、影集、隐藏等组织功能由菲林盒维护，
辅助进程不提供远端删除、重命名或上传接口。

## 构建及随包源码

运行 `sh scripts/build-cloud-engine.sh`。需要 Go 1.23 或更新版本。
默认生成 macOS arm64、无 CGO 依赖的辅助程序：

```
.build/CloudEngine/install/filmbox-cloud-engine
.build/CloudEngine/install/filmbox-cloud-engine-source.tar.gz
.build/CloudEngine/install/LICENSE
.build/CloudEngine/install/UPSTREAM.md
```

主应用打包将程序复制到 `Contents/Helpers/filmbox-cloud-engine`，
将源码归档、许可和改动记录复制到 `Contents/Resources/Licenses/CloudEngine/`，
并在签名应用前先签名辅助程序。设置 `FILMBOX_ENGINE_ARCH=amd64` 可构建 Intel
版本。`CloudEngine` 使用 AGPL-3.0；不在此文件中擅自更改主应用许可。
准确上游版本、原始文件和改动记录见 `CloudEngine/UPSTREAM.md`。

## 进程

启动参数 `--port 0`（默认）自动选择回环端口，`FILMBOX_CLOUD_SECRET`
环境变量传入至少 16 字节的随机秘密。进程启动后从自身环境删除该值。
标准输出只有一行 `{"port":12345}`；标准错误不输出请求地址、令牌或 Cookie。
仅监听 `127.0.0.1`，每个接口（包括 health 和资源流）均要求
`Authorization: Bearer <secret>`。父进程退出或收到 SIGTERM 时关闭。
测试工具可显式传 `--watch-parent=false`。

## 接口

全部请求 JSON，除健康检查和资源流外均为 POST。错误是
`{"error":"可展示的中文信息","code":"machine_code"}`，不包含上游原始内容。

* `GET /health` → `{status,version}`。
* `/v1/accounts/connect` ← `{account_id,provider,credential,endpoint?,username?,password?}`；
  → `{name,root_id,credential,credential_revision}`。根目录 ID：夸克 `0`，百度/WebDAV `/`。
* `/v1/accounts/disconnect` ← `{account_id}`，清除内存中的该账号。
* `/v1/accounts/credential` ← `{account_id}` → `{credential,credential_revision}`。在媒体流结束或取消后、
  定期同步或正常退出前读取最新会话，再按连接代次及版本更新 Keychain 中的对应项。
* `/v1/files/list` ← `{account_id,folder_id,path}`；
  → `{entries:[{id,name,is_directory,size,modified,created?,width?,height?,duration?,thumbnail?}],folder_id,path,credential,credential_revision}`。
  日期均为 UTC ISO 8601；path 是真实网盘相对根目录的绝对路径，`/` 表示根。
* `/v1/files/resolve` ← `{account_id,file_id,path,purpose?:"thumbnail",direct?:false}`；
  → `{url,headers,expires_at?,thumbnail_available,credential,credential_revision}`。
  默认 URL 是本地资源代理，只需传回响应的 Authorization 请求头。
  `purpose:"thumbnail"` 只读取提供商缩略图；没有时返回
  `thumbnail_unavailable`，不再返回原文件链接作为缩略图回退。
  原生任务显示安静的无封面状态。诊断时可以 `direct:true` 获取远端链接。
* `GET|HEAD /v1/asset?account_id=…&file_id=…&path=…&purpose=thumbnail`；
  转发 Range、If-Range 和内容响应头，支持视频拖动播放。
  临时链接失效时会重新解析并重试一次。

原始缩略图地址可能需要 Cookie 或 User-Agent，原生应用应调用 thumbnail
resolve，不能把列表中的 thumbnail 地址直接当成无条件可访问的公共图片。
控制 JSON 响应中的非空 credential 携带同一 helper 内账号单调递增的 credential_revision，重连也继续递增；原生按登录代次、helper 实例和版本接收，拒绝过期回复。已连接账号的 list/resolve 错误响应也可能携带轮换后的 credential，应先接收再展示错误。首次未验证连接的失败不登记账号或写入新钥匙串项，重登失败不覆盖原身份。

媒体代理也会合并有效 Set-Cookie，包括跳转响应，并以最新 Cookie 访问缓存链接。`/v1/asset` 及其错误 body 始终不包含凭据或版本，避免 URLSession 将控制信息当媒体保存到临时磁盘文件。原生从独立的 `/v1/accounts/credential` 控制接口在流结束、原图取消、播放验证及每15秒本机快照中收集更新；这不是定时访问夸克的保活请求。未变化凭据不反复操作钥匙串，辅助进程不写明文会话文件。

## 索引与缓存策略（0.6.5）

每个资源库有独立 staging、目录检查点、追加完成日志与小状态文件。目录完整列完才落检查点，整库成功才原子替换正式项目；失败与取消保留旧目录。未发布的完整 staging 由 scanner actor 后台恢复，启动不在主线程解码整库。文件版本不变时复用已学尺寸、日期及用户集合；网盘变化仍需通过列目录核对，自动校对间隔 30 分钟，手动刷新立即执行。

预览尺寸分为 256、768、1600、4096。正常网格使用768，照片卷邻近单元最高1600；照片卷当前聚焦图片与独立照片查看器使用最长边4096像素的原件显示。照片卷当前图先获取完整原件，再进行高清解码，避免邻近封面等待占满解码槽而阻塞聚焦下载；即使显示预览仍在，原件缓存已清理时也会重新获取当前原件。失焦取消该消费者，若无其它查看器或手动下载消费者，取消会穿过解码任务与Resolver至实际HTTP请求；已完成原件保留。邻域预取依次为当前、右1／左1至右4／左4，仅请求768封面，不预载邻近原件。缩略图默认只读视口与附近内容，可选全库后台封面预载。全库预载只保存提供商封面、读取图像头部补充比例，不解码位图或把全库图片装入内存；实际浏览时再从封面生成对应显示预览。缺少／损坏封面的后台任务不取原图或视频帧；全库完成日志防止自动淘汰后重新下载，手动清云缩略图会重置日志并保持后台暂停，等待用户继续。

预览磁盘目录下分 local、cloud、highResolution，旧根目录缓存继续兼容，单独统计为 legacy。生成和读取磁盘缩略图共用 3 个解码名额；前台内存缓存预算 64 MiB／192 项，后台预取只保留磁盘结果，4096 大预览仅由当前卷轴焦点或查看器持有，失焦或关闭后释放。该预算不是整个应用的内存上限，当前可见图片、播放器及系统框架另有占用。磁盘预览默认 2 GiB。云端封面及完整原件另有默认 8 GiB 池，首次在后台建立缓存字节账本，此后随文件增删维护，预算充足时不逐文件枚举目录。下载前预留预算，封面单个最多 16 MiB，实际响应过大即停止；后台预载在池占用达到 95% 时停止。正在查看、播放、近期使用与导出中的文件会受保护；降低预算或清理时可能仍保留这些文件，UI显示未释放部分。

元数据通知在交互停稳后合并，每批最多 256 条，批次间让出主线程；只更新受影响的描述和日期组几何，屏外项目不发布可见布局变化。元数据持久化合并到约 2 秒一次，退出仍保存最新状态。单文件进度只通知该文件，任务列表最多每 100 毫秒刷新，活动／排队／失败数量增量维护；流量仍每秒采样。未变化的会话凭据不反复读取、写入钥匙串。

原生视频使用认证 Range 代理，不保存持久的视频分片。WebM 连续浏览只探测已缓存原件，不自动整片下载；明确下载或独立查看器打开后才缓存原件再由 WebKit 播放。

`POST /v1/traffic` 返回 helper 会话标识、真实上游接收字节、每日接收字节和活跃流数量。原生每秒采样，累计会话／当日流量；URLSession delegate 仅上报单文件进度，不再次计入总量。目录响应和媒体 body 都计流量，不计本机回环转发字节两次。

## 授权差异

夸克 credential 为用户在菲林盒隔离登录窗口中获得的该站点 Cookie。
辅助进程会通过真实根目录请求确认登录，而不把游客配置接口当登录成功。
登录窗口只收集可用于夸克 API 的非空 Cookie，必须有有效 `__puus`，`__pus` 可选；等待写入短暂稳定再提交验证。取消及过期页面回调不写入新登录。WebKit 登录兼容性仍需用真实用户的自主登录验证。

百度 credential 支持 refresh token 字符串，或 JSON 字符串：
`{access_token?,refresh_token?,client_id?,client_secret?}`。
不提供自有 client_id/client_secret 时，刷新沿用 OpenList
`https://api.oplist.org/baiduyun/renewapi` 在线服务；这一步会将 refresh token
发送到该服务，不能描述为完全直连百度。提供自有凭据时直接向百度刷新。
公共授权服务是否允许长期用于第三方分发、百度平台限额和夸克接口兼容性，
仍取决于服务方政策，不能保证这些第三方接口长期不变。

## 验证边界

自动检查覆盖 HTTP 身份验证、错误脱敏、夸克分页/会话更新、百度令牌刷新、
WebDAV 目录及媒体 Range 代理。自动检查不替代真实百度/夸克账号登录验收，
也不会读取浏览器现有 Cookie、用户网盘令牌或修改远端原件。

### 应用更新与钥匙串恢复（0.6.5）

凭据仅持久保存在系统钥匙串，账号使用原 UUID，`catalog` 不包含 Cookie。主程序经私有标准输入输出调用 `filmbox-credential-helper-v1`，不开放端口，不把凭据放进参数、环境、日志或文件。组件限定服务 `com.filmbox.app.cloud.credentials.v1`、UUID 账号以及读取／保存／删除三种操作；验证实际父进程的主应用标识、同一签名证书、Hardened Runtime 及无危险签名例外，主程序也在发送请求前验证实际组件。

仅固定本地自签证书不足以保留变化程序的通用钥匙串分区：Apple Security 实现对该类证书仍可能使用 cdhash。故打包将已签名的专用组件逐字节沿用，不随主程序更新重签；它保持自身钥匙串身份，主程序可独立升级。旧版临时签名的项不放宽权限，0.6.5 首次需要用户重新登录一次，之后新凭据由固定组件保管。组件源码、证书或架构变化须显式迁移；签名构建与负向／正向检查见 [BUILD](BUILD.md)。该结论依据 [Apple Security 分区实现](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp)，不能把本地证书等同于 Developer ID 或公证。

系统访问禁止弹授权窗口，worker 有5秒截止且最多一个未结束系统调用，组件与客户端分别有6秒和8秒边界。锁屏、钥匙串暂不可用或繁忙超时不会标记账号退出；最新会话保留内存，持久保存按账号串行并重试。只有确实缺少凭据、解锁后的访问拒绝或明确上游失效才要求重新登录。临时连接失败保留原身份与旧钥匙串值。测试不会读取正式账号或改写其访问权限。

### 登录失效状态（0.6.5）

认证失效集中到账号状态，主界面与设置提供重新登录入口。已确认失效后不再自动尝试新网络请求，终止该账号旧的排队及在途下载；已有缓存和其他账号保持可用。只有明确重新登录成功才清除状态。夸克仅明确401／31001／31004视为失效；当响应确实轮换 Cookie 时可用新会话重试一次。目录503、通用403、容量32003、单文件41017及解码失败不判整账号退出；[夸克官方资料](https://github.com/quark-clouddrive/quarkclouddrive_offical/blob/main/skills/quarkclouddrive/references/file-saveas.md)亦将32003列为容量限制。播放失败通过合并且限频的目录请求复核，旧helper或旧登录错误不污染新会话。原生视频仍采用在线Range读取，没有新增持久分片缓存。
