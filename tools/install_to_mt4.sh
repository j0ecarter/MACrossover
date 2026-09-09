#!/usr/bin/env bash
# ---------------------------------------------------------------
# install_to_mt4.sh - symlink this repo's MQL4 sources into the
# MetaTrader 4 data folder.
#
#   Experts/MACrossover.mq4    -> MQL4/Experts/
#   Indicators/CandleTimer.mq4 -> MQL4/Indicators/
#
# Symlinks rather than copies, so the files MetaEditor compiles and
# the files git tracks are the same files. Edit in VS Code, compile
# in MetaEditor, commit in Terminal - one source of truth.
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

# --- Work out which MQL4 folder to install into -----------------
MQL4_DIR="${1:-}"

if [ -z "$MQL4_DIR" ]; then
  # Search the known Wine-prefix locations rather than scanning the
  # whole of ~/Library, which walks every browser cache on the machine
  # and takes minutes.
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
    echo "ERROR: no MQL4 data folder found." >&2
    echo "Open MetaTrader 4 at least once so it creates its data folder," >&2
    echo "then re-run. Or run ./tools/find_mt4.sh and pass the path in." >&2
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

echo "Repo:     $REPO_DIR"
echo "MT4 data: $MQL4_DIR"
echo

# ---------------------------------------------------------------
# link_source <repo-subfolder> <mql4-subfolder> <filename>
#
# Backs up any real file already at the target, then links ours in.
# A target that is already a symlink is simply replaced - it will be
# one of ours from a previous run.
# ---------------------------------------------------------------
link_source()
{
  repo_subfolder="$1"
  mql4_subfolder="$2"
  filename="$3"

  source_file="$REPO_DIR/$repo_subfolder/$filename"
  target_dir="$MQL4_DIR/$mql4_subfolder"
  target_link="$target_dir/$filename"

  if [ ! -f "$source_file" ]; then
    echo "  SKIP $filename - not present in the repo at $repo_subfolder/"
    return 0
  fi

  if [ ! -d "$target_dir" ]; then
    echo "  SKIP $filename - $target_dir does not exist"
    return 0
  fi

  if [ -e "$target_link" ] && [ ! -L "$target_link" ]; then
    backup="$target_link.backup.$(date +%Y%m%d%H%M%S)"
    mv "$target_link" "$backup"
    echo "  Backed up the existing file to $(basename "$backup")"
  fi

  ln -sfn "$source_file" "$target_link"

  if [ -L "$target_link" ] && [ -f "$target_link" ]; then
    echo "  OK   $mql4_subfolder/$filename -> $repo_subfolder/$filename"
  else
    echo "  FAIL $filename - the symlink was not created correctly" >&2
    return 1
  fi
}

link_source "Experts"    "Experts"    "MACrossover.mq4"
link_source "Indicators" "Indicators" "CandleTimer.mq4"

echo
echo "Next: in MetaEditor open each file and press F7 to compile."
echo "Then refresh MT4's Navigator panel (right-click - Refresh)."
