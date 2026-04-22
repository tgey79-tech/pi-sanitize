# pi-sanitize

A single-file Bash script that strips developer identity, GitHub credentials,
editor caches and accumulated runtime state from a Raspberry Pi **before you
hand the SD-card image to a third party**.

Useful when you develop on a Pi (with VS Code Remote, Copilot, your personal
GitHub account) and want to ship the resulting image without leaking who you
are or which repository it came from.

## What it cleans up

| # | Area | What is removed / reset |
|---|------|-------------------------|
| 1 | Project git repo | `.git` directory replaced by a fresh local-only repo (no history, no GitHub remote, no author email) |
| 2 | VS Code Server | `~/.vscode-server`, `~/.vscode-cli`, Copilot + Pull-Request extension caches |
| 3 | Web `.git` leftovers | `/var/www/html/.git` and any `/var/www/html_backup_*/.git` |
| 4 | Shell history | `bash`, `python`, `zsh`, `less` history for `pi` and `root` |
| 5 | SSH host keys | Deleted, regenerated on next boot (avoids identical keys across all distributed cards) |
| 6 | System logs | `journalctl --vacuum`, `/var/log/*.log*`, rotated logs |
| 7 | Caches | APT archives, pip cache, npm cache, `/tmp`, `/var/tmp` |
| 8 | *(optional)* free space | Zero-fill so the resulting `.img` compresses smaller |

## Usage

### Quick install (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/tgey79-tech/pi-sanitize/main/pi-sanitize.sh -o pi-sanitize.sh
chmod +x pi-sanitize.sh
sudo ./pi-sanitize.sh --dry-run            # preview first
```

### Run

```bash
sudo bash pi-sanitize.sh --dry-run            # preview only
sudo bash pi-sanitize.sh                      # interactive, asks per step
sudo bash pi-sanitize.sh --yes                # unattended

# For a project that does NOT live in /home/pi:
sudo bash pi-sanitize.sh /home/pi/my-other-project --yes
PROJECT_DIR=/srv/app sudo -E bash pi-sanitize.sh --yes
```

### Options

| Flag | Purpose |
|------|---------|
| `--yes`, `-y` | Skip every confirmation |
| `--dry-run` | Print what would happen, change nothing |
| `--keep-git` | Do not touch the project's `.git` history |
| `--zero-free-space` | Fill free space with zeros (skip if you use `pishrink`) |
| `-h`, `--help` | Show inline help |

### Environment variables

| Var | Default | Meaning |
|-----|---------|---------|
| `PROJECT_DIR` | `/home/pi` | Repo to reset |
| `NEUTRAL_NAME` | `Raspberry Pi` | Author name written into the fresh repo |
| `NEUTRAL_EMAIL` | `pi@localhost` | Author email written into the fresh repo |

## Recommended image-handover workflow

```bash
# On the Pi
sudo bash pi-sanitize.sh --yes
sudo shutdown -h now

# On a host machine
sudo dd if=/dev/sdX of=project.img bs=4M status=progress
sudo pishrink.sh project.img      # optional, shrinks the partition
xz -T0 -9e project.img            # optional, compresses for distribution
```

If you do **not** use `pishrink`, add `--zero-free-space` to the script call so
that the resulting `.img` is at least more compressible.

## Verification after running

```bash
git -C /home/pi log            # expect: only the new "initial" commit
git -C /home/pi remote -v      # expect: empty
grep -rln 'your.name@email' /home /etc /var/www 2>/dev/null   # expect: empty
```

## What is NOT touched

- WiFi credentials in `/etc/wpa_supplicant/` — keep them if the user should
  connect automatically, otherwise wipe them manually.
- The `pi` user password — change it manually if you want a fresh default.
- Application config files containing API keys / tokens — only you know where
  these live; review the project before imaging.

## License

MIT — do whatever you want, no warranty. See [LICENSE](LICENSE).
