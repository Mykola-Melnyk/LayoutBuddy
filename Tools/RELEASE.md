# Releasing LayoutBuddy

`Tools/release.sh` produces a **notarized, stapled `.dmg`** that opens on any Mac
without Gatekeeper warnings:

```
archive → Developer ID export → notarize → staple → DMG → notarize → staple
```

LayoutBuddy is distributed **outside the Mac App Store** (a session-wide event
tap + Accessibility control of other apps can't run sandboxed), so it ships as a
Developer ID app.

## One-time setup

You need an Apple Developer account (you have one) and two things on the build
machine:

### 1. A "Developer ID Application" certificate

In Xcode: **Settings → Accounts → (your team) → Manage Certificates → `+` →
Developer ID Application**. Confirm it's installed:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Notarization credentials

Create an **app-specific password** at <https://appleid.apple.com> (Sign-In &
Security → App-Specific Passwords), then store it once as a keychain profile:

```sh
xcrun notarytool store-credentials "LayoutBuddy" \
  --apple-id "you@example.com" \
  --team-id  "2GC3A5P98F" \
  --password "abcd-efgh-ijkl-mnop"   # the app-specific password
```

The script uses the `LayoutBuddy` profile by default.

## Release

```sh
./Tools/release.sh
```

Output: `build/LayoutBuddy-<version>.dmg`, notarized and stapled. The version
comes from the app target's `MARKETING_VERSION` — bump it in Xcode before
cutting a release.

## Configuration (env overrides)

| Variable | Default | Purpose |
|---|---|---|
| `CONFIGURATION` | `Release` | xcodebuild configuration |
| `TEAM_ID` | `2GC3A5P98F` | signing team |
| `NOTARY_PROFILE` | `LayoutBuddy` | stored notarytool keychain profile |
| `BUILD_DIR` | `./build` | output directory |

Instead of the keychain profile you can pass auth via env (useful in CI):

- **App Store Connect API key:** `AC_API_KEY_PATH`, `AC_API_KEY_ID`, `AC_API_ISSUER_ID`
- **Apple ID:** `APPLE_ID`, `APPLE_APP_PASSWORD` (with `TEAM_ID`)

## Troubleshooting

- **"No 'Developer ID Application' certificate…"** — step 1 above.
- **Notarization not accepted** — the script prints the submission id; run
  `xcrun notarytool log <id> --keychain-profile LayoutBuddy` to see why
  (usually an unsigned nested binary or a missing hardened-runtime flag).
- **Verify a finished build manually:**
  ```sh
  spctl -a -t open --context context:primary-signature -vv build/LayoutBuddy-*.dmg
  xcrun stapler validate build/LayoutBuddy-*.dmg
  ```
