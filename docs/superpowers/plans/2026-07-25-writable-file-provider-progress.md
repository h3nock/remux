# Writable File Provider Progress

| Task | Commit | Focused tests | Review | Status |
| --- | --- | --- | --- | --- |
| 1 | a8ea8cd, 999e676 | focused identity/snapshot coverage | 6e676bb review; c5b31af review of root fix | complete |
| 2 | e9f19c9 | focused mutation-state coverage | b7563b2 final review | complete |
| 3 | f15e261, 266b4fd, 9ac9ec1 | RemuxSFTPReadOnlyClientTests | 3062e8b final review | complete |
| 4 | fc1fba2, bcc3929 | FileProviderRemoteServiceTests | 5049676 final review | complete |
| 5 | 5109406, e8ec5cf | FileProviderDomainOperationCoordinatorTests | 2e062c0 final review | complete |
| 6 | e7280e0, b953800 | mutation validator and error-mapper coverage | 7da2c1f final review | complete |
| 7 | 8da04dc, 1f794a3, 7b89f78 | FileProviderMutationCoreTests | a055d86 final review | complete |
| 8 | b42d234, c818ccb | FileProviderMutationCoreTests | aa2594f final review | complete |
| 9 | 1f85860, e35b46f, b0b0b27, 377fa38, 1f51794 | FileProviderMutationCoreTests | task-9-review.md | complete |
| 10 | fc568ba, 28135e5 | FileProviderMutationCoreTests and FileProviderSnapshotStoreTests (75 passed) | task-10-review.md | complete |
| 11 | 7ce7882 | contract and mutation-core tests (101 passed) | task-11-review.md | complete |
| 12 | cd914bf, cc19780 | FileProviderExtensionConfigurationTests (1 passed) | task-12-review.md | complete |
| 13 | 744c393, 8efc585, 999e676 | magic-kingdom live: 19 passed, 0 skipped, 0 failures | e07a390 host selector; c5b31af root fix | live SFTP complete; Files UI/device pending |
| 14 | pending | final focused suite: 198 passed, 1 opt-in disposable-host test skipped; final complete suite: 1,045 passed, 1 opt-in disposable-host test skipped | ae100f5 Task 14 review; 1bab149 coordinator ordering-race fix review | automated/build and disposable-host evidence recorded; Files/device pending |

## Task 14 verification evidence (2026-07-25)

- Focused writable-provider suite: `xcodebuild test` with all ten Task 14 `-only-testing` targets completed successfully: 194 executed, 1 skipped, 0 failures. The only skip was `RemuxSFTPReadOnlyClientTests.testWritableSFTPIntegrationMutationsStayInDedicatedRoot`, which is explicitly opt-in and requires `REMUX_WRITABLE_SFTP_INTEGRATION=1`. Full log: `.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/task-14-focused-suite.log`; Xcode result: `/Users/jesse/Library/Developer/Xcode/DerivedData/Remux-baapfdiwnnvmtnfolpbdblblyvtw/Logs/Test/Test-Remux-2026.07.25_18-55-51--0700.xcresult`.
- Complete Remux automated suite: completed successfully: 1,041 executed, 1 skipped, 0 failures. The same explicitly opt-in disposable-host test was the sole skip. Full log: `.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/task-14-full-suite.log`; Xcode result: `/Users/jesse/Library/Developer/Xcode/DerivedData/Remux-baapfdiwnnvmtnfolpbdblblyvtw/Logs/Test/Test-Remux-2026.07.25_18-56-11--0700.xcresult`.
- `scripts/qualify-writable-file-provider.sh` exited successfully and reported `Automated configuration checks passed.` Its log is `.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/task-14-qualification.log`; it regenerated the project with no `Remux.xcodeproj/project.pbxproj` or `RemuxFileProvider/Info.plist` drift.
- Generic iOS Simulator build: `xcodebuild build -project Remux.xcodeproj -scheme Remux -destination 'generic/platform=iOS Simulator' -derivedDataPath .derived-data/writable-file-provider` completed successfully. Log: `.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/task-14-generic-simulator-build.log`. The extension exists at `.derived-data/writable-file-provider/Build/Products/Debug-iphonesimulator/Remux.app/PlugIns/RemuxFileProvider.appex`.
- Built extension configuration: `.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/task-14-appex-nsextension.plist` confirms `NSExtensionFileProviderUploadPipelineDepth = 1` and `NSExtensionFileProviderMetadataOnlyUploadPipelineDepth = 1`; no `NSExtensionFileProviderReadOnly` key is present.
- Entitlement inspection limitation: the requested `codesign -d --entitlements :-` against the simulator extension returned an empty dictionary (recorded in `.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/task-14-appex-entitlements.plist`). The build's generated simulator entitlement payload at `.derived-data/writable-file-provider/Build/Intermediates.noindex/Remux.build/Debug-iphonesimulator/RemuxFileProvider.build/RemuxFileProvider.appex-Simulated.xcent` contains `com.apple.security.application-groups = group.dev.remux` and `keychain-access-groups = 87WJ58S66M.dev.remux.shared`, matching `RemuxFileProvider/RemuxFileProvider.entitlements`. This is build configuration evidence only; the simulator ad-hoc signature does not provide the requested codesign entitlement proof.
- Final branch check: `git diff --check 527604b..HEAD` produced no whitespace errors. `git log --oneline 527604b..HEAD` contains the coherent Tasks 1-13 series. The worktree was not clean before Task 14: it already contained untracked Task 9-13 review/report files; Task 14 also leaves its untracked report/log artifacts outside the commit by instruction.

