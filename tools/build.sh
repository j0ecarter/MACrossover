#!/usr/bin/env bash
# ---------------------------------------------------------------
# build.sh - compile the EA headlessly via the Wine-hosted
# MetaEditor, so you can build without leaving Terminal.
#
# MetaEditor supports:  metaeditor.exe /compile:"<file>" /log
#
# The MetaQuotes macOS build is a CrossOver bottle (note the
# drive_c/users/crossover path), so the wine binary is not simply
# called "wine" and is not always inside the .app. If this script
# cannot find one, compile with F7 in MetaEditor instead - that
# always works, this is only a convenience.
# ---------------------------------------------------------------
set -eu
shopt -s nullglob nocaseglob

PREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader4"
EDITOR_EXE="$PREFIX/drive_c/Program Files (x86)/MetaTrader 4/metaeditor.exe"

if [ ! -f "$EDITOR_EXE" ]; then
  echo "metaeditor.exe not found at the expected path:" >&2
  echo "  $EDITOR_EXE" >&2
  echo "Run ./tools/find_mt4.sh to locate it." >&2
  exit 1
fi

# Look for a wine launcher in the usual CrossOver and MetaQuotes spots.
WINE_BIN=""
for candidate in \
  /Applications/MetaTrader*.app/Contents/SharedSupport/*/bin/wine* \
  /Applications/MetaTrader*.app/Contents/SharedSupport/bin/wine* \
  /Applications/MetaTrader*.app/Contents/MacOS/wine* \
  /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine* \
  "$(command -v wine 2>/dev/null || true)"; do
  if [ -n "$candidate" ] && [ -x "$candidate" ] && [ -f "$candidate" ]; then
    WINE_BIN="$candidate"
    break
  fi
done

if [ -z "$WINE_BIN" ]; then
  echo "No wine launcher found - headless compiling is not available here." >&2
  echo "Compile with F7 in MetaEditor instead." >&2
  exit 1
fi

echo "wine:       $WINE_BIN"
echo "metaeditor: $EDITOR_EXE"
echo

"$WINE_BIN" "$EDITOR_EXE" /compile:"MQL4\\Experts\\MACrossover.mq4" /log

echo "Compile finished. Check the .ex4 timestamp in the Experts folder."
