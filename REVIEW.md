# 改进说明

本次改进基于 jasonbitsmith/vps-first-steps 原有脚本；默认流程的有限实机验证见 TESTING.md；其他范围仍待完成。

## 已改进

- README 改为中文，默认流程只需下载、检查、运行；区分本地终端与 VPS 终端。
- 默认保留现有 SSH 登录策略与端口；不再在没有替代账号时关闭 root 登录。
- 新增 --check，只读检查系统、SSH 配置与参数；公钥 URL 检查会进行 HTTPS 请求。
- 公钥和用户参数先校验，再修改系统；拒绝空公钥、无用户的关闭登录请求和无效端口。
- 可选管理账号配置经过 visudo 校验的免密码 sudo，并明确告知权限。
- 关闭旧登录入口前要求第二会话验证；不允许 --yes 跳过。
- SSH 修改校验或 reload 失败时恢复配置备份；默认不触碰 SSH 配置。
- 不覆盖整个 fail2ban/jail.local；改为专用 jail.d 配置。
- --no-basic-tools 不再漏装其他已启用功能的必要依赖。
- 不覆盖已存在但未启用的 /swapfile；不自动 autoremove 软件包。
- 新增 SKILL.md 与安全的本地回归测试。

## 验证

- bash -n：通过。
- git diff --check：通过。
- python3 -m unittest test_cli -v：3 个测试方法通过，其中输入验证覆盖 8 个错误案例。
- SSH 失败恢复测试使用临时文件及模拟 sshd/systemctl，不会修改真实系统。
- Skill 官方快速校验器因本机缺少 PyYAML 未运行完成；frontmatter 已人工检查。
- 初版静态审查后，用户进行了默认流程测试，见 TESTING.md。

## 发布前应完成的实机验证

在可销毁的新 VPS 上验证 Ubuntu 与 Debian：默认初始化、非 22 端口、已有 swap、跳过选项、新用户 sudo、公钥登录和 SSH 限制流程。检查服务商安全组与 Ubuntu socket activation 的实际端口。

更改 SSH 端口已退出本版支持范围；已有业务服务器与复杂 SSH Match 规则需要人工审查。SSH 配置采用前置指令使全局策略优先，依据 [OpenSSH 官方说明](https://man.openbsd.org/sshd_config)；Match 块可能另行影响特定连接，不能仅凭全局配置证明所有连接行为。

这个版本优化了默认入口，并非完整安全审计。系统升级和防火墙更改没有整体事务回滚。
