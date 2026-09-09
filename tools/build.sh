#!/usr/bin/env bash
# ---------------------------------------------------------------
# build.sh - compile the EA headlessly via the Wine-hosted
# MetaEditor, so you can build without leaving Terminal.
#
# MetaEditor supports:  metaeditor.exe /compile:"<file>" /log
# ---------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WINE_BIN="$(find /Applications/MetaTrader*.app -maxdepth 8 -type f -name wine 2>/dev/null | head -n 1)"
EDITOR_EXE="$(find "$HOME/Library" -maxdepth 14 -type f -iname 'metaeditor*.exe' 2>/dev/null | head -n 1)"

if [ -z "$WINE_BIN" ] || [ -z "$EDITOR_EXE" ]; then
  echo "Could not locate wine and/or metaeditor.exe." >&2
  echo "Run ./tools/find_mt4.sh to see what is present, then edit this script." >&2
  exit 1
fi

# MetaEditor needs a Windows-style path. The EA is symlinked into the
# terminal's Experts folder, so compile it by its MQL4-relative name.
"$WINE_BIN" "$EDITOR_EXE" /compile:"MQL4\\Experts\\MaCrossoverBot.mq4" /log

echo "Compile finished. Check the .ex4 timestamp in the Experts folder."
