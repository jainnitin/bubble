# Developing Bubble

Needs Xcode: the Command Line Tools alone can't expand SwiftUI's macros.

```sh
scripts/bundle.sh            # release build: build/Bubble.app, Developer ID (else ad-hoc), hardened runtime
scripts/bundle.sh --install  # also copies it to /Applications
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build   # debug build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test    # unit tests
```


under a sandbox profile that skips macOS-protected folders; see Privacy below. Launch a dev build
with `-simulateNoFullDiskAccess YES` to see that mode on a Mac that has access.

Some tests run real processes in a pseudo-terminal (bash scripts standing in for Mole and sudo).
The test that needs an installed Mole skips itself without one; `BUBBLE_LIVE_MOLE=1 swift test
--filter LiveOptimizeWhitelistTests` runs a real `mo optimize --dry-run` with the temporary whitelist.

**Dev builds.** `BUBBLE_DEV=1 scripts/bundle.sh` compiles in debug hooks that release builds don't
contain (`release.sh` refuses to ship them). Pass them as launch arguments, for example
`open build/Bubble.app --args -simulateNoMole YES`:

| Argument | Effect |
|---|---|
| `-simulateNoMole YES` | Mole reported missing (welcome screen) |
| `-simulateNoBrew YES` | Homebrew reported missing (install-script route) |
| `-simulateMoleVersion 1.40.0` | Report this Mole version (update screen) |
| `-simulateInstallFailure YES` | The simulated install fails (error screen) |
| `-simulateNoFullDiskAccess YES` | Full Disk Access reported off everywhere (setup step, Settings, Checkup, and Clean/Analyze run guarded) |
| `-lastTab Status`, `-appsSub Updates` | Open on a section |
| `-autoStart YES` | Clean and Analyze start their read-only scan on launch |

While any `-simulate…` argument is set, installing or updating Mole is a dry run with canned
output. `scripts/shot.sh <Tab> out.png` relaunches a dev build on a section and screenshots its
window (check the image before sharing it: Status shows your IP address, processes and devices).

The app icon is drawn in code; see [scripts/icon/README.md](../scripts/icon/README.md).

## Releasing

Settings live in `updates.conf` (repo, feed URL, public key, Keychain account) and `VERSION`.
`CFBundleVersion` is derived from the version (`1.2.3` → `1002003`), so every new version is newer
to Sparkle.

One-time setup:

1. Set `GITHUB_REPO` in `updates.conf` to the real `owner/repo`. The feed URL is derived from it:
   `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`.
2. The EdDSA private key is in the login Keychain as "Private key for signing Sparkle updates",
   account `bubble`. Its public half is `SU_PUBLIC_ED_KEY` in `updates.conf`. Export the private key
   into the release secret, then delete the exported file:
   ```sh
   swift package resolve   # fetches Sparkle's tools into .build/artifacts
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account bubble -x ~/bubble_ed25519
   gh secret set SPARKLE_ED_PRIVATE_KEY --env release < ~/bubble_ed25519 && rm -P ~/bubble_ed25519
   ```
3. The secret lives in a GitHub environment named `release` (Settings ▸ Environments), not in the
   repo-wide secrets. Give that environment a deployment rule limited to tags matching `v*.*.*`
   (and ideally a required reviewer), so no other branch or workflow can read the key.
4. Keep a backup of the private key (for example in a password manager). Without it, existing
   installs can't be updated.
5. Add the Apple secrets to the same `release` environment (the same values as `~/code/keel`):
   `MACOS_CERT_P12_BASE64` and `MACOS_CERT_PASSWORD` (the Developer ID Application certificate),
   and `APPLE_API_KEY_P8_BASE64`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` (an App Store Connect
   API key, used to notarize).
6. For local releases, save the notary credentials once:
   `xcrun notarytool store-credentials bubble --key <AuthKey.p8> --key-id <ID> --issuer <issuer>`.

To cut a release, bump `VERSION`, commit, then `git tag v$(cat VERSION) && git push --tags`.
`.github/workflows/release.yml` runs `scripts/release.sh` in the `release` environment: it builds
the app, signs it with Developer ID, notarizes and staples it, zips it with `ditto`, signs the zip, writes a signed `appcast.xml` with Sparkle's
`generate_appcast`, and checks the signature against `SU_PUBLIC_ED_KEY`. It then packs the same app
into `Bubble-X.Y.Z.dmg` for downloads (`scripts/dmg.sh`), and signs, notarizes and staples the DMG
too. A separate job without the key then attaches the DMG, the zip and `appcast.xml` to the GitHub
Release. Sparkle only uses the zip and the appcast; the DMG is what people download to install. If `release-notes/X.Y.Z.md` exists, it
appears in the update dialog. To build a release locally with the Keychain key, run
`scripts/release.sh` (the output goes to `dist/`); `SKIP_NOTARIZE=1` skips notarization for a
test build.

The DMG window (Bubble.app, an Applications shortcut and an arrow between them) is laid out by
[dmgbuild](https://github.com/dmgbuild/dmgbuild), which writes Finder's `.DS_Store` directly, so it
works on a headless CI runner without scripting Finder. `scripts/dmg.sh` installs it into
`build/dmgbuild-venv` from `scripts/dmg/requirements.txt` (pinned by hash); its settings are in
`scripts/dmg/settings.py`. To try the DMG without releasing:
`scripts/bundle.sh && scripts/dmg.sh build/Bubble.app build/Bubble.dmg`. The background
(`assets/dmg-background.png` and `@2x`) is drawn by `swift scripts/dmg/render-background.swift`.

Builds use the hardened runtime with the `com.apple.security.automation.apple-events` entitlement
(Mole runs `osascript`, and macOS checks Bubble for it). `scripts/bundle.sh` signs with the first
Developer ID Application identity in your keychains (override with `SIGN_IDENTITY`, or `-` for
ad-hoc). Ad-hoc builds also set `cs.disable-library-validation`, because without a Team ID the
hardened runtime won't load Sparkle.framework; Developer ID builds keep library validation on.

CI (`.github/workflows/ci.yml`) builds with and without the debug hooks and runs the tests on
every push and pull request.

