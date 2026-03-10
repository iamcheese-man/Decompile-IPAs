#!/bin/bash
set -e

IPA=$1
WORKDIR=work

echo "[+] Cleaning workspace"
rm -rf "$WORKDIR"
mkdir "$WORKDIR"

echo "[+] Extracting IPA"
unzip -q "$IPA" -d "$WORKDIR"

echo "[+] Finding .app folder"
APP=$(find "$WORKDIR/Payload" -name "*.app" -type d | head -n 1)
if [ -z "$APP" ]; then
    echo "[-] No .app found!"
    exit 1
fi

echo "[+] Finding main binary"
BIN_NAME=$(basename "$APP")
BIN_PATH="$APP/$BIN_NAME"

if [ ! -f "$BIN_PATH" ]; then
    echo "[-] Binary not found!"
    exit 1
fi

cp "$BIN_PATH" "$WORKDIR/binary"

echo "[+] Extracting strings"
strings "$WORKDIR/binary" > "$WORKDIR/strings.txt"

echo "[+] Extracting symbols"
nm "$WORKDIR/binary" > "$WORKDIR/symbols.txt" || echo "[!] Some symbols may be stripped"

echo "[+] Extracting Info.plist"
plutil -convert xml1 "$APP/Info.plist" -o "$WORKDIR/Info.plist"

echo "[+] Extracting URL schemes (if any)"
PLIST_URLS=$(defaults read "$APP/Info.plist" CFBundleURLTypes 2>/dev/null || echo "none")
echo "$PLIST_URLS" > "$WORKDIR/url_schemes.txt"

echo "[+] Listing frameworks"
ls "$APP/Frameworks" > "$WORKDIR/frameworks.txt" 2>/dev/null || echo "No frameworks"

echo "[+] Done. Workspace: $WORKDIR"
