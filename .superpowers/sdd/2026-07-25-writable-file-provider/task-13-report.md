# Task 13 report: real SFTP mutation qualification

## Implemented

- Added an opt-in Citadel integration test that resolves the latest saved Remux
  profile only when `REMUX_WRITABLE_SFTP_INTEGRATION=1` is set.
- The test requires `REMUX_WRITABLE_SFTP_TEST_ROOT` to be a canonical,
  pre-created, empty remote directory with at least two non-empty path
  components. It rejects empty paths, `/`, `.`, and any `.` or `..` component.
- Under that exact root, the test covers directory creation, upload/download,
  file and directory rename, temporary-upload replacement, file deletion,
  empty-directory removal, non-empty-directory rejection with child
  preservation, and a cancelled large temporary upload that preserves the old
  destination.
- Cleanup addresses every generated file and directory by name with
  `removeFile` and `removeEmptyDirectory`; it does not call a recursive remove.
- Added the requested executable qualification helper. It regenerates XcodeGen
  outputs, checks writable File Provider configuration, and prints only manual
  live gates. It does not reset a simulator, delete a domain, connect to SSH,
  or mutate a remote path.

## Automated evidence

The targeted test command ran without the opt-in environment:

```sh
xcodebuild test -quiet -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxSFTPReadOnlyClientTests
```

Result: 15 passed, 0 failed, 1 skipped. The skipped test is the disposable-host
integration test, as intended. Result bundle:

`/Users/jesse/Library/Developer/Xcode/DerivedData/Remux-baapfdiwnnvmtnfolpbdblblyvtw/Logs/Test/Test-Remux-2026.07.25_18-50-19--0700.xcresult`

`scripts/qualify-writable-file-provider.sh` also completed its generated-output
and configuration checks. `git diff --check` passed.

## Live disposable-host qualification

Jesse authorized the saved `magic-kingdom` profile for mutations limited to
test-created files. The test used the exact pre-created root
`/home/jesse/remux-writable-qualification-8c79abc31b4345f1a8bb4fa1ae9b7f6e`.
It verified that root was empty before mutation, performed every qualified
operation beneath it, explicitly removed only the created files and empty
directories, verified the root was empty afterward, and then removed the root
itself with non-recursive `rmdir`. No pre-existing remote path was touched.

The opt-in simulator run wrote its result bundle to
`/tmp/remux-magic-live-20260725-1916.xcresult` and its execution log to
`.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/magic-kingdom-live-simenv.log`.
It completed with 19 passed, 0 skipped, and 0 failures. The simulator
`launchctl` environment was cleared after the run.

The exact-host selector used for this qualification is `8efc585`, reviewed by
`e07a390`. The fresh File Provider root-enumeration fix is `999e676`, reviewed
by `c5b31af`.

## Remaining qualification

The live SFTP mutation gate is complete. The Files UI matrix and physical-device
qualification remain unchecked; this run did not exercise either.

## Retained-root replacement qualification

This replaces the removed-root evidence above as the live qualification record.
Using the saved `magic-kingdom` profile, the test created and retained the new
empty root
`/home/jesse/remux-writable-qualification-retained-8345c41c4172432c9566a801f3c14e65`.
It was verified empty before the run and remains present and empty afterward.
Only test-created children beneath that root were mutated and explicitly
cleaned; no pre-existing remote path was touched and the root itself was not
removed.

The booted iPhone 17 run completed with 19 passed, 0 skipped, and 0 failures.
Result bundle:
`/tmp/remux-magic-live-retained-20260725-1930.xcresult`. Execution log:
`.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/magic-kingdom-live-retained-simenv.log`.
The simulator `launchctl` environment for all writable-SFTP integration
variables was cleared after the run.

This verifies the SFTP mutation path only. The Files UI matrix and physical
device qualification remain unchecked.
