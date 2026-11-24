# 参与贡献

提交问题前先确认平台、版本与复现步骤。反馈入口位于 README 和 `release.json`，连接问题可先查看 `docs/RECOVERY.md`。安全问题请按 `SECURITY.md` 处理。

1. 从当前源码创建分支，每次修改围绕一个具体问题。
2. 使用临时测试账号和生成素材。运行 `python3 scripts/generate-test-media.py` 准备媒体夹具。
3. 执行 `python3 scripts/check-release.py` 和本次修改涉及的检查，完整命令见 `docs/RELEASE.md`。
4. 提交说明写清问题、修改和验证范围。界面变化附合成素材截图，涉及行为变化更新对应平台版本和更新记录。

PR 使用项目当前许可证。新增第三方代码需注明版本、来源、许可证和修改内容，并同步包内声明。签名密钥、Cookie、令牌、私人相片与运行时数据库应保存在仓库外。
