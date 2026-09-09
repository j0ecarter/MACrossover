#!/usr/bin/env bash
# ---------------------------------------------------------------
# install_to_mt4.sh - symlink this repo's Expert Advisor into the
# MetaTrader 4 data folder.
#
# A symlink rather than a copy, so the file MetaEditor compiles and
# the file git tracks are the same file. Edit in VS Code, compile in
# MetaEditor, commit in Terminal - no copying, no version drift.
#
# Usage:
#   ./tools/install_to_mt4.sh                 # auto-detect the data folder
#   ./tools/install_to_mt4.sh /path/to/MQL4   # or point it at one explicitly
#
# Written for the bash 3.2 that ships with macOS, so no arrays and no
# mapfile - both behave badly there under `set -u`.
# ---------------------------------------------------------------
set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_FILE="$REPO_DIR/Experts/MACrossover.mq4"

if [ ! -f "$SOURCE_FILE" ]; then
  echo "ERROR: cannot find $SOURCE_FILE" >&2
  exit 1
fi

# --- Work out which MQL4 folder to install into -----------------
MQL4_DIR="${1:-}"

if [ -z "$MQL4_DIR" ]; then
  # The MetaQuotes macOS build is Wine-wrapped, so the terminal's data
  # folder sits deep inside a Wine prefix under ~/Library. Search for
  # the Experts folder and work back up one level.
  # Search the known Wine-prefix locations rather than scanning the
  # whole of ~/Library, which takes minutes on a machine with caches.
  shopt -s nullglob nocaseglob
  FOUND=""
  for prefix in "$HOME/Library/Application Support"/*metatrader* \
                "$HOME/Library/Application Support"/*metaquotes* \
                "$HOME/Library/Containers"/*metatrader*; do
    [ -d "$prefix" ] || continue
    HITS="$(find "$prefix" -maxdepth 10 -type d -path '*/MQL4/Experts' 2>/dev/null || true)"
    [ -n "$HITS" ] && FOUND="$FOUND
$HITS"
  done
  FOUND="$(printf '%s\n' "$FOUND" | grep . || true)"
  COUNT="$(printf '%s\n' "$FOUND" | grep -c . || true)"

  if [ "$COUNT" -eq 0 ]; then
    echo "ERROR: no MQL4 data folder found under ~/Library." >&2
    echo "Open MetaTrader 4 at least once so it creates its data folder," >&2
    echo "then re-run this script. Or run ./tools/find_mt4.sh to see what" >&2
    echo "is actually on disk and pass the path in as an argument." >&2
    exit 1
  fi

  if [ "$COUNT" -gt 1 ]; then
    echo "Several MT4 installations found. Re-run with the one you want:"
    printf '%s\n' "$FOUND" | while IFS= read -r experts_dir; do
      [ -n "$experts_dir" ] && echo "  $(dirname "$experts_dir")"
    done
    exit 1
  fi

  MQL4_DIR="$(dirname "$FOUND")"
fi

TARGET_DIR="$MQL4_DIR/Experts"
TARGET_LINK="$TARGET_DIR/MACrossover.mq4"

if [ ! -d "$TARGET_DIR" ]; then
  echo "ERROR: $TARGET_DIR does not exist." >&2
  exit 1
fi

echo "Repo:     $REPO_DIR"
echo "MT4 data: $MQL4_DIR"

# --- Preserve anything already sitting at the target -------------
if [ -e "$TARGET_LINK" ] && [ ! -L "$TARGET_LINK" ]; then
  BACKUP="$TARGET_LINK.backup.$(date +%Y%m%d%H%M%S)"
  mv "$TARGET_LINK" "$BACKUP"
  echo "Existing file backed up to: $BACKUP"
fi

ln -sfn "$SOURCE_FILE" "$TARGET_LINK"

# --- Verify -----------------------------------------------------
if [ -L "$TARGET_LINK" ] && [ -f "$TARGET_LINK" ]; then
  echo "Linked:   $TARGET_LINK"
  echo "       -> $(readlink "$TARGET_LINK")"
  echo
  echo "Next: open MetaEditor, open MACrossover.mq4, press F7 to compile."
else
  echo "ERROR: the symlink was not created correctly." >&2
  exit 1
fi
