#!/usr/bin/env bash
# ccdocker clipboard shim — drop-in replacement for xclip / xsel / wl-paste / pbpaste.
# Communicates with the host clipboard daemon via HTTP (host.docker.internal).
set -euo pipefail

URL="http://host.docker.internal:${CCDOCKER_CLIP_PORT:-19283}"
AUTH="Authorization: Bearer ${CCDOCKER_CLIP_TOKEN:-}"

# Detect how we were invoked (symlink name) to adjust argument parsing.
prog=$(basename "$0")

output=false
target=""
list_types=false

case "$prog" in
  pbpaste|pngpaste)
    output=true
    [[ "$prog" == "pngpaste" ]] && target="image/png"
    ;;
  wl-paste)
    output=true
    ;;
esac

# Parse xclip / xsel / wl-paste compatible flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|-out|--output)       output=true;  shift ;;
    -i|-in|--input)         output=false; shift ;;
    -t)                     target="$2";  shift 2 ;;
    -target)                target="$2";  shift 2 ;;
    -l|--list-types)        list_types=true; shift ;;  # wl-paste -l
    -selection|-sel)        shift 2 ;;
    --clipboard|--primary)  shift ;;
    --)                     shift; break ;;
    *)                      shift ;;
  esac
done

# wl-paste -l  →  list available MIME types
if $list_types; then
  exec curl -sfS -H "$AUTH" "$URL/targets" 2>/dev/null
fi

if $output; then
  # xclip -t TARGETS -o  →  list available MIME types
  if [[ "$target" == "TARGETS" ]]; then
    exec curl -sfS -H "$AUTH" "$URL/targets" 2>/dev/null
  elif [[ "$target" == image/* ]]; then
    exec curl -sfS -H "$AUTH" "$URL/image" 2>/dev/null
  else
    exec curl -sfS -H "$AUTH" "$URL/text" 2>/dev/null
  fi
else
  exec curl -sfS -X POST -H "$AUTH" --data-binary @- "$URL/copy" 2>/dev/null
fi
