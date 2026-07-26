# Task 14 Verification Report

Date: 2026-07-25

## Final commands and results

- Exact focused ten-target writable-provider command after final review commit `1bab149`: succeeded. 198 tests executed, 1 explicitly opt-in disposable-host test skipped, 0 failures. Log: `artifacts/task-14-final-reviewed-focused-suite.log`. Result bundle: `/Users/jesse/Library/Developer/Xcode/DerivedData/Remux-baapfdiwnnvmtnfolpbdblblyvtw/Logs/Test/Test-Remux-2026.07.25_19-25-08--0700.xcresult`.
- Complete `xcodebuild test` after `1bab149`: succeeded. 1,045 tests executed, the same 1 explicitly opt-in disposable-host test skipped, 0 failures. Log: `artifacts/task-14-final-reviewed-full-suite.log`. Result bundle: `/Users/jesse/Library/Developer/Xcode/DerivedData/Remux-baapfdiwnnvmtnfolpbdblblyvtw/Logs/Test/Test-Remux-2026.07.25_19-25-22--0700.xcresult`. The full run took 307.191 seconds because two Ghostty pasteboard tests waited on the simulator pasteboard service, then passed.
- `scripts/qualify-writable-file-provider.sh`: succeeded. Log: `artifacts/task-14-final-reviewed-qualification.log`.
- Generic Simulator build with `.derived-data/writable-file-provider-followup`: succeeded. Log: `artifacts/task-14-final-reviewed-generic-simulator-build.log`. The built `RemuxFileProvider.appex` is embedded in `Remux.app`; its extension plist has both upload pipeline depths set to one and no read-only extension key.
- `codesign -d --entitlements :-` on the simulator extension again produced `{}`. The generated `RemuxFileProvider.appex-Simulated.xcent` contains the configured App Group and shared Keychain group, but device-signed entitlement proof remains required.
- The initially failing full-suite coordinator test was diagnosed as a deterministic test-submission ordering race. Its synchronization fix is `5396170` and `43c75ce`, reviewed in `1bab149`; the final focused and complete runs above passed after it.
- All Tasks 1-8 now have final review/fix commits: `6e676bb`, `c5b31af`, `b7563b2`, `3062e8b`, `5049676`, `2e062c0`, `7da2c1f`, `a055d86`, and `aa2594f`.

## Open gates

- Disposable SFTP host: complete in prior `magic-kingdom` qualification (19 passed, 0 skipped, 0 failures; `/tmp/remux-magic-live-20260725-1916.xcresult`). This follow-up did not contact the host.
- Simulator Files matrix: unrun for password and private-key authentication. No safe pre-created live fixture was available, and the development simulator domain was not reset.
- Physical device: unrun. It is required for actual signed entitlement validation and File Provider behavior in Files.
- Task-by-task review: complete through the final review/fix commits listed above; Task 14's ordering-race review is `1bab149`.
