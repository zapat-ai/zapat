# Linux Setup Guide

This guide covers Linux-specific setup for Zapat. If you're on macOS, the standard [setup wizard](/zapat) handles everything.

## Prerequisites

### Install system packages

**Debian/Ubuntu:**
```bash
sudo apt-get update
sudo apt-get install -y tmux jq git curl
```

**Fedora/RHEL:**
```bash
sudo dnf install -y tmux jq git curl
```

**Arch:**
```bash
sudo pacman -S tmux jq git curl
```

### Install Node.js 18+

The version in your distro's default repos may be too old. Use NodeSource:

```bash
# Ubuntu/Debian
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
```

Or use `nvm`:
```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc
nvm install 20
```

Verify: `node --version` should be 18.0.0 or higher.

### Install GitHub CLI

```bash
# Ubuntu/Debian
(type -p wget >/dev/null || sudo apt install wget -y) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli-stable.list > /dev/null \
  && sudo apt update \
  && sudo apt install gh -y
```

Then authenticate: `gh auth login`

### Install Claude Code CLI

```bash
npm install -g @anthropic-ai/claude-code
```

Verify: `claude --version`

## Linux-Specific Differences

### `timeout` vs `gtimeout`

Zapat uses `timeout` for enforcing session time limits. On macOS, this requires `brew install coreutils` and uses `gtimeout`. On Linux, `timeout` is available by default from GNU coreutils.

The scripts auto-detect which is available. No action needed.

### No Keychain

On macOS, the `ANTHROPIC_API_KEY` can be stored in Keychain. On Linux, store it as an environment variable:

```bash
# Add to ~/.bashrc or ~/.zshrc
export ANTHROPIC_API_KEY="sk-ant-xxxxx"
```

Or add it to the Zapat `.env` file:
```bash
ANTHROPIC_API_KEY=sk-ant-xxxxx
```

### File paths

Zapat uses `$HOME` for all user-relative paths. Default locations on Linux:

| Path | Purpose |
|------|---------|
| `~/.claude/agents/` | Agent persona files |
| `~/.claude/agent-memory/_shared/` | Shared agent memory |
| `/tmp/agent-worktrees/` | Isolated git worktrees for implementations |

## Running as a systemd Service

Instead of (or in addition to) cron, you can run the poller as a systemd service for better process management, automatic restarts, and log integration.

### Create the service file

```bash
sudo tee /etc/systemd/system/zapat-poller.service > /dev/null <<'EOF'
[Unit]
Description=Zapat Pipeline Poller
After=network.target

[Service]
Type=simple
User=YOUR_USERNAME
WorkingDirectory=/home/YOUR_USERNAME/zapat
ExecStart=/bin/bash -c 'while true; do ./bin/poll-github.sh >> logs/cron-poll.log 2>&1; sleep 120; done'
Restart=always
RestartSec=60
Environment=HOME=/home/YOUR_USERNAME
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/home/YOUR_USERNAME/.nvm/versions/node/v20.0.0/bin

[Install]
WantedBy=multi-user.target
EOF
```

Replace `YOUR_USERNAME` with your Linux user, and update the Node.js path if using nvm.

### Enable and start

```bash
sudo systemctl daemon-reload
sudo systemctl enable zapat-poller
sudo systemctl start zapat-poller
```

### Check status

```bash
sudo systemctl status zapat-poller
journalctl -u zapat-poller -f    # Follow logs
```

### Create a service for the dashboard

```bash
sudo tee /etc/systemd/system/zapat-dashboard.service > /dev/null <<'EOF'
[Unit]
Description=Zapat Dashboard
After=network.target

[Service]
Type=simple
User=YOUR_USERNAME
WorkingDirectory=/home/YOUR_USERNAME/zapat/dashboard
ExecStart=/usr/bin/npx next start -H 0.0.0.0 -p 8080
Restart=always
RestartSec=10
Environment=HOME=/home/YOUR_USERNAME
Environment=AUTOMATION_DIR=/home/YOUR_USERNAME/zapat
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/home/YOUR_USERNAME/.nvm/versions/node/v20.0.0/bin

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable zapat-dashboard
sudo systemctl start zapat-dashboard
```

## Using cron (alternative to systemd)

If you prefer cron, `bin/startup.sh` handles this automatically. It installs:

```cron
*/2 * * * * cd /home/you/zapat && ./bin/poll-github.sh >> logs/cron-poll.log 2>&1
```

Check that cron is running: `systemctl status cron` (or `crond` on RHEL/Fedora).

## tmux on headless servers

On a headless server (no display), tmux works without any special configuration. If you connect via SSH:

```bash
# Attach to the Zapat tmux session
tmux attach -t zapat

# Detach without stopping: press Ctrl+B, then D
```

If your SSH connection drops, the tmux session (and all running agents) continue in the background.

## Firewall configuration

If you want to access the dashboard from other machines, open the dashboard port:

```bash
# UFW (Ubuntu)
sudo ufw allow 8080/tcp

# firewalld (RHEL/Fedora)
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --reload
```

## Cloud VM recommendations

Zapat runs well on modest hardware. Recommended specs:

| Spec | Minimum | Recommended |
|------|---------|-------------|
| CPU | 2 cores | 4 cores |
| RAM | 4 GB | 8 GB |
| Disk | 20 GB | 50 GB |
| OS | Ubuntu 22.04+ | Ubuntu 24.04 LTS |

The main resource consumers are git operations (cloning/worktrees) and the Node.js processes. Claude Code API calls are network-bound, not CPU-bound.