## Unrun simulator Files matrix

The development simulator domain was not removed or recreated, and no Files matrix entry was run. There is no safe, pre-created live fixture with both password and private-key server profiles in this worktree. Therefore all eleven matrix behaviors remain unrun for both authentication modes; no simulator reset, profile/credential/trusted-host mutation, remote SSH mutation, upload cancellation, or extension restart was performed.

## Review disposition

Tasks 1-8 now have final review/fix commits: Task 1 `6e676bb` and `c5b31af`, Task 2 `b7563b2`, Task 3 `3062e8b`, Task 4 `5049676`, Task 5 `2e062c0`, Task 6 `7da2c1f`, Task 7 `a055d86`, and Task 8 `aa2594f`. Task 14 was reviewed in `ae100f5`. Its final rerun exposed a deterministic ordering-test synchronization race; the test synchronization was fixed in `5396170` and `43c75ce`, with final review recorded in `1bab149`. The final focused and complete evidence below was collected after those commits.

## Final reviewed verification evidence (2026-07-25)

- Exact ten-target focused suite after `1bab149`: 198 executed, 1 skipped, 0 failures. The only skip was the explicitly opt-in `testWritableSFTPIntegrationMutationsStayInDedicatedRoot` because `REMUX_WRITABLE_SFTP_INTEGRATION` remained unset. Log: `.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/task-14-final-reviewed-focused-suite.log`; result: `/Users/jesse/Library/Developer/Xcode/DerivedData/Remux-baapfdiwnnvmtnfolpbdblblyvtw/Logs/Test/Test-Remux-2026.07.25_19-25-08--0700.xcresult`.
- Complete Remux suite after `1bab149`: 1,045 executed, 1 skipped, 0 failures. The same opt-in disposable-host test was the sole skip. Log: `.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/task-14-final-reviewed-full-suite.log`; result: `/Users/jesse/Library/Developer/Xcode/DerivedData/Remux-baapfdiwnnvmtnfolpbdblblyvtw/Logs/Test/Test-Remux-2026.07.25_19-25-22--0700.xcresult`. Two Ghostty pasteboard tests each incurred a simulator pasteboard-service delay (154.802 and 145.065 seconds) but passed; the total test duration was 307.191 seconds.
- `scripts/qualify-writable-file-provider.sh` passed with no generated-project drift. Log: `.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/task-14-final-reviewed-qualification.log`.
- Final generic iOS Simulator build passed. Log: `.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/task-14-final-reviewed-generic-simulator-build.log`. The embedded extension is at `.derived-data/writable-file-provider-followup/Build/Products/Debug-iphonesimulator/Remux.app/PlugIns/RemuxFileProvider.appex`; its extension plist at `.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/task-14-final-reviewed-appex-nsextension.plist` has both upload pipeline depths set to one and no read-only key.
- The simulator extension remains ad-hoc signed: `codesign -d --entitlements :-` returned `{}` in `.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/task-14-final-reviewed-appex-entitlements.plist`. The generated simulated entitlement payload contains `group.dev.remux` and `87WJ58S66M.dev.remux.shared`. This establishes build configuration only; physical-device signing remains the entitlement-proof gate.

## Remaining live gates

- [x] Disposable SFTP host: `magic-kingdom` qualification used the pre-created empty root `/home/jesse/remux-writable-qualification-8c79abc31b4345f1a8bb4fa1ae9b7f6e`; all mutations were test-created children, explicit cleanup left it empty, and the root was then removed with non-recursive `rmdir`. Result: 19 passed, 0 skipped, 0 failures; `/tmp/remux-magic-live-20260725-1916.xcresult`; log: `.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/magic-kingdom-live-simenv.log`. Simulator `launchctl` environment was cleared afterward. This follow-up did not contact the host.
- [ ] Physical device: validate Files create, edit, rename, move, delete, non-empty-directory rejection, and callback behavior on a physical device. Simulator-only results do not establish this behavior.
