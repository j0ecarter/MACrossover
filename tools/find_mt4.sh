#!/usr/bin/env bash
# ---------------------------------------------------------------
# find_mt4.sh - locate the MetaTrader 4 installation on macOS.
#
# The MetaQuotes macOS build is a Wine wrapper, so the terminal's
# data folder (the one holding MQL4/Experts) is buried inside a Wine
# prefix rather than sitting next to the .app.
#
# Searches the known Wine-prefix locations first, because a blind
# scan of ~/Library takes minutes - it has to walk every browser
# cache and Xcode derived-data folder on the machine.
#
# Safe to run: it only reads.
# ---------------------------------------------------------------
set -u
shopt -s nullglob nocaseglob    # unmatched globs vanish; match case-insensitively

echo "== Application bundle =="
ls -d /Applications/MetaTrader*.app 2>/dev/null || echo "  none found in /Applications"

echo
echo "== Wine prefixes =="
PREFIXES=""
for prefix in "$HOME/Library/Application Support"/*metatrader* \
              "$HOME/Library/Application Support"/*metaquotes* \
              "$HOME/Library/Containers"/*metatrader* \
              "$HOME/Library/Containers"/*metaquotes*; do
  [ -d "$prefix" ] || continue
  echo "  $prefix"
  PREFIXES="$PREFIXES
$prefix"
done
[ -n "$PREFIXES" ] || echo "  none found"

echo
echo "== MQL4 data folders (this is what you want) =="
printf '%s\n' "$PREFIXES" | while IFS= read -r prefix; do
  [ -n "$prefix" ] || continue
  find "$prefix" -maxdepth 10 -type d -path '*/MQL4/Experts' 2>/dev/null | \
    while IFS= read -r experts; do dirname "$experts"; done
done

echo
echo "== metaeditor.exe (the compiler) =="
printf '%s\n' "$PREFIXES" | while IFS= read -r prefix; do
  [ -n "$prefix" ] || continue
  find "$prefix" -maxdepth 10 -type f -iname 'metaeditor*.exe' 2>/dev/null
done

echo
echo "== bundled wine binary =="
for bundle in /Applications/MetaTrader*.app; do
  [ -d "$bundle" ] || continue
  find "$bundle" -maxdepth 8 -type f -name wine 2>/dev/null
done

echo
echo "Done."
