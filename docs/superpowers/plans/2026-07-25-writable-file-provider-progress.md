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
| 13 | pending | RemuxSFTPReadOnlyClientTests safe-skip run pending | pending | in progress |

## Remaining live gates

- [ ] Disposable SFTP host: Jesse provides the exact pre-created empty remote root and confirms the saved Remux profile points to that disposable host. Then run the opt-in mutation test. Every create, upload, download, rename, replacement, deletion, cancellation, and explicit cleanup must remain beneath that root.
- [ ] Physical device: validate Files create, edit, rename, move, delete, non-empty-directory rejection, and callback behavior on a physical device. Simulator-only results do not establish this behavior.
