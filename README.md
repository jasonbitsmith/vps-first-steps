# vps-init

A single, readable bash script that takes a fresh Ubuntu/Debian VPS from
default install to a reasonably hardened, ready-to-use server — in one run.

No config management framework, no dependencies beyond `apt`. Read it before
you run it; that's the point.

## What it does

1. **Updates** the system (`apt update && apt upgrade`)
2. **Installs** basic tools (`curl`, `git`, `vim`, `htop`, `ufw`, `fail2ban`, `unattended-upgrades`)
3. **Sets the timezone** (optional)
4. **Creates a sudo user** and installs your SSH public key for it
5. **Hardens SSH** — custom port, disables root login, optionally disables password auth
6. **Enables the UFW firewall** — deny incoming by default, allow only your SSH port
7. **Configures fail2ban** for SSH brute-force protection
8. **Sets up a swap file** (skipped if swap already exists)
9. **Enables unattended security updates**

Every step is idempotent — safe to re-run. Each can also be individually
skipped with a flag.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/jasonbitsmith/vps-first-steps/main/vps-init.sh -o vps-init.sh
chmod +x vps-init.sh
sudo ./vps-init.sh --user deploy --ssh-key-url https://github.com/<your-github-username>.keys \
  --timezone Asia/Shanghai --disable-password-auth
```

Or clone the repo and run it locally:

```bash
git clone https://github.com/jasonbitsmith/vps-first-steps.git
cd vps-first-steps
sudo ./vps-init.sh --help
```

## ⚠️ Before you disconnect

If you disable password auth or root login, **open a second terminal and
verify you can log in with the new user/key/port before closing your
current session.** Getting locked out of a VPS with no console access is a
real and common mistake — the script prints a reminder at the end, but it's
on you to actually test it.

```bash
ssh -p <port> <user>@<server-ip>
```

## Options

| Flag | Description | Default |
|---|---|---|
| `--user NAME` | Create a sudo user | *(none — skips user creation)* |
| `--ssh-key "KEY"` | Public key string to authorize | |
| `--ssh-key-url URL` | Fetch key from a URL (e.g. `https://github.com/<user>.keys`) | |
| `--ssh-port PORT` | SSH port | `22` |
| `--timezone TZ` | e.g. `Asia/Shanghai`, `UTC` | *(unchanged)* |
| `--swap SIZE` | Swap file size, e.g. `2G`, `512M` | `2G` |
| `--no-swap` | Skip swap setup | |
| `--disable-password-auth` | Key-only SSH login (requires `--ssh-key`/`--ssh-key-url`) | password auth stays on |
| `--keep-root-login` | Don't disable SSH root login | root login is disabled |
| `--no-firewall` | Skip UFW setup | |
| `--no-fail2ban` | Skip fail2ban | |
| `--no-auto-updates` | Skip unattended-upgrades | |
| `--no-basic-tools` | Skip installing curl/git/vim/htop/etc. | |
| `-y`, `--yes` | Non-interactive, skip confirmation prompt | |

Run `sudo ./vps-init.sh --help` for the same list from the terminal.

## Supported systems

Ubuntu and Debian (anything with `apt` and `systemd`). Tested against
current Ubuntu LTS releases. Not intended for CentOS/RHEL/Alpine — PRs
welcome to add support behind OS detection, but keep the script readable.

## Design principles

- **One file.** You should be able to read the whole thing in under five
  minutes before running it as root on a machine you care about.
- **Idempotent.** Re-running it should not break anything or duplicate
  config.
- **No lock-yourself-out footguns by default.** Password auth stays enabled
  unless you explicitly pass a key and ask to disable it.
- **Everything is a flag.** No step is mandatory except the system update.

## License

[MIT](LICENSE)
