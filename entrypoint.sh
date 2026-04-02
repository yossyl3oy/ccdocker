#!/usr/bin/env bash
set -euo pipefail

# ─── Check for Claude Code update ───
check_update() {
  local current latest
  current=$(claude --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+') || return
  latest=$(curl -fsSL --max-time 5 https://claude.ai/install.sh 2>/dev/null \
    | grep -oE 'latest|[0-9]+\.[0-9]+\.[0-9]+' | tail -1) || return

  # If can't determine latest, try installing and check
  if [[ "$latest" == "latest" ]] || [[ -z "$latest" ]]; then
    echo "Claude Code: v${current} (checking for updates...)"
    local check
    check=$(curl -fsSL https://claude.ai/install.sh 2>/dev/null | bash -s -- --check 2>&1) || true
    if echo "$check" | grep -qi "up to date"; then
      echo "Claude Code: v${current} (up to date)"
      return
    fi
  fi

  if [[ -n "$latest" ]] && [[ "$latest" != "latest" ]] && [[ "$current" != "$latest" ]]; then
    echo "Claude Code: v${current} -> v${latest} available"
    read -rp "Update? [y/N]: " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      echo "Updating Claude Code..."
      curl -fsSL https://claude.ai/install.sh | bash
      cp -a /root/.local/bin/. /usr/local/bin/
      echo "Updated to $(claude --version 2>/dev/null | head -1)"
    fi
  else
    echo "Claude Code: v${current} (up to date)"
  fi
}

case "${1:-}" in
  login)
    echo "Login to Claude (open the URL shown below in your browser):"
    echo ""
    BROWSER=echo claude login
    echo ""
    echo "Login complete. Credentials saved to profile."
    ;;
  *)
    check_update
    echo "Starting Claude Code..."
    claude
    echo "Claude exited. Stopping container."
    ;;
esac
