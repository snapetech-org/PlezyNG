# macOS App Store candidate

The manual `macOS App Store Candidate` workflow configures a separate macOS
`SUPPORTER_MODE=iap` build with update checks disabled, selects the sandboxed
`macos/Runner/AppStore.entitlements` in the Xcode build settings, creates an
unsigned `.xcarchive`, and packages the universal app with `productbuild` as an
unsigned installer. Code signing is disabled, so the archive does not enforce
or qualify the sandbox at runtime. Its artifact includes the archive, package,
and a JSON receipt with the source commit, bundle identity, version,
architectures, package digest, and explicit qualification fields.

The candidate is retained as a workflow artifact and is not added to the
versioned GitHub release. It does not change or replace the direct distribution
DMG. The receipt deliberately reports the app, installer, StoreKit purchase and
restore flow, sandbox runtime, JIT runtime, App Store Connect processing, and
Apple review as unqualified. The build has no App Store signing credentials and
the generated package cannot be uploaded to App Store Connect.

Apple distribution remains gated on an Apple Distribution app signature and a
Mac Installer Distribution signature, App Store Connect processing, sandboxed
runtime qualification (including the embedded JIT-dependent playback paths),
and StoreKit purchase and restore on a Mac. The candidate workflow is a
source-owned packaging path; it is not evidence that those external account and
device checks passed.

To create a new candidate, dispatch `macOS App Store Candidate` from `main` and
retain its package and JSON receipt together. Keep the candidate's commit and
artifact digest paired when presenting it for account-backed qualification.
