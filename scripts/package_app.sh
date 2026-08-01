#!/bin/bash
# Package FleetView into a double-clickable FleetView.app bundle.
#   ./scripts/package_app.sh            → builds ./FleetView.app (release)
#   ./scripts/package_app.sh --install  → also copies it to /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▸ Building release binary (this compiles SwiftTerm too the first time)…"
swift build -c release

BIN="$ROOT/.build/release/FleetView"
APP="$ROOT/FleetView.app"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FleetView"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FleetView</string>
    <key>CFBundleDisplayName</key><string>FleetView</string>
    <key>CFBundleIdentifier</key><string>ai.eigent.fleetview</string>
    <key>CFBundleExecutable</key><string>FleetView</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><false/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

# Ad-hoc code-sign so macOS keeps TCC/permissions stable across rebuilds.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "▸ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "▸ Installing to /Applications"
    rm -rf "/Applications/FleetView.app"
    ditto "$APP" "/Applications/FleetView.app"
    echo "▸ Installed /Applications/FleetView.app"
fi

# treeflow is what opens a Codex conversation at a past node — FleetView has its own Swift port of
# the Claude side but nothing equivalent for Codex, so without it Codex search hits cannot be
# opened. Offered rather than installed silently: it is a pip install into the user's own Python,
# which is not a thing a build script should do behind your back. Skip with SKIP_TREEFLOW=1.
if [[ -z "${SKIP_TREEFLOW:-}" ]] && ! command -v treeflow >/dev/null 2>&1; then
    echo
    echo "▸ treeflow isn't installed — it's what opens Codex conversations at a past node."
    echo "  Install it from GitHub? (pip install into your current Python)"
    read -r -p "  [y/N] " reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        pip3 install "git+https://github.com/nitpicker55555/Agent-Treeflow.git" \
            && echo "▸ treeflow installed" \
            || echo "! treeflow install failed — Codex node opening will be unavailable"
    else
        echo "  Skipped. Install later with:"
        echo "    pip3 install 'git+https://github.com/nitpicker55555/Agent-Treeflow.git'"
    fi
fi

echo "✓ Done."
