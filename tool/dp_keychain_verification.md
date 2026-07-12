# Verifying the macOS Data Protection keychain (entitled success path)

On macOS the resolver picks native Data Protection keychain items (AES-256-GCM +
Secure Enclave, `hardwareBacked`) **only** for a signed app carrying a
`keychain-access-groups` entitlement authorized by a provisioning profile. Its
two other outcomes are covered automatically:

- **Refusal path** (`errSecMissingEntitlement` −34018 → the file scheme) — CI,
  every push (`keychain_integration_test.dart`, plus the resolver end-to-end).
- **Unentitled file scheme inside a real `.app`** — the `example_flutter/`
  harness, `flutter test integration_test -d macos` (no signing needed).

The **entitled success path** can't run in CI (no signing identity) and needs a
one-time local run on a Mac with Xcode and an Apple Development identity.

## Just run the script

`tool/test_e2e.sh --entitled` is the supported path. It applies the entitled
config overlay temporarily, provisions with `-allowProvisioningUpdates`, runs the
entitled leg with the right dart-defines, and **always restores** the overlay on
exit (a trap), so the default unentitled build stays runnable:

```sh
./tool/test_e2e.sh --entitled
```

Look for `macOS entitled (DP success)  PASS` in the summary. Everything below is
just what that leg (`leg_entitled` / `apply_entitled_overlay` in the script)
does, for when you want to reproduce it by hand or diagnose a failure.

## Prerequisite (this is what blocks it)

The account holder must have accepted the **current Apple Developer Program
License Agreement**. If not, automatic provisioning fails with:

> Unable to process request - PLA Update available: … your team's Account
> Holder … must agree to the latest Program License Agreement.

Accept it at <https://developer.apple.com/account> (or App Store Connect) →
then provisioning works. Nothing in this repo can bypass this; it is a legal
agreement tied to the Apple ID.

## By hand (what the script automates)

The permanent harness is `example_flutter/` — no throwaway app.

1. **Signing + identity** — append to
   `example_flutter/macos/Runner/Configs/AppInfo.xcconfig` (a target-level
   xcconfig outranks the project's ad-hoc `CODE_SIGN_IDENTITY = "-"`):

   ```
   DEVELOPMENT_TEAM = <YOUR_TEAM_ID>
   CODE_SIGN_IDENTITY = Apple Development
   ```

2. **Entitlement** — in `example_flutter/macos/Runner/DebugProfile.entitlements`
   add (the default access group is implicit; `$(AppIdentifierPrefix)` resolves
   at sign time):

   ```xml
   <key>keychain-access-groups</key>
   <array>
     <string>$(AppIdentifierPrefix)com.example.exampleFlutter</string>
   </array>
   ```

3. **Provision once** — Flutter's build does not pass
   `-allowProvisioningUpdates`, so create the managed profile directly
   (registers the App ID under your team):

   ```sh
   cd example_flutter && flutter build macos --debug --config-only
   cd macos && xcodebuild build -workspace Runner.xcworkspace -scheme Runner \
     -configuration Debug -destination 'platform=macOS' -allowProvisioningUpdates
   ```

   Expected: `** BUILD SUCCEEDED **`. If it fails on the PLA, do the
   prerequisite above. If it fails with "No profiles found" *after* accepting
   the PLA, open the workspace in Xcode once so it can sign in / 2FA, then retry.

4. **Run the entitled leg** — pass the same dart-defines the script uses. The
   distinct `APP_ID` matters: it keeps this native-scheme store from colliding
   with the default-appId **file**-scheme store the unentitled leg leaves on the
   same machine, which would otherwise trip the scheme-migration guard
   (`MigrationRequired`) at construction.

   ```sh
   cd example_flutter
   flutter test integration_test/keyway_test.dart -d macos \
     --dart-define=EXPECT_SCHEME=native \
     --dart-define=EXPECT_LEVEL=hardware \
     --dart-define=APP_ID=com.example.keywayHarness.native
   ```

   Expected: **All tests passed!** The first test (`resolver picked the scheme +
   level this environment must get`) asserts `info.scheme ==
   StorageScheme.nativeItems` and `info.level == SecurityLevel.hardwareBacked` —
   i.e. the DP **success** branch is live. A build error about "entitlements that
   require signing with a development certificate" means step 1's identity didn't
   take; a runtime `keystore_unreachable` means the entitlement/profile isn't in
   effect (recheck steps 2–3).

5. **Revert the overlay** — remove the two edits from steps 1–2 to restore the
   default ad-hoc build so the unentitled leg (`--dart-define=EXPECT_SCHEME=file`,
   `-d macos`) runs again. (`tool/test_e2e.sh` does this automatically.)
