#!/usr/bin/env bash
# Pull the latest probe code onto the Pi and restart the service.
#
# Run as your login user (NOT with sudo): the GitHub token comes from your
# own `gh` session, while the repo and the service belong to root.
#
#   ./update.sh
#
# Background: /opt/probe was rebuilt with `git init` after SD card
# corruption (see hardware/pi-setup.md), and root has no GitHub
# credentials, so a plain `sudo git pull` prompts for a password that
# cannot work: GitHub dropped password auth for git in 2021.
set -euo pipefail

REPO_DIR=/opt/probe
REMOTE=github.com/Selimgul14/network-quality-analysis.git

command -v gh >/dev/null || { echo "gh not installed; see pi-setup.md"; exit 1; }
TOKEN=$(gh auth token) || { echo "gh not authenticated: run 'gh auth login'"; exit 1; }

echo "fetching..."
# Note: the token is on the command line, so it is briefly visible in `ps`
# on a shared machine. Fine for a single-user probe.
sudo git -C "$REPO_DIR" fetch "https://x-access-token:${TOKEN}@${REMOTE}" main
sudo git -C "$REPO_DIR" reset --hard FETCH_HEAD
sudo git -C "$REPO_DIR" update-ref refs/remotes/origin/main FETCH_HEAD

# Stale bytecode survives a checkout when the clock is off, and the Pi has
# no real-time clock.
sudo find "$REPO_DIR" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

echo "at $(sudo git -C "$REPO_DIR" log --oneline -1)"
sudo systemctl restart probe
sleep 8
systemctl --no-pager --lines=0 status probe | head -4
echo
echo "watch it run:  journalctl -u probe -f"
