#!/bin/zsh
# Build "Wayback.app" and install it into ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Wayback.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/backend"

swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/Wayback" app/Sources/*.swift

# Bundle uv (a self-contained binary, macOS 11+) so the app works without Homebrew.
cp "$(command -v uv)" "$APP/Contents/MacOS/uv"
codesign --force --sign - "$APP/Contents/MacOS/uv"

cp app/Info.plist "$APP/Contents/Info.plist"
[[ -f app/AppIcon.icns ]] && cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
rsync -a --exclude '__pycache__' --exclude '.venv' backend/pyproject.toml backend/uv.lock backend/.python-version backend/wayback \
  "$APP/Contents/Resources/backend/"

codesign --force --deep --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/"Wayback.app" ~/Applications/"Session Search.app"
cp -R "$APP" ~/Applications/
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -u "$APP" 2>/dev/null || true
"$LSREG" -f ~/Applications/"Wayback.app"
echo "Installed ~/Applications/Wayback.app"

# Release artifact: ditto keeps the code signature and extended attributes intact.
rm -f build/Wayback.zip
ditto -c -k --keepParent "$APP" build/Wayback.zip
echo "Packaged build/Wayback.zip"
