#!/bin/bash
# Build, sign, notarize, staple, and package Sauron.dmg for distribution.
#
# One-time setup (requires Apple Developer Program membership, $99/yr):
#   1. developer.apple.com → Certificates → create a "Developer ID
#      Application" certificate and install it in your login keychain.
#   2. Store notary credentials (app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials sauron-notary \
#          --apple-id you@example.com --team-id YOURTEAMID
#
# Then just: make dist
# Override with IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=name
#
# CI mode: instead of a keychain profile, set NOTARY_APPLE_ID,
# NOTARY_PASSWORD (app-specific password), and NOTARY_TEAM_ID.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
PROFILE="${NOTARY_PROFILE:-sauron-notary}"

if [ -z "$IDENTITY" ]; then
    echo "error: no 'Developer ID Application' identity in the keychain." >&2
    echo "See the setup comment at the top of this script." >&2
    exit 1
fi
echo "signing as: $IDENTITY"

if [ -n "${NOTARY_APPLE_ID:-}" ]; then
    NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
    echo "notarizing as: $NOTARY_APPLE_ID ($NOTARY_TEAM_ID)"
else
    NOTARY_AUTH=(--keychain-profile "$PROFILE")
    echo "notarizing with keychain profile: $PROFILE"
fi

./scripts/make_app.sh

# Sign with hardened runtime + the Apple Events entitlement (Empty Trash).
codesign --force --options runtime --timestamp \
    --entitlements scripts/entitlements.plist \
    --sign "$IDENTITY" Sauron.app
codesign --verify --strict --verbose=2 Sauron.app

# Notarize the app itself, then staple so it verifies offline.
WORK="$(mktemp -d /tmp/sauron-dist.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
ditto -c -k --keepParent Sauron.app "$WORK/Sauron.zip"
xcrun notarytool submit "$WORK/Sauron.zip" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple Sauron.app

# Package a drag-to-Applications DMG; notarize and staple that too.
# Built read-write first so the volume gets the eye as its icon (the icon
# lives inside the image and survives download; a custom icon on the .dmg
# file itself would not — resource forks don't survive HTTP).
STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R Sauron.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f Sauron.dmg
hdiutil create -volname "Sauron" -srcfolder "$STAGE" -ov -format UDRW "$WORK/rw.dmg"
MOUNT_DIR="$WORK/mnt"
mkdir -p "$MOUNT_DIR"
hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen -mountpoint "$MOUNT_DIR" > /dev/null
cp .build/Sauron.icns "$MOUNT_DIR/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT_DIR"
hdiutil detach "$MOUNT_DIR" > /dev/null
hdiutil convert "$WORK/rw.dmg" -format UDZO -o Sauron.dmg > /dev/null
echo "created Sauron.dmg with volume icon"
codesign --force --timestamp --sign "$IDENTITY" Sauron.dmg
xcrun notarytool submit Sauron.dmg "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple Sauron.dmg

echo ""
echo "Sauron.dmg is signed, notarized, and stapled — ready to distribute."
spctl --assess --type open --context context:primary-signature -v Sauron.dmg || true
