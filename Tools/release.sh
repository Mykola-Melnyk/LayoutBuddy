#!/usr/bin/env bash
#
# LayoutBuddy release pipeline:
#   archive → Developer ID export → notarize → staple → DMG → notarize → staple
#
# Produces a notarized, stapled disk image that opens on any Mac without
# Gatekeeper warnings. See Tools/RELEASE.md for the one-time setup.
#
# No credentials are hard-coded. Notarization auth is resolved in this order:
#   1. App Store Connect API key:  AC_API_KEY_PATH + AC_API_KEY_ID + AC_API_ISSUER_ID
#   2. Apple ID:                   APPLE_ID + APPLE_APP_PASSWORD (+ TEAM_ID)
#   3. Stored keychain profile:    NOTARY_PROFILE (default "LayoutBuddy")
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---- Config (override via env) ----
PROJECT="LayoutBuddy.xcodeproj"
SCHEME="LayoutBuddy"
APP_NAME="LayoutBuddy"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${TEAM_ID:-2GC3A5P98F}"
NOTARY_PROFILE="${NOTARY_PROFILE:-LayoutBuddy}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"

ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

run() { # run "<logfile>" cmd…  — quiet unless it fails
  local logf="$1"; shift
  if ! "$@" >"$logf" 2>&1; then
    echo "--- last 50 lines of $(basename "$logf") ---"; tail -50 "$logf"
    die "command failed: $*"
  fi
}

# ---- Preflight ----
command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode."

SIGN_ID="$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | grep "($TEAM_ID)" | head -1 \
  | sed -E 's/^[^"]*"([^"]+)".*/\1/' || true)"
[[ -n "$SIGN_ID" ]] || die "No 'Developer ID Application' certificate for team $TEAM_ID in your keychain. See Tools/RELEASE.md."

# Resolve notarytool auth.
NOTARY_AUTH=()
if [[ -n "${AC_API_KEY_PATH:-}" && -n "${AC_API_KEY_ID:-}" && -n "${AC_API_ISSUER_ID:-}" ]]; then
  NOTARY_AUTH=(--key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID")
  AUTH_DESC="App Store Connect API key"
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  NOTARY_AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$TEAM_ID")
  AUTH_DESC="Apple ID $APPLE_ID"
else
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  AUTH_DESC="keychain profile '$NOTARY_PROFILE'"
fi

log "Releasing $APP_NAME ($CONFIGURATION) — team $TEAM_ID, signing as: $SIGN_ID"
echo "  notarization via $AUTH_DESC"

rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"

notarize() { # notarize <file>
  local file="$1" logf="$BUILD_DIR/notary-$(basename "$file").log"
  if ! xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait 2>&1 | tee "$logf"; then :; fi
  if ! grep -q "status: Accepted" "$logf"; then
    local id; id="$(grep -m1 -E '^[[:space:]]*id:' "$logf" | awk '{print $2}')"
    echo "Inspect the failure with:  xcrun notarytool log ${id:-<submission-id>} <your-auth-args>"
    die "Notarization was not accepted for $(basename "$file")."
  fi
}

# ---- 1. Archive ----
log "Archiving…"
run "$BUILD_DIR/archive.log" xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID"
ok "Archived"

# ---- 2. Export (Developer ID) ----
log "Exporting Developer ID app…"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
run "$BUILD_DIR/export.log" xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -allowProvisioningUpdates
[[ -d "$APP" ]] || die "Export did not produce $APP (see $BUILD_DIR/export.log)."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ok "Exported $APP_NAME $VERSION"

# ---- 3. Verify signature + hardened runtime ----
codesign --verify --strict --deep --verbose=2 "$APP" 2>/dev/null || die "Codesign verification failed."
codesign -dvv "$APP" 2>&1 | grep -q 'flags=.*runtime' || die "Hardened runtime is not enabled on the app."
ok "Signature + hardened runtime verified"

# ---- 4. Notarize + staple the app ----
log "Notarizing app (this waits on Apple)…"
ZIP="$BUILD_DIR/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"
ok "App notarized + stapled"

# ---- 5. Build the DMG ----
log "Building DMG…"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
STAGE="$BUILD_DIR/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
run "$BUILD_DIR/dmg.log" hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
ok "DMG built + signed"

# ---- 6. Notarize + staple the DMG ----
log "Notarizing DMG…"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" >/dev/null && ok "DMG notarized + stapled"

# ---- Done ----
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /' || true
log "✅ Release ready: $DMG"
