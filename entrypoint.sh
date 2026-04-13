#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  login)
    echo "Login to Claude (open the URL shown below in your browser):"
    echo ""
    BROWSER=echo claude login
    echo ""
    echo "Login complete. Credentials saved to profile."
    ;;
  *)
    echo "Claude Code: v$(claude --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
    echo "Starting Claude Code..."
    if command -v pty-proxy &>/dev/null && [ -n "${CCDOCKER_CLIP_PORT:-}" ]; then
      pty-proxy claude
    else
      claude
    fi
    echo "Claude exited. Stopping container."
    ;;
esac
