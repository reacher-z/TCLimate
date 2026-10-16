# Releasing TCLimate

Public releases must pass Developer ID signing, Apple notarization, stapling, and Gatekeeper validation. Never upload `submission.zip` or an unsigned build as a release asset.

## One-time local setup

Install a Developer ID Application certificate and its private key in your macOS Keychain. Set `TCL_RELEASE_CODESIGN_IDENTITY` to the certificate name or fingerprint, or save it in the ignored `.release-codesign-identity` file. Keep the same signing team and bundle identifier for updates.

Store notarization credentials interactively:

```sh
xcrun notarytool store-credentials TCLimate
```

Enter Apple credentials only at the local prompts. Apple ID authentication requires an app-specific password and the signing team's ID; App Store Connect API credentials are another option supported by notarytool. Do not paste credentials into issues, shell history, or the repository.

## Build and notarize

Update both version fields in `Scripts/Info.plist` when shipping a new version. Build from the exact commit that will be tagged.

```sh
./Scripts/build-app.sh release
export TCL_NOTARY_PROFILE=TCLimate
./Scripts/notarize-release.sh
./Scripts/build-dmg.sh
```

The release build combines arm64 and x86_64 executables into `dist/release/TCLimate.app`, enables hardened runtime, and signs with a secure timestamp. Local development builds remain separate at `dist/TCLimate.app`.

DMG packaging additionally requires [uv](https://docs.astral.sh/uv/); the script runs pinned `dmgbuild==1.6.7` in an isolated tool environment. These are release tools, not app dependencies. `dmg-settings.py` configures the app icon, Applications shortcut, arrow background, and Finder layout.

The notarization script stops unless Apple returns `Accepted`. It staples and validates the app's ticket, runs Gatekeeper assessment, then creates the distributable ZIP and checksum at `dist/releases/v<version>/`. `build-dmg.sh` packages the already-notarized app, signs and separately notarizes the disk image, staples its ticket, checks Gatekeeper, and updates checksums for both downloads. Service status and submission files stay ignored under `dist/`.

## Publish the public beta

The public beta uses a regular GitHub release marked Latest so it appears in the repository sidebar. Keep “Public Beta” in the title and notes; GitHub prereleases cannot be selected as Latest.

Only after notarization succeeds and the source commit is pushed:

```sh
git tag v0.1.0
git push origin v0.1.0
gh release create v0.1.0 \
  dist/releases/v0.1.0/TCLimate-v0.1.0-universal.dmg \
  dist/releases/v0.1.0/TCLimate-v0.1.0-universal.zip \
  dist/releases/v0.1.0/SHA256SUMS \
  --repo umarz317/TCLimate --verify-tag --latest \
  --title "v0.1.0 — Public Beta" --notes-file Docs/Releases/v0.1.0.md
```

Check the published archive after download: unzip it, run `xcrun stapler validate TCLimate.app` and `spctl --assess --type execute --verbose=2 TCLimate.app`. For the DMG, run `xcrun stapler validate <image.dmg>` and `spctl --assess --type open --context context:primary-signature --verbose=2 <image.dmg>`, then mount it read-only and verify the enclosed app and Applications shortcut. GitHub's automatically generated source archives are not notarized app builds.

See [Apple's notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
