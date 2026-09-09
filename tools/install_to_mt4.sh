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
# ---------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$REPO_DIR/Experts/MaCrossoverBot.mq4"

if [ ! -f "$SOURCE_FILE" ]; then
  echo "ERROR: cannot find $SOURCE_FILE" >&2
  exit 1
fi

# --- Work out which MQL4 folder to install into -----------------
MQL4_DIR="${1:-}"

if [ -z "$MQL4_DIR" ]; then
  # Collect every MQL4/Experts folder under ~/Library. macOS ships
  # bash 3.2, which has no `mapfile`, hence the while-read loop.
  CANDIDATES=()
  while IFS= read -r found; do
    CANDIDATES+=("$(dirname "$found")")
  done < <(find "$HOME/Library" -maxdepth 14 -type d -path "*/MQL4/Experts" 2>/dev/null)

  case "${#CANDIDATES[@]}" in
    0)
      echo "ERROR: no MQL4 data folder found." >&2
      echo "Open MT4 at least once so it creates its data folder, then re-run." >&2
      echo "Or run ./tools/find_mt4.sh to see what is actually on disk." >&2
      exit 1
      ;;
    1)
      MQL4_DIR="${CANDIDATES[0]}"
      ;;
    *)
      echo "Several MT4 installations found. Re-run with the one you want:"
      for candidate in "${CANDIDATES[@]}"; do echo "  $candidate"; done
      exit 1
      ;;
  esac
fi

TARGET_DIR="$MQL4_DIR/Experts"
TARGET_LINK="$TARGET_DIR/MaCrossoverBot.mq4"

echo "Repo:        $REPO_DIR"
echo "MT4 data:    $MQL4_DIR"

# --- Preserve anything already sitting at the target -------------
if [ -e "$TARGET_LINK" ] && [ ! -L "$TARGET_LINK" ]; then
  BACKUP="$TARGET_LINK.backup.$(date +%Y%m%d%H%M%S)"
  mv "$TARGET_LINK" "$BACKUP"
  echo "Existing file backed up to: $BACKUP"
fi

ln -sfn "$SOURCE_FILE" "$TARGET_LINK"

# --- Verify -----------------------------------------------------
if [ -L "$TARGET_LINK" ] && [ -f "$TARGET_LINK" ]; then
  echo "Linked:      $TARGET_LINK"
  echo "          -> $(readlink "$TARGET_LINK")"
  echo
  echo "Next: open MetaEditor, open MaCrossoverBot.mq4, press F7 to compile."
else
  echo "ERROR: the symlink was not created correctly." >&2
  exit 1
fi
