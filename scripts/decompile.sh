#!/bin/bash
set -e

IPA=$1
WORKDIR="work"

echo "[+] Cleaning workspace"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

echo "[+] Extracting IPA"
unzip -q "$IPA" -d "$WORKDIR"

echo "[+] Locating .app bundle"
APP=$(find "$WORKDIR/Payload" -name "*.app" -type d | head -n 1)

if [ -z "$APP" ]; then
    echo "[-] No .app bundle found"
    exit 1
fi

echo "[+] Found app: $APP"

echo "[+] Reading Info.plist"
INFO_PLIST="$APP/Info.plist"

if [ ! -f "$INFO_PLIST" ]; then
    echo "[-] Info.plist not found"
    exit 1
fi

cp "$INFO_PLIST" "$WORKDIR/Info.plist"

echo "[+] Detecting executable from Info.plist"
EXEC=$(grep -A1 CFBundleExecutable "$INFO_PLIST" | tail -n1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')

BIN_PATH=""

if [ ! -z "$EXEC" ] && [ -f "$APP/$EXEC" ]; then
    BIN_PATH="$APP/$EXEC"
fi

if [ -z "$BIN_PATH" ]; then
    echo "[!] Executable not found via Info.plist, scanning for Mach-O"

    BIN_PATH=$(find "$APP" -type f -exec file {} \; | grep "Mach-O" | cut -d: -f1 | head -n 1)
fi

if [ -z "$BIN_PATH" ]; then
    echo "[-] No Mach-O executable found"
    exit 1
fi

echo "[+] Found executable: $BIN_PATH"

cp "$BIN_PATH" "$WORKDIR/binary"

echo "[+] Extracting strings"
strings "$WORKDIR/binary" > "$WORKDIR/strings.txt" || true

echo "[+] Extracting symbols"
nm "$WORKDIR/binary" > "$WORKDIR/symbols.txt" 2>/dev/null || echo "[!] Symbols stripped"

echo "[+] Extracting bundle identifier"
grep -A1 CFBundleIdentifier "$INFO_PLIST" | tail -n1 > "$WORKDIR/bundle_id.txt" || true

echo "[+] Extracting URL schemes"
grep -A3 CFBundleURLSchemes "$INFO_PLIST" > "$WORKDIR/url_schemes.txt" || echo "None" > "$WORKDIR/url_schemes.txt"

echo "[+] Listing frameworks"
if [ -d "$APP/Frameworks" ]; then
    ls "$APP/Frameworks" > "$WORKDIR/frameworks.txt"
else
    echo "No frameworks" > "$WORKDIR/frameworks.txt"
fi

echo "[+] Listing embedded plugins"
if [ -d "$APP/PlugIns" ]; then
    ls "$APP/PlugIns" > "$WORKDIR/plugins.txt"
else
    echo "No plugins" > "$WORKDIR/plugins.txt"
fi

echo "[+] Listing app bundle files"
ls "$APP" > "$WORKDIR/app_contents.txt"

echo "[+] Copying entire Payload for inspection"
cp -r "$WORKDIR/Payload" "$WORKDIR/payload_dump"

echo "[+] Done. Results in: $WORKDIR"
