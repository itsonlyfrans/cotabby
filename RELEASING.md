# Releasing this Cotabby fork

The fork at `itsonlyfrans/cotabby` ships as **Cotabby Fork.app**, bundle identifier
`com.itsonlyfrans.cotabby`. This is an installation distinction, not a new brand: it builds
the same app sources and keeps Cotabby's icon. Its settings and Accessibility, Input Monitoring,
and optional Screen Recording grants are separate from both upstream and `Cotabby Dev`.
The approved dev identity remains unchanged. Do not replace `/Applications/Cotabby.app`.

The `Cotabby Fork` target uses `CotabbyForkInfo.plist`, with automatic updates false and no
Sparkle feed or signing key. `COTABBY_DEV` disables updater startup in Debug **and** Release;
that flag currently changes only updater enablement. `COTABBY_FORK` selects the manual
releases and source links shown in the menu and About pane. Updates are manual until a separately
owned fork update channel is explicitly configured. A release must not use the upstream appcast,
update signing key, Pages domain, or Homebrew tap. Repository checks prevent the upstream release
and Pages jobs from running in this fork, including tag-triggered and manually dispatched runs.

## Build and package locally

Use an explicit version and monotonically increasing build number. Replace the example values
when selecting a release; these commands do not assign a release tag or publish anything.
Run serially in this checkout, after the relevant tests pass:

```bash
xcodegen generate
scripts/prepare_cotabby_workspace.sh
xcodebuild archive \
  -workspace build/cotabby-dependencies/Cotabby.xcworkspace \
  -scheme "Cotabby Fork" -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "build/fork-release/Cotabby Fork.xcarchive" \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION=1.0.0 CURRENT_PROJECT_VERSION=1
python3 scripts/package_fork_release.py \
  --app-path "build/fork-release/Cotabby Fork.xcarchive/Products/Applications/Cotabby Fork.app" \
  --validate-only
python3 -m venv build/fork-release/venv
build/fork-release/venv/bin/python3 -m pip install 'dmgbuild[badge_icons]==1.6.7'
build/fork-release/venv/bin/python3 scripts/package_fork_release.py \
  --app-path "build/fork-release/Cotabby Fork.xcarchive/Products/Applications/Cotabby Fork.app" \
  --identity "Developer ID Application: Frans Emmanuel (KU6R499PHR)"
```

The package helper checks built metadata before making any signing changes. It copies the
archive, signs nested code inside-out with hardened runtime and secure timestamps, verifies
the fork's Developer ID team, and writes `build/fork-release/Cotabby-Fork.dmg`. The source archive
is preserved. The ordinary local signer uses `--timestamp=none` and optional debugging/testing
entitlements, so it is unsuitable for distribution. Packaging does not install, notarize,
create update keys, or publish. It refuses to overwrite an existing DMG; retain a completed
artifact in a versioned subdirectory with `--output-dir build/fork-release/<version>`.

## Notarize and verify the artifact

Developer ID signing alone is not a notarized release. Configure an owned `notarytool` keychain
profile through Apple's supported credential flow; keep passwords/private keys out of commands,
logs, notes, and this repository. The example profile name below contains no credential value.

An existing signed-in Xcode account can also submit a **signed archive** without creating a
`notarytool` profile. This path was verified locally for 1.0.0 (1). Build a separate archive
with `CODE_SIGNING_ALLOWED=YES`, `CODE_SIGN_STYLE=Manual`, the owned Developer ID
`CODE_SIGN_IDENTITY`, and `DEVELOPMENT_TEAM`. The unsigned archive above cannot pass Xcode's
Developer ID export gate: the hardened-runtime flag must exist in its code signature.
Export options use `method=developer-id`, `destination=upload`, `signingStyle=manual`, the
owned team/certificate, `manageAppVersionAndBuildNumber=false`, and `uploadSymbols=false`.

```bash
xcodebuild -exportArchive \
  -archivePath "build/fork-release/Cotabby Fork-signed.xcarchive" \
  -exportOptionsPlist build/fork-release/ExportOptions-notarize.plist \
  -exportPath build/fork-release/xcode-export-signed
xcodebuild -exportNotarizedApp \
  -archivePath "build/fork-release/Cotabby Fork-signed.xcarchive" \
  -exportPath build/fork-release/notarized
xcrun stapler validate "build/fork-release/notarized/Cotabby Fork.app"
spctl --assess --type execute --verbose=2 "build/fork-release/notarized/Cotabby Fork.app"
ditto -c -k --sequesterRsrc --keepParent \
  "build/fork-release/notarized/Cotabby Fork.app" \
  build/fork-release/Cotabby-Fork-1.0.0.zip
```

