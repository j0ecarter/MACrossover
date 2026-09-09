#!/usr/bin/env bash
# ---------------------------------------------------------------
# find_mt4.sh - locate the MetaTrader 4 installation on macOS.
#
# The MetaQuotes macOS build is a Wine wrapper, so the terminal's
# data folder (the one holding MQL4/Experts) is buried inside a Wine
# prefix rather than sitting next to the .app. This script finds it
# and prints everything the other scripts need.
#
# Safe to run: it only reads.
# ---------------------------------------------------------------
set -u

echo "== Application bundle =="
ls -d /Applications/MetaTrader*.app 2>/dev/null || echo "  none found in /Applications"

echo
echo "== Wine prefixes =="
find "$HOME/Library/Application Support" -maxdepth 1 -iname "*metatrader*" 2>/dev/null
find "$HOME/Library/Containers"          -maxdepth 1 -iname "*metatrader*" 2>/dev/null

echo
echo "== MQL4/Experts directories (this is what you want) =="
find "$HOME/Library" -maxdepth 14 -type d -path "*/MQL4/Experts" 2>/dev/null

echo
echo "== metaeditor.exe (the compiler) =="
find "$HOME/Library" -maxdepth 14 -type f -iname "metaeditor*.exe" 2>/dev/null
find /Applications/MetaTrader*.app -maxdepth 8 -type f -iname "metaeditor*.exe" 2>/dev/null

echo
echo "== bundled wine binary =="
find /Applications/MetaTrader*.app -maxdepth 8 -type f -name "wine" 2>/dev/null
