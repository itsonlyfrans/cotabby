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
