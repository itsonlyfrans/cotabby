# Fork release preparation

Goal: prepare a reviewable distributable for `itsonlyfrans/cotabby` without replacing upstream
Cotabby, changing the approved dev identity, or publishing to upstream update destinations.
Parent owns builds, actual signing/notarization checks, release publication, and changelog entries.

## Decision and boundaries

Use `Cotabby Fork` / `com.itsonlyfrans.cotabby` as a third target based on the existing app template.
Reusing `Cotabby Dev` would reuse current permissions, but would make a distributed app inherit
a shared development identity. Reusing `Cotabby` would collide with the installed production app
and its updates. A third target adds a plist and scheme while preserving the common source graph;
its cost is a separate first-run settings and permissions setup. This is the minimal identity
separation; product copy and icon remain Cotabby's.

The fork plist has no Sparkle feed/public key and all automatic-update settings false. The existing
`COTABBY_DEV` condition plus distinct `COTABBY_FORK` condition disable the updater in every fork
configuration. A future use of the dev condition needs review for this distributable.
Upstream's feed/key, credentials, and Homebrew routing remain intact, but each upstream release
job and the Pages republish job is gated to `FuJacob/cotabby`. There is no automated fork publisher.

`package_fork_release.py` owns distribution signing and artifact containment. It validates the
actual built plist and executable, refuses upstream/dev identities and update keys/feeds, copies
the app, signs nested binaries before enclosing bundles, removes debug/test app entitlements,
requires Developer ID team `KU6R499PHR`, then packages and signs a distinct DMG. It never modifies
the input archive, installed applications, Keychain contents, or remote destinations. It uses
secure timestamps, unlike `sign_local_app.py`, which deliberately uses `--timestamp=none` and
can enable XCTest/debugging entitlements. Signing and notarization are separate boundaries.

## Prepared

- Fork target, scheme specification, dedicated updater-free plist.
- Upstream workflow repository gates; no upstream endpoint migration or key creation.
- Local distribution packaging command with built-metadata validation mode.
- Exact build/package/notarization commands and release checklist in `RELEASING.md`.

XcodeGen regeneration is delegated to the parent after its current shared build finishes. No
build, actual signing, notarization submission, installation, push, tag, or publication was
performed by this preparation worker.

Bounded checks completed: Python compile/help, plist lint, project/workflow YAML parsing, and
`git diff --check` passed. A temporary synthetic built bundle passed validation; seven variants
with upstream/dev identities, update feed/key, enabled checks, unresolved version metadata, or
invalid executable path were rejected. This checks guard behavior, not real signing or packaging.

## Draft release notes

Cotabby Fork builds on the upstream local-first autocomplete app with more reliable completion
and safer text handling. Personal Vocabulary saves explicit names and specialist words on your
Mac, protects their spelling, and gives unique exact-prefix matches priority over generated text.
Typing-history suggestions avoid duplicating text already after the caret. Correction replacement
keeps UTF-16 context offsets separate from keyboard deletion counts, and recovered web focus is
checked against the current window. Popup suggestions can move above the caret near a screen edge.

This fork installs alongside upstream Cotabby with a separate settings and permissions identity.
Automatic updates are disabled; new fork releases are installed manually. Add the actual validation
results, supported platform claims, known limitations, selected version/build/tag, and final
artifact checksum before publishing these notes. Do not claim runtime proof from this draft.

## Remaining gates and next action

Update UI handoff: `AppUpdateManager` exposes build capability and manual fork release/source URLs.
The fork menu and About pane now offer a user-initiated “View Fork Releases” link with manual
installation help; dev update buttons are disabled and upstream Sparkle behavior is unchanged.
Both GitHub source links use the fork implementation URL in fork builds; support/wiki attribution
is unchanged. No feed/network polling was added. No UI capture was taken because the user asked
to avoid interrupting current work. Parent owns XcodeGen regeneration and Release build validation.
Targeted SwiftLint (cache disabled), project YAML/build-flag assertions, source-link/update-policy
checks, and `git diff --check` passed. These are source checks; link clicks and live UI were not tested.

Parent: regenerate the project; validate fork build settings and plist; archive Release; package
with the existing Developer ID identity; verify notarization authorization without exposing it;
submit only within authorized publication scope; require Accepted/stapled/Gatekeeper-approved
artifact and runtime verification; finalize version/notes/checksum; publish only to the fork.
GitHub Actions secrets were empty at preparation time, so upstream CI credentials cannot be
assumed. Record the actual successful boundaries and concrete blockers here.

## Local package evidence, 2026-10-09

A universal Release archive built successfully at version **1.0.0 (1)**; its executable
contains `x86_64 arm64`. Metadata validation passed. The packaging helper produced
`build/fork-release/Cotabby-Fork.dmg` with Developer ID signing, hardened runtime and
secure timestamps. The read-only mounted app passed deep/strict signature and fork
metadata checks. Its identity is `com.itsonlyfrans.cotabby`, team `KU6R499PHR`.

Pre-notarization DMG SHA-256:
`4f24d3a02eb96733ee81bd528d11730f811c37f4fa240363c1da19102519761c`.
Gatekeeper returned `rejected / Unnotarized Developer ID`, as expected before notarization.
The temporary mount was ejected. This is a signed local package, not a public release.

The first Xcode Developer ID upload attempt stopped locally: the unsigned archive lacked
a runtime code-signature flag even though the project enables hardened runtime. The DMG
copy was signed correctly, but signing that copy does not sign the archive. A second,
Developer ID-signed archive is being built through Xcode for its upload path. No Apple
submission has yet succeeded, no release was published, and no credentials were read.

## Notarized artifact verified

The second Xcode archive succeeded with Developer ID signing and hardened runtime.
Xcode used the existing signed-in account to upload successfully, then
`-exportNotarizedApp` succeeded. No new profile, credential extraction, secret configuration,
or user authentication was needed. The exported app passed `stapler validate`, deep/strict
signature verification and Gatekeeper: **accepted / Notarized Developer ID**.

The final distributable is `build/fork-release/Cotabby-Fork-1.0.0.zip`, preserving that
exported app without re-signing. A fresh extraction passed the same three checks.
SHA-256: `8dc21baf2cff745da91f50db5b55c96c14cedad1c75cae9b014a749b23aadd14`.
The earlier signed DMG remains a pre-notarization artifact, not the deliverable.
Both architectures are included; execution on Intel hardware was not tested.

The separate `Cotabby Dev` target also rebuilt in Release as 1.0.0 (1), was signed with
its existing Apple Development identity and staged at `build/Development/Cotabby Dev.app`.
Two obsolete Debug-only libraries from the older destination were removed after strict
verification identified them as added resources. Final strict verification and the prior
permission signing requirement passed. The refreshed binary was launched in the background;
state-only logs confirm both required grants, Apple engine availability and service startup.
No new global-key or broader-host test was performed after the no-interruption request.

The exact distribution bundle has its own permissions and has not completed interactive
onboarding/Tab acceptance. Keep the release draft until that runtime check is convenient.
The approved cleanup of DerivedData and the previous Dev backup was rejected again by
`core.filesystem:rm-rf-general`; do not bypass it. Final app, archives, ZIP, logs and research remain.
