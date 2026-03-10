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

# FIX 1: Better plist parsing with plutil/plistutil
echo "[+] Detecting executable from Info.plist"
if command -v plutil &> /dev/null; then
    # Convert to JSON for easier parsing
    plutil -convert json "$INFO_PLIST" -o "$WORKDIR/Info.json"
    EXEC=$(grep -o '"CFBundleExecutable"[[:space:]]*:[[:space:]]*"[^"]*"' "$WORKDIR/Info.json" | sed 's/.*"CFBundleExecutable"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
elif command -v plistutil &> /dev/null; then
    EXEC=$(plistutil -i "$INFO_PLIST" -o - | grep -A1 CFBundleExecutable | tail -n1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
else
    # Fallback to grep (fragile)
    EXEC=$(grep -A1 CFBundleExecutable "$INFO_PLIST" | tail -n1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
fi

BIN_PATH=""

if [ ! -z "$EXEC" ] && [ -f "$APP/$EXEC" ]; then
    BIN_PATH="$APP/$EXEC"
fi

# FIX 2: Faster Mach-O search - only check root level first
if [ -z "$BIN_PATH" ]; then
    echo "[!] Executable not found via Info.plist, scanning root of app bundle"
    
    # Check root level files first (faster)
    for file in "$APP"/*; do
        if [ -f "$file" ] && file "$file" | grep -q "Mach-O"; then
            BIN_PATH="$file"
            break
        fi
    done
    
    # Only do deep search if still not found
    if [ -z "$BIN_PATH" ]; then
        echo "[!] Not in root, doing deep scan (slow)..."
        BIN_PATH=$(find "$APP" -maxdepth 3 -type f -exec sh -c 'file "$1" | grep -q "Mach-O" && echo "$1"' _ {} \; | head -n 1)
    fi
fi

if [ -z "$BIN_PATH" ]; then
    echo "[-] No Mach-O executable found"
    exit 1
fi

echo "[+] Found executable: $BIN_PATH"

cp "$BIN_PATH" "$WORKDIR/binary"

echo "[+] Extracting strings"
strings "$WORKDIR/binary" > "$WORKDIR/strings.txt" || true

# FIX 4: Better symbol extraction with fallback
echo "[+] Extracting symbols"
if nm "$WORKDIR/binary" > "$WORKDIR/symbols.txt" 2>/dev/null; then
    echo "[+] Symbols extracted successfully"
else
    echo "[!] Binary is stripped, trying otool for exports"
    otool -IV "$WORKDIR/binary" > "$WORKDIR/exports.txt" 2>/dev/null || echo "No exports available" > "$WORKDIR/exports.txt"
    echo "Binary is stripped - no symbols available" > "$WORKDIR/symbols.txt"
fi

# FIX 5: Extract Objective-C classes
echo "[+] Extracting Objective-C class information"
if command -v class-dump &> /dev/null; then
    class-dump "$WORKDIR/binary" > "$WORKDIR/objc_classes.txt" 2>/dev/null || {
        echo "[!] class-dump failed, trying otool"
        otool -oV "$WORKDIR/binary" > "$WORKDIR/objc_classes.txt" 2>/dev/null || echo "No Objective-C classes found" > "$WORKDIR/objc_classes.txt"
    }
else
    echo "[!] class-dump not installed, using otool"
    otool -oV "$WORKDIR/binary" > "$WORKDIR/objc_classes.txt" 2>/dev/null || echo "No Objective-C classes found" > "$WORKDIR/objc_classes.txt"
fi

# FIX 6: Dump entitlements
echo "[+] Extracting entitlements"
if command -v codesign &> /dev/null; then
    codesign -d --entitlements :- "$WORKDIR/binary" > "$WORKDIR/entitlements.plist" 2>/dev/null || echo "No entitlements" > "$WORKDIR/entitlements.plist"
    
    # Also get embedded entitlements if they exist
    if [ -f "$APP/archived-expanded-entitlements.xcent" ]; then
        cp "$APP/archived-expanded-entitlements.xcent" "$WORKDIR/embedded-entitlements.xcent"
    fi
else
    echo "[!] codesign not available, checking for embedded entitlements"
    if [ -f "$APP/archived-expanded-entitlements.xcent" ]; then
        cp "$APP/archived-expanded-entitlements.xcent" "$WORKDIR/entitlements.plist"
    else
        echo "No entitlements found" > "$WORKDIR/entitlements.plist"
    fi
fi

echo "[+] Extracting bundle identifier"
if [ -f "$WORKDIR/Info.json" ]; then
    grep -o '"CFBundleIdentifier"[[:space:]]*:[[:space:]]*"[^"]*"' "$WORKDIR/Info.json" | sed 's/.*"\([^"]*\)".*/\1/' > "$WORKDIR/bundle_id.txt" || true
else
    grep -A1 CFBundleIdentifier "$INFO_PLIST" | tail -n1 > "$WORKDIR/bundle_id.txt" || true
fi

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

# ====== .NET DECOMPILATION SECTION ======

echo "[+] Searching for .NET assemblies"
mkdir -p "$WORKDIR/dlls"
find "$APP" -name "*.dll" -type f -exec cp {} "$WORKDIR/dlls/" \;

DLL_COUNT=$(ls "$WORKDIR/dlls" 2>/dev/null | wc -l)

if [ "$DLL_COUNT" -gt 0 ]; then
    echo "[+] Found $DLL_COUNT .NET assemblies"
    ls "$WORKDIR/dlls" > "$WORKDIR/dotnet_assemblies.txt"
    
    # FIX 3: Check if .NET is already installed
    if ! command -v dotnet &> /dev/null; then
        echo "[+] Installing .NET SDK"
        wget -q https://dot.net/v1/dotnet-install.sh -O dotnet-install.sh
        chmod +x dotnet-install.sh
        ./dotnet-install.sh --channel 8.0 --install-dir "$HOME/.dotnet" > /dev/null 2>&1
        export PATH="$HOME/.dotnet:$PATH"
    else
        echo "[+] .NET SDK already installed"
    fi
    
    # FIX 3: Check if ILSpy is already installed
    if ! command -v ilspycmd &> /dev/null; then
        echo "[+] Installing ILSpy decompiler"
        export PATH="$HOME/.dotnet:$PATH"
        dotnet tool install -g ilspycmd > /dev/null 2>&1 || true
        export PATH="$HOME/.dotnet/tools:$PATH"
    else
        echo "[+] ILSpy already installed"
    fi
    
    mkdir -p "$WORKDIR/decompiled"
    
    # Decompile each DLL
    for dll in "$WORKDIR/dlls"/*.dll; do
        DLL_NAME=$(basename "$dll" .dll)
        echo "[+] Decompiling $DLL_NAME.dll"
        
        ilspycmd "$dll" -o "$WORKDIR/decompiled/$DLL_NAME" 2>/dev/null || {
            echo "[!] Failed to decompile $DLL_NAME"
            mkdir -p "$WORKDIR/decompiled/$DLL_NAME"
            echo "Decompilation failed" > "$WORKDIR/decompiled/$DLL_NAME/ERROR.txt"
        }
    done
    
    echo "[+] .NET decompilation complete"
    
    # Create summary
    echo "Total DLLs: $DLL_COUNT" > "$WORKDIR/decompilation_summary.txt"
    echo "Decompiled to: work/decompiled/" >> "$WORKDIR/decompilation_summary.txt"
    echo "" >> "$WORKDIR/decompilation_summary.txt"
    echo "Assemblies:" >> "$WORKDIR/decompilation_summary.txt"
    ls "$WORKDIR/dlls" >> "$WORKDIR/decompilation_summary.txt"
else
    echo "[!] No .NET assemblies found - not a .NET app"
fi

# ====== END DECOMPILATION SECTION ======

echo "[+] Copying entire Payload for inspection"
cp -r "$WORKDIR/Payload" "$WORKDIR/payload_dump"

echo ""
echo "========================================="
echo "[+] Analysis Complete!"
echo "========================================="
echo "Results location: $WORKDIR"
echo ""
echo "Contents:"
echo "  - binary: Mach-O executable"
echo "  - strings.txt: Extracted strings"
echo "  - symbols.txt: Symbols (if available)"
echo "  - exports.txt: Exported symbols (if stripped)"
echo "  - objc_classes.txt: Objective-C class dump"
echo "  - entitlements.plist: Code signing entitlements"
echo "  - bundle_id.txt: Bundle identifier"
echo "  - url_schemes.txt: URL schemes"
echo "  - frameworks.txt: Linked frameworks"
echo "  - plugins.txt: Embedded plugins"
echo "  - app_contents.txt: App bundle listing"
if [ "$DLL_COUNT" -gt 0 ]; then
echo "  - dlls/: .NET assemblies"
echo "  - decompiled/: Decompiled C# source code"
echo "  - decompilation_summary.txt: Summary"
fi
echo "  - payload_dump/: Complete app bundle"
echo "========================================="
