#!/usr/bin/env bash
set -euo pipefail

# ─── Check for Claude Code update ───
check_update() {
  local current latest check
  current=$(claude --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+') || return

  check=$(curl -fsSL --max-time 5 https://claude.ai/install.sh 2>/dev/null | bash -s -- --check 2>&1) || true

  if [[ -z "$check" ]]; then
    echo "Claude Code: v${current}"
    return
  fi

  if echo "$check" | grep -qi "up to date"; then
    echo "Claude Code: v${current} (up to date)"
    return
  fi

  latest=$(echo "$check" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1) || true

  if [[ -n "$latest" ]] && [[ "$current" != "$latest" ]]; then
    echo "Claude Code: v${current} -> v${latest} available"
  else
    echo "Claude Code: v${current} (update available)"
  fi

  read -rp "Update? [y/N]: " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    echo "Updating Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
    cp -a /root/.local/bin/. /usr/local/bin/
    echo "Updated to $(claude --version 2>/dev/null | head -1)"
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
    if command -v pty-proxy &>/dev/null && [ -n "${CCDOCKER_CLIP_PORT:-}" ]; then
      pty-proxy claude
    else
      claude
    fi
    echo "Claude exited. Stopping container."
    ;;
esac
