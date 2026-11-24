# 隔离性能回归

`./scripts/check-performance.sh --report .build/performance-current.json`

脚本构建 Debug 后链接真实 app 对象，不启动 app 窗口。也可指定已经构建的对象目录，从而不执行 SwiftPM：

```sh
FILMBOX_PERFORMANCE_BINARY_DIR=.build/arm64-apple-macosx/debug \
  ./scripts/check-performance.sh --report .build/performance-current.json
```

新旧计时比较时，两边均传 `--compare-only`，只运行共有负载；完整模式另测新接口和通知竞态。

比较 0.6.1 基线时，先保存旧版本的 `Modules`、`Filmbox.build/*.o`、`FilmboxCore.build/*.o`，然后指定目录及 `--baseline`。此模式保留数据完整性断言，策略缺陷只记录，不阻止采样。

覆盖范围：

- 一万条合成云媒体，仅显示其中 20 条；其余记录分批补充元数据，并通过真实通知合并器再更新一次。
- 一万条真实传输状态流转，检查某个可见文件的观察是否被无关文件触发。
- 96 张真实 JPEG 后台解码，以弱引用检查位图是否进入前台缓存；同时检查前台缓存、查看器大图释放及磁盘缓存离线复用和预算。
- 完整模式另测 256 次只读封面图头的预载、EXIF 旋转比例，以及旧通知正在分块提交时同一批媒体的新值最终胜出。封面文件加载器注入临时 JPEG，不经过云盘账号。

`metadataSetupWorstDelayMs` 单独统计生成、读取测试目录的主线程延迟。`backgroundMainActorWorstDelayMs` 只取元数据、传输及位图三个工作阶段的最大心跳延迟。20 毫秒心跳记录超出计划间隔的时间；这不是屏幕帧率。RSS 是整个检查进程的观测值，报告峰值及后台位图阶段增量，不把配置缓存上限当成进程内存上限。

所有图片、目录和缓存均为临时文件；传输状态使用独立 UserDefaults suite。检查不连接真实网盘、不使用用户账号、不读写剪贴板。编译最多 45 秒，执行最多 75 秒。

查看器胶片导航另用 `./scripts/check-viewer-filmstrip.sh`，复用完整Debug对象，缓存与资料库均在临时bundle内隔离。真实原生集合加载一万项，验证可见单元数量受控、末项定位、连续元数据更新、窗口变化、最新身份选择及筛选恢复；窗口透明且置于屏幕外，不发送桌面输入。执行截止30秒。
