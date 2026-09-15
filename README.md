# VPS 起手式 · Jason 数字生活

给刚买的 Ubuntu / Debian VPS 做基础初始化：安装常用工具、配置防火墙、登录防护、交换空间和自动安全更新。

**在你的 VPS 终端里运行。默认保留现有 SSH 登录方式和端口。**

> 当前为待实机验证的改进版本。已做本地语法和输入校验测试；尚未验证各发行版上的完整部署，不承诺所有 VPS 均可运行。

## 先弄清楚：这个项目做什么？

| 会做 | 不包含 |
| --- | --- |
| 更新系统和安装 curl、git、vim、htop 等工具 | aaPanel、3x-ui、WARP 的部署 |
| UFW 防火墙和 fail2ban 登录防护 | 建站、代理节点、域名和证书配置 |
| 默认 2G swap（磁盘上的备用内存） | VPS 购买和自动连接服务器 |
| 自动安全更新 | 自动重启服务器 |

只适合**刚创建、还没部署业务的 VPS**。已有网站、Docker、数据库或其他服务的机器，应先单独检查端口和防火墙，不要照抄运行。

## 开始前准备

- Ubuntu 或 Debian，使用 apt 和 systemd；其他系统暂不支持。
- 能通过 SSH 登录服务器，使用 root 或能执行 sudo 的账号。
- 知道服务商网页控制台在哪里：SSH 出问题时可从那里操作。
- 磁盘至少为 2G swap 留出空间，外加软件更新所需空间；空间不足用 `--no-swap`。

**终端是什么？** 就是你连接 VPS 后输入命令的窗口。下面命令运行在 VPS 上，不是在 Mac 或 Windows 的本地终端里直接运行。

## 新手只需三步

### 1. 下载脚本

在 VPS 终端粘贴：

```bash
curl -fsSL https://raw.githubusercontent.com/jasonbitsmith/vps-first-steps/main/vps-init.sh -o vps-init.sh
```

如果提示找不到 curl，先执行 `sudo apt-get update && sudo apt-get install -y curl`，再下载。

可以先用 `less vps-init.sh` 查看脚本，按 `q` 退出。无需设置可执行权限。

### 2. 检查环境（不会修改系统）

```bash
sudo bash vps-init.sh --check
```

看到 `Checks passed` 后再继续；看到红色错误就先处理，不要跳过。

### 3. 开始初始化

```bash
sudo bash vps-init.sh
```

阅读提示，输入 `y` 并回车。等到出现 `VPS initialization complete`。

**运行期间保留窗口。完成后另开一个终端，用原来的用户名、密钥或密码、端口再次登录，确认成功后再关闭旧窗口。**

> 上述下载地址指向 main 分支的最新版本；当前仍待 VPS 实机验证。

## 完成后检查什么？

```bash
sudo ufw status verbose
sudo systemctl is-active fail2ban
swapon --show
```

- 防火墙应显示 `active`，并放行你的 SSH 端口。
- fail2ban 应显示 `active`。
- 未跳过 swap 时，应能看到交换空间；已有 swap 会保留。
- 系统升级可能要求重启。先验证新连接，再自行安排重启。

## 常见问题

**网页打不开了？** 默认只新增 SSH 放行规则，其他服务端口不会自动放行。部署网站时，需要根据实际服务另行允许 80/443；服务商安全组也要允许对应端口。

**SSH 是不是只能用 22？** 不是。脚本检测当前配置的端口。若连接实际端口与配置不一致（例如 socket activation），会停止，避免错误配置防火墙。此版本不提供改端口功能。

**执行一半报错怎么办？** 保留窗口，记录最后的错误，先判断已执行步骤。系统更新没有整体回滚功能；不要认为重跑必然安全。SSH 配置修改失败会恢复本次修改前的配置文件。

**GitHub 用户名能直接用来登录 VPS 吗？** 不能。GitHub 账号也不一定有 SSH 公钥。只有你持有对应私钥的公钥才能用于登录，切勿使用别人的 `.keys` 地址。

**能多次运行吗？** 已有用户、已有 swap 和相同公钥会被检查；但系统升级、UFW 和配置写入仍会执行。现有业务机器需要人工评估。

## 可选参数

| 参数 | 用途 |
| --- | --- |
| `--check` | 只读检查，不执行初始化 |
| `--timezone Asia/Shanghai` | 设置时区；默认不改 |
| `--no-swap` / `--swap 1G` | 不创建 swap / 修改大小 |
| `--no-firewall` | 跳过 UFW 配置 |
| `--no-fail2ban` | 跳过 fail2ban |
| `--no-auto-updates` | 不配置自动更新 |
| `--no-basic-tools` | 跳过常用工具；必要依赖仍安装 |
| `--user deploy --ssh-key "公钥全文"` | 创建密钥账号，并授予免密码 sudo 管理权限 |
| `--ssh-key-url https://github.com/你的用户名.keys` | 从 HTTPS 地址读取自己的公钥 |
| `--disable-root-login` | 验证新账号后关闭 root SSH 登录 |
| `--disable-password-auth` | 验证新账号后关闭 SSH 密码登录 |
| `--keep-root-login` | 保留原有 root 登录配置（默认） |
| `--ssh-port 22` | 仅校验现有端口，不能用于改端口 |
| `-y` | 跳过普通确认；禁止与关闭登录入口的参数组合使用 |
| `--help` | 查看帮助 |

关闭 root 或密码登录需同时提供 `--user` 及自己的公钥。不要把私钥粘贴到命令里。脚本会要求你在第二个终端成功登录并运行 `sudo -n true`，然后输入 `VERIFIED` 才会更改 SSH 登录限制。

## 让 AI 帮你操作

把仓库目录交给 AI 助手，告诉它：

> 阅读 SKILL.md，先检查我的全新 VPS 环境。用默认设置做基础初始化，保留现在的 SSH 登录方式。遇到错误先说明原因。

AI 需要你另外授权连接目标服务器；此仓库不会自己获取账号和密码。

## 项目与反馈

维护：**Jason 数字生活** · [𝕏](https://x.com/EvanWritesX) · [Telegram](https://t.me/EvanCreates)

[提交问题](https://github.com/jasonbitsmith/vps-first-steps/issues)：请附系统版本、运行参数（去掉敏感值）及错误信息。不要上传密码、私钥、Token 或完整服务器日志。

使用 [MIT 许可证](LICENSE)。