Upload success alone is not notarization acceptance. Require successful notarized export,
ticket validation, deep/strict signature verification, and Gatekeeper acceptance, then repeat
those checks on a fresh ZIP extraction. Do not re-sign the exported app or pass it through
`package_fork_release.py`, which would replace its notarized signature. The verified ZIP
preserves the stapled app; it does not establish notarization of an earlier DMG container.

For the separately signed **DMG** route, submit that container itself with `notarytool`:

```bash
xcrun notarytool submit build/fork-release/Cotabby-Fork.dmg \
  --keychain-profile cotabby-fork-notary --wait --timeout 60m
xcrun stapler staple build/fork-release/Cotabby-Fork.dmg
xcrun stapler validate build/fork-release/Cotabby-Fork.dmg
spctl --assess --type open --context context:primary-signature --verbose=2 \
  build/fork-release/Cotabby-Fork.dmg
shasum -a 256 build/fork-release/Cotabby-Fork.dmg
```

Require Apple's **Accepted** result before stapling. Mount the resulting DMG read-only, verify
the packaged app with `codesign --verify --deep --strict`, check its bundle/version/update
metadata with `package_fork_release.py --validate-only`, and assess it with
`spctl --assess --type execute --verbose=2`. Verify the exact packaged app on the supported Mac
architectures and OS versions being claimed. Confirm its separate settings/permissions identity,
updater-off state, startup, completion, Tab acceptance, and non-secure-field gating. Granting
permissions to the dev build does not establish the fork build's grants. Quit competing Cotabby
instances during this check to avoid two global input monitors.

## Publication checklist

- Relevant source tests and Release build pass; record actual checks and limitations.
- Built fork metadata, Developer ID signature, notarization acceptance, staple, and Gatekeeper
  assessment pass for the final DMG or the stapled app extracted from the final ZIP.
  Record SHA-256 after packaging/stapling.
- Exact packaged app passes runtime checks. Confirm universal slices with `lipo -archs` before
  claiming Intel and Apple silicon support.
- Select version, build number, release tag, and draft notes. Keep the release private/draft until
  the final artifact and limitations are reviewable. Publish only to `itsonlyfrans/cotabby`.
- No appcast, upstream Pages deployment, or upstream Homebrew dispatch accompanies this fork release.
- Preserve the distributable under `build/fork-release`; remove `build/DerivedData` and verify cleanup
  once validation is complete. Keep temporary notarization/signing credentials out of tracked files.

Repository Actions secrets were absent at preparation time. Local signing can use an existing
Developer ID identity, but notarization authorization and an actual accepted artifact must be
verified separately. The isolated target and scripts alone are release preparation, not release
completion. Draft notes and current handoff state live in `work/fork-release.md`.

## Upstream release path

In `FuJacob/cotabby` only, the upstream Release workflow remains the distribution entry point: push a `v<version>` tag,
or dispatch it with `release_version` and `publish: false` to validate packaging without publishing.
It builds the production `Cotabby` scheme, signs with the configured upstream credentials,
notarizes and staples the DMG, then publishes the signed Sparkle appcast, GitHub release, Pages
site, and Homebrew cask update when publication is enabled.

Upstream's existing secret names, environments, appcast signing key, update feed, bundle identifier,
and tag-derived version / workflow-run build number remain unchanged. `Cotabby Dev` uses its
own identity and disables Sparkle in every build configuration.

The build stage first runs `scripts/prepare_cotabby_workspace.sh` to supply the pending
CotabbyInference APIs. This is the only native dependency preparation added to the release flow;
all functional app changes compile against the same package and patch as local builds and tests.
Once those APIs land upstream, the workspace override can be retired together with the patch.
Do not remove the patch before a compatible package revision is available.

See [CONTRIBUTING.md](CONTRIBUTING.md) for local builds and evaluations. Historical CoHamster
release notes describe past fork binaries and do not control Cotabby's release configuration.
