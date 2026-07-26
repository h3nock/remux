# Writable File Provider Progress

| Task | Commit | Focused tests | Review | Status |
| --- | --- | --- | --- | --- |
| 1 | a8ea8cd | focused identity/snapshot coverage | not reviewed | complete |
| 2 | e9f19c9 | focused mutation-state coverage | not reviewed | complete |
| 3 | f15e261, 266b4fd, 9ac9ec1 | RemuxSFTPReadOnlyClientTests | not reviewed | complete |
| 4 | fc1fba2 | FileProviderRemoteServiceTests | not reviewed | complete |
| 5 | 5109406, e8ec5cf | FileProviderDomainOperationCoordinatorTests | not reviewed | complete |
| 6 | e7280e0, b953800 | mutation validator and error-mapper coverage | not reviewed | complete |
| 7 | 8da04dc, 1f794a3, 7b89f78 | FileProviderMutationCoreTests | f7fc328 follow-up coverage | complete |
| 8 | b42d234, c818ccb | FileProviderMutationCoreTests | not reviewed | complete |
| 9 | 1f85860, e35b46f, b0b0b27, 377fa38, 1f51794 | FileProviderMutationCoreTests | task-9-review.md | complete |
| 10 | fc568ba, 28135e5 | FileProviderMutationCoreTests and FileProviderSnapshotStoreTests (75 passed) | task-10-review.md | complete |
| 11 | 7ce7882 | contract and mutation-core tests (101 passed) | task-11-review.md | complete |
| 12 | cd914bf, cc19780 | FileProviderExtensionConfigurationTests (1 passed) | task-12-review.md | complete |
| 13 | 744c393, 8efc585, 999e676 | magic-kingdom live: 19 passed, 0 skipped, 0 failures | e07a390 host selector; c5b31af root fix | live SFTP complete; Files UI/device pending |
| 14 | pending | focused suite: 194 passed, 1 opt-in disposable-host test skipped; complete suite: 1,041 passed, 1 opt-in disposable-host test skipped | branch diff check: no whitespace errors; task-by-task review remains incomplete for Tasks 1-8 | automated/build evidence recorded; live gates pending |

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

Task 9-13 review artifacts exist in the worktree, but Task 1-8 have not received the Task 14 task-by-task code review required by the brief. No review fix was made in this verification pass; the focused suite above is the current post-Task-13 automated evidence.

## Remaining live gates

- [x] Disposable SFTP host: `magic-kingdom` qualification used the pre-created empty root `/home/jesse/remux-writable-qualification-8c79abc31b4345f1a8bb4fa1ae9b7f6e`; all mutations were test-created children, explicit cleanup left it empty, and the root was then removed with non-recursive `rmdir`. Result: 19 passed, 0 skipped, 0 failures; `/tmp/remux-magic-live-20260725-1916.xcresult`; log: `.superpowers/sdd/2026-07-25-writable-file-provider/artifacts/magic-kingdom-live-simenv.log`. Simulator `launchctl` environment was cleared afterward.
- [ ] Physical device: validate Files create, edit, rename, move, delete, non-empty-directory rejection, and callback behavior on a physical device. Simulator-only results do not establish this behavior.
