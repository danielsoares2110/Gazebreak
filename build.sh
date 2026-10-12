#!/bin/bash
# Build GazeBreak.app with Xcode (uses the real Gaze_v3.0.icon via ictool export).
set -euo pipefail
cd "$(dirname "$0")"

ICT="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
SRC_ICON="$HOME/Downloads/Gaze_v3.0.icon"

# 1. Render icon art from the actual .icon file (Apple's own renderer).
if [ -d "${SRC_ICON}" ]; then
  "$ICT" "${SRC_ICON}" --export-image --output-file GazeBreak/Gaze_v3.0.png \
    --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
  rm -rf GazeBreak/GazeBreak.iconset
  mkdir -p GazeBreak/GazeBreak.iconset
  for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
              "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
              "512 icon_256x256@2x" "512 icon_512x512"; do
    set -- $spec
    sips -z "$1" "$1" GazeBreak/Gaze_v3.0.png --out "GazeBreak/GazeBreak.iconset/$2.png" >/dev/null
  done
  cp GazeBreak/Gaze_v3.0.png GazeBreak/GazeBreak.iconset/icon_512x512@2x.png
  iconutil -c icns GazeBreak/GazeBreak.iconset -o GazeBreak/GazeBreak.icns
  # sips/iconutil propagate quarantine/FinderInfo xattrs -> strip them now,
  # otherwise codesign rejects the bundle ("detritus not allowed").
  xattr -c GazeBreak/Gaze_v3.0.png GazeBreak/GazeBreak.icns GazeBreak/GazeBreak.iconset/*.png 2>/dev/null || true
  echo "==> Icon re-rendered from ${SRC_ICON}"
else
  echo "--> ${SRC_ICON} missing; reusing committed Gaze_v3.0.png / GazeBreak.icns"
fi

# Strip quarantine/resource-fork xattrs (breaks hardened-runtime codesign).
xattr -cr GazeBreak GazeBreak.xcodeproj 2>/dev/null || true

# 2. Build (unsigned here; ad-hoc sign manually below for determinism).
rm -rf Build
xcodebuild -project GazeBreak.xcodeproj -target GazeBreak -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  CONFIGURATION_BUILD_DIR="$PWD/Build" SYMROOT="$PWD/Build" OBJROOT="$PWD/Build/Obj" build

# 2b. Ad-hoc sign (best effort). Finder re-stamps FinderInfo on bundles
# afterwards, so strict verification is not a release gate locally.
xattr -cr Build/GazeBreak.app 2>/dev/null || true
xattr -d com.apple.FinderInfo Build/GazeBreak.app 2>/dev/null || true
codesign --force --deep --sign - Build/GazeBreak.app 2>&1 | head -n 2 || true

# 3. Deploy to Desktop (best-effort sign; Finder may re-stamp after).
rm -rf ~/Desktop/GazeBreak.app
cp -R Build/GazeBreak.app ~/Desktop/GazeBreak.app
xattr -cr ~/Desktop/GazeBreak.app 2>/dev/null || true
xattr -d com.apple.FinderInfo ~/Desktop/GazeBreak.app 2>/dev/null || true
codesign --force --deep --sign - ~/Desktop/GazeBreak.app 2>&1 | head -n 2 || true
touch ~/Desktop/GazeBreak.app
echo "==> Done! Launch with: open ~/Desktop/GazeBreak.app"
ls -lh ~/Desktop/GazeBreak.app/Contents/Resources/
