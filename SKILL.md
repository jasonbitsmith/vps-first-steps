---
name: vps-first-steps
description: Guide basic initialization of a fresh Ubuntu or Debian VPS using vps-init.sh, including tools, UFW, fail2ban, swap and automatic updates. Use for initial server setup; panel, proxy, WARP and website deployment are outside this skill.
---

# VPS 起手式

先读 README.md 和 vps-init.sh。脚本在目标 VPS 上运行，需要 root 或 sudo；不要在操作者的本机执行初始化。

## 开始前

确认目标服务器由用户授权管理，是无现有业务的新机，并确认 SSH 登录方式、服务商控制台和安全组情况。已有服务时先列出现有端口、UFW 状态和影响，不直接采用默认防火墙配置。

默认运行 `sudo bash vps-init.sh --check`，通过后再运行 `sudo bash vps-init.sh`。保持现有 SSH 登录方式和端口；不要主动加入关闭 root、关闭密码或创建用户的参数。不要声称这是完整的一键 VPS 节点部署。

如用户明确需要新管理账号，说明它将获得免密码 sudo。使用用户自己的 SSH 公钥，验证其对应私钥可用；不要索取或打印私钥。GitHub 账号注册不等于已经配置 SSH 公钥。

## 执行与验证

保留当前 SSH 会话。执行失败时停在失败步骤，检查已发生的修改；不要盲目重跑或宣称整体回滚。

关闭旧登录方式需要用户在第二个终端使用新账号登录，并成功运行 `sudo -n true`。不能代填 VERIFIED 来猜测验证成功。

完成后检查新 SSH 连接、UFW 规则、fail2ban 状态和 swap。说明跳过步骤、失败项及是否需要重启，不自动重启。未进行实机部署时只报告静态测试，不声称服务器已验证。
