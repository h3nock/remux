# Writable SSH File Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Remux's unshipped read-only File Provider behavior with safe, remote-authoritative creation, modification, movement, and deletion of regular files and directories over SFTP.

**Architecture:** Persist opaque item identities and mutation receipts in the existing snapshot state, then serialize namespace refreshes and mutations through one domain coordinator. Each mutation validates live remote state, performs bounded path-contained SFTP operations, commits authoritative snapshots and replay state, and only then completes the File Provider callback.

**Tech Stack:** Swift 6, iOS 18+, XcodeGen, XCTest, FileProvider, UniformTypeIdentifiers, Citadel SFTP v3, SwiftNIO, App Groups, Keychain access groups.

## Global Constraints

- The read-only File Provider never shipped; add no production migration, identifier translation, compatibility mode, or legacy-domain marker.
- Existing development simulator domains may be manually removed and recreated; never delete saved profiles, credentials, trusted-host records, or remote files as part of that reset.
- Regular files support create, overwrite, rename, move, and delete.
- Directories support create, rename, move, and deletion only while empty.
- Never recursively delete a remote directory, including when File Provider passes `.recursive`.
- Symbolic links remain read-only; never create, modify, rename, move, or delete them.
- Metadata-only fields remain unsupported: permissions, tags, favorite rank, extended attributes, creation date, and other fields outside contents, filename, and parent identifier.
- Remote state wins conflicts; never silently overwrite a file changed by a coding agent or other SSH client.
- Never truncate an existing remote file in place and never use delete-then-rename as a replacement fallback.
- All remote paths remain beneath the canonical authenticated home returned by `realPath(".")`.
- Do not advertise remote trash behavior.
- Mutation logs, snapshots, identities, and receipts contain no passwords, private keys, passphrases, or file contents.
- Keep the iOS 18.0 deployment target and the existing pinned Citadel revision.
- Keep File Provider upload and metadata-only upload pipeline depths at one.
- Tests exercise structured behavior, not rendered commands, generated plist text, or large serialized snapshots.

---

## File Map

### Stable identity and persisted domain state

- `RemuxApp/Sources/FileProvider/FileProviderItemIdentity.swift`: opaque provider identity, identified remote item, replay key, and receipt value types.
- `RemuxApp/Sources/FileProvider/FileProviderRemotePath.swift`: normalized remote paths and opaque identifier encoding/validation.
- `RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift`: atomic identity allocation, path relocation, directory snapshots, bounded generations, pending signals, and bounded mutation receipts.
- `RemuxApp/Sources/FileProvider/FileProviderRemoteItem.swift`: remote metadata and version calculation; it remains independent of provider identity.
- `RemuxApp/Sources/FileProvider/FileProviderItemProjection.swift`: project an identified remote item into File Provider metadata.

### Serialization and mutation planning

- `RemuxApp/Sources/FileProvider/FileProviderDomainOperationCoordinator.swift`: serialize refresh and mutation turns for one domain with cancellation-aware waiters.
- `RemuxApp/Sources/FileProvider/FileProviderMutationRequest.swift`: structured create/modify/delete inputs and supported-field partitioning.
- `RemuxApp/Sources/FileProvider/FileProviderMutationValidator.swift`: type, collision, base-version, destination, and directory-cycle validation.
- `RemuxApp/Sources/FileProvider/FileProviderMutationCore.swift`: remote-authoritative create, modify, move, rename, and delete transactions.
- `RemuxApp/Sources/FileProvider/FileProviderPollingCoordinator.swift`: removed after its behavior is subsumed by the domain coordinator.

### SFTP and remote service

- `RemuxApp/Sources/SSH/RemuxSFTPClient.swift`: provider write protocol and normalized mutation errors.
- `RemuxApp/Sources/SSH/RemuxCitadelSFTPClient.swift`: strict mkdir, upload, rename, remove, and rmdir implementations.
- `RemuxApp/Sources/FileProvider/FileProviderRemoteService.swift`: single-lease path-contained mutation session.
- `RemuxApp/Sources/FileProvider/FileProviderCitadelSFTPClientProvider.swift`: provide the combined read/write client to the extension.

### File Provider bridge and configuration

- `RemuxApp/Sources/FileProvider/FileProviderEnumeratorCore.swift`: consume identified snapshots through the domain coordinator.
- `RemuxApp/Sources/FileProvider/FileProviderReplicatedExtensionCore.swift`: item lookup, fetch, mutation request execution, progress, receipts, and lifecycle draining.
- `RemuxApp/Sources/FileProvider/FileProviderSDKItem.swift`: shared `NSFileProviderItem` adapter used by callbacks and structured collision/deletion errors.
- `RemuxFileProvider/Sources/RemuxFileProviderExtension.swift`: adapt SDK create/modify/delete callbacks to structured core requests.
- `RemuxFileProvider/Sources/RemuxFileProviderItem.swift`: removed after its adapter moves into shared provider code.
- `project.yml`: remove the private read-only key and set both upload pipeline depths to one.
- `RemuxFileProvider/Info.plist` and `Remux.xcodeproj/project.pbxproj`: regenerated XcodeGen outputs.

### Tests and qualification

- `RemuxAppTests/FileProviderRemoteItemTests.swift`: opaque identifier and stable projection behavior.
- `RemuxAppTests/FileProviderSnapshotStoreTests.swift`: identity allocation, relocation, local mutation commits, and receipts.
- `RemuxAppTests/FileProviderDomainOperationCoordinatorTests.swift`: refresh/mutation ordering and cancellation.
- `RemuxAppTests/RemuxSFTPReadOnlyClientTests.swift`: combined Citadel read/write adapter behavior.
- `RemuxAppTests/FileProviderRemoteServiceTests.swift`: containment and remote mutation-session behavior.
- `RemuxAppTests/FileProviderMutationValidatorTests.swift`: field, type, conflict, collision, and cycle decisions.
- `RemuxAppTests/FileProviderMutationCoreTests.swift`: create, modify, move, rename, delete, replay, cleanup, and snapshot behavior.
- `RemuxAppTests/RemuxFileProviderContractTests.swift`: extension-core progress, cancellation, invalidation, and exactly-once completion.
- `RemuxAppTests/FileProviderErrorMapperTests.swift`: writable File Provider error mappings.
- `RemuxAppTests/FileProviderExtensionConfigurationTests.swift`: built extension is writable and pipeline depths are one.
- `scripts/qualify-writable-file-provider.sh`: non-destructive build/configuration checks and printed live qualification checklist; it never mutates a remote host itself.
- `docs/superpowers/plans/2026-07-25-writable-file-provider-progress.md`: task evidence and remaining manual gates.

---

### Task 1: Stable opaque identities end to end

**Files:**
- Create: `RemuxApp/Sources/FileProvider/FileProviderItemIdentity.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderRemotePath.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderErrorMapper.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderItemProjection.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderEnumeratorCore.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderReplicatedExtensionCore.swift`
- Modify: `RemuxFileProvider/Sources/RemuxFileProviderExtension.swift`
- Test: `RemuxAppTests/FileProviderRemoteItemTests.swift`
- Test: `RemuxAppTests/FileProviderSnapshotStoreTests.swift`
- Test: `RemuxAppTests/RemuxFileProviderContractTests.swift`
- Test: `RemuxAppTests/FileProviderErrorMapperTests.swift`

**Interfaces:**
- Produces: `enum FileProviderItemIdentity: Hashable, Codable, Sendable`
- Produces: `struct FileProviderIdentifiedItem: Equatable, Codable, Sendable`
- Produces: `FileProviderItemIdentifierCodec.identifier(for:)` and `identity(for:)`
- Produces: `FileProviderSnapshotStore.path(for:)`,
  `pathSynchronously(for:)`, `item(for:)`, and identity-assigning `record`
- Changes: enumeration and item projection consume `FileProviderIdentifiedItem`

- [ ] **Step 1: Replace path-codec tests with opaque identity tests**

```swift
func testOpaqueIdentifierRoundTripsIdentityWithoutExposingPath() throws {
    let identity = FileProviderItemIdentity.item(
        UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )
    let codec = FileProviderItemIdentifierCodec()

    let identifier = codec.identifier(for: identity)

    XCTAssertEqual(identifier.rawValue, "i:11111111-2222-3333-4444-555555555555")
    XCTAssertEqual(try codec.identity(for: identifier), identity)
    XCTAssertFalse(identifier.rawValue.contains("report"))
    XCTAssertEqual(codec.identifier(for: .root), .rootContainer)
}

func testOpaqueIdentifierRejectsPathAndMalformedRepresentations() {
    let codec = FileProviderItemIdentifierCodec()

    XCTAssertThrowsError(
        try codec.identity(
            for: NSFileProviderItemIdentifier(rawValue: "p:cmVwb3J0LnR4dA")
        )
    )
    XCTAssertThrowsError(
        try codec.identity(
            for: NSFileProviderItemIdentifier(rawValue: "i:not-a-uuid")
        )
    )
}
```

- [ ] **Step 2: Write failing snapshot identity tests**

```swift
func testRecordAllocatesAndPersistsIdentityForPath() async throws {
    let ids = FileProviderTestIdentitySequence([
        UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
    ])
    let store = FileProviderSnapshotStore(
        rootURL: root,
        identityGenerator: { ids.next() }
    )
    let remote = try item(path: "report.txt")

    let first = try await store.record(directory: .root, items: [remote])
    let second = try await store.record(directory: .root, items: [remote])

    XCTAssertEqual(first.items, second.items)
    XCTAssertEqual(
        first.items.first?.identity,
        .item(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
    )
    XCTAssertEqual(
        try await store.path(for: first.items[0].itemIdentifier),
        remote.path
    )
    XCTAssertEqual(
        try store.pathSynchronously(for: first.items[0].itemIdentifier),
        remote.path
    )
}

func testRemoteRenameUsesDeleteAndNewIdentity() async throws {
    let ids = FileProviderTestIdentitySequence([
        UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
        UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
    ])
    let store = FileProviderSnapshotStore(
        rootURL: root,
        identityGenerator: { ids.next() }
    )
    let original = try item(path: "old.txt")
    let renamed = try item(path: "new.txt")
    let first = try await store.record(directory: .root, items: [original])

    let second = try await store.record(directory: .root, items: [renamed])

    XCTAssertNotEqual(first.items[0].identity, second.items[0].identity)
    XCTAssertEqual(second.delta.deleted, [first.items[0].itemIdentifier])
}

func testUnshippedLegacySnapshotFileIsIgnored() async throws {
    try Data("legacy-path-identity-state".utf8).write(
        to: root.appendingPathComponent("snapshot-generations.json")
    )
    let store = FileProviderSnapshotStore(rootURL: root)

    let result = try await store.record(
        directory: .root,
        items: [try item(path: "report.txt")]
    )

    XCTAssertEqual(result.items.count, 1)
    XCTAssertTrue(
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "snapshot-generations-v2.json"
            ).path
        )
    )
}
```

Add the mapper regression:

```swift
func testUnknownOpaqueIdentityMapsToRequestedNoSuchItem() {
    let identifier = NSFileProviderItemIdentifier(
        rawValue: "i:11111111-2222-3333-4444-555555555555"
    )

    let error = FileProviderErrorMapper.map(
        FileProviderSnapshotStoreError.itemIdentityNotFound,
        itemIdentifier: identifier
    )

    XCTAssertEqual(error.domain, NSFileProviderErrorDomain)
    XCTAssertEqual(error.code, NSFileProviderError.noSuchItem.rawValue)
    XCTAssertEqual(
        error.userInfo[NSFileProviderErrorNonExistentItemIdentifierKey]
            as? NSFileProviderItemIdentifier,
        identifier
    )
}
```

Use this deterministic helper in
`FileProviderSnapshotStoreTests.swift`:

```swift
private final class FileProviderTestIdentitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.withLock {
            precondition(!values.isEmpty)
            return values.removeFirst()
        }
    }
}
```

- [ ] **Step 3: Run identity tests and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderRemoteItemTests \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests \
  -only-testing:RemuxTests/FileProviderErrorMapperTests
```

Expected: compile failures because identity types, the generator seam, and identified snapshot results do not exist.

- [ ] **Step 4: Add the opaque identity types and codec**

```swift
enum FileProviderItemIdentity: Hashable, Codable, Sendable {
    case root
    case item(UUID)

    var itemIdentifier: NSFileProviderItemIdentifier {
        FileProviderItemIdentifierCodec().identifier(for: self)
    }
}

struct FileProviderIdentifiedItem: Equatable, Codable, Sendable {
    let identity: FileProviderItemIdentity
    let remoteItem: FileProviderRemoteItem

    var itemIdentifier: NSFileProviderItemIdentifier {
        identity.itemIdentifier
    }
}

struct FileProviderItemIdentifierCodec: Sendable {
    private static let itemPrefix = "i:"

    func identifier(
        for identity: FileProviderItemIdentity
    ) -> NSFileProviderItemIdentifier {
        switch identity {
        case .root:
            return .rootContainer
        case .item(let id):
            return NSFileProviderItemIdentifier(
                rawValue: Self.itemPrefix + id.uuidString.lowercased()
            )
        }
    }

    func identity(
        for identifier: NSFileProviderItemIdentifier
    ) throws -> FileProviderItemIdentity {
        guard identifier != .rootContainer else { return .root }
        let raw = identifier.rawValue
        guard raw.hasPrefix(Self.itemPrefix),
              let id = UUID(uuidString: String(raw.dropFirst(2)))
        else {
            throw FileProviderRemotePathError.invalidItemIdentifier
        }
        return .item(id)
    }
}
```

- [ ] **Step 5: Persist identified items and allocate only for new remote paths**

Change persisted directory entries from `[FileProviderRemoteItem]` to
`[FileProviderIdentifiedItem]`. Inject the identity generator:

```swift
private let identityGenerator: @Sendable () -> UUID

init(
    rootURL: URL,
    retainedGenerationCount: Int = 8,
    fileManager: FileManager = .default,
    identityGenerator: @escaping @Sendable () -> UUID = UUID.init
) {
    self.identityGenerator = identityGenerator
    // retain existing initialization
}
```

Change the private state filename to `snapshot-generations-v2.json`. Do not read,
rewrite, or delete the unshipped path-identity file
`snapshot-generations.json`.

During `record`, preserve identities by exact normalized path and allocate only
for paths absent from the latest generation:

```swift
let previousByPath = Dictionary(
    uniqueKeysWithValues: previousItems.map { ($0.remoteItem.path, $0.identity) }
)
let identified = items.map { remote in
    FileProviderIdentifiedItem(
        identity: previousByPath[remote.path] ?? .item(identityGenerator()),
        remoteItem: remote
    )
}
```

Make deltas compare `remoteItem` while reporting the stable
`itemIdentifier`. Add:

```swift
func path(
    for identifier: NSFileProviderItemIdentifier
) throws -> FileProviderRemotePath

nonisolated func pathSynchronously(
    for identifier: NSFileProviderItemIdentifier
) throws -> FileProviderRemotePath

func item(
    for identifier: NSFileProviderItemIdentifier
) throws -> FileProviderIdentifiedItem?
```

The synchronous lookup reads the atomically replaced state file with a fresh
decoder, so the SDK can reject an unknown container without awaiting the actor.
The root identifier resolves to `.root`; unknown opaque identifiers throw
`FileProviderSnapshotStoreError.itemIdentityNotFound`.
Map that error through the requested identifier to File Provider's formatted
no-such-item error; it must not become a generic XPC error.

- [ ] **Step 6: Move projection, enumeration, item lookup, and fetch to identified items**

Use:

```swift
init(item: FileProviderIdentifiedItem, rootDisplayName: String)
```

`FileProviderEnumeratorCore` returns identified items from `record`.
`FileProviderReplicatedExtensionCore.item` and `fetchContents` resolve the path
through `FileProviderSnapshotStore` instead of decoding it from the identifier.
Root lookup constructs:

```swift
FileProviderIdentifiedItem(identity: .root, remoteItem: remoteRoot)
```

The synchronous SDK `enumerator(for:)` resolves the container with
`pathSynchronously(for:)`, returns a formatted no-such-item error for an unknown
identity, and gives the resolved path to `FileProviderEnumeratorScope.directory`.
The enumerator core continues to use the actor-backed async snapshot APIs after
construction.

- [ ] **Step 7: Run focused tests and verify GREEN**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderRemoteItemTests \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests \
  -only-testing:RemuxTests/FileProviderErrorMapperTests
```

Expected: all selected tests pass; no test expects a path-derived identifier.

- [ ] **Step 8: Commit**

```bash
git add RemuxApp/Sources/FileProvider/FileProviderItemIdentity.swift \
  RemuxApp/Sources/FileProvider/FileProviderRemotePath.swift \
  RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift \
  RemuxApp/Sources/FileProvider/FileProviderErrorMapper.swift \
  RemuxApp/Sources/FileProvider/FileProviderItemProjection.swift \
  RemuxApp/Sources/FileProvider/FileProviderEnumeratorCore.swift \
  RemuxApp/Sources/FileProvider/FileProviderReplicatedExtensionCore.swift \
  RemuxFileProvider/Sources/RemuxFileProviderExtension.swift \
  RemuxAppTests/FileProviderRemoteItemTests.swift \
  RemuxAppTests/FileProviderSnapshotStoreTests.swift \
  RemuxAppTests/RemuxFileProviderContractTests.swift \
  RemuxAppTests/FileProviderErrorMapperTests.swift
git commit -m "Persist stable File Provider item identities"
```

---

### Task 2: Atomic local mutation state and replay receipts

**Files:**
- Modify: `RemuxApp/Sources/FileProvider/FileProviderItemIdentity.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift`
- Test: `RemuxAppTests/FileProviderSnapshotStoreTests.swift`

**Interfaces:**
- Produces: `FileProviderMutationReplayKey`
- Produces: `FileProviderMutationReceipt`
- Produces: `FileProviderSnapshotLocalMutation`
- Produces: `FileProviderSnapshotStore.commit(localMutation:)`
- Produces: `FileProviderSnapshotStore.receipt(for:)`

- [ ] **Step 1: Write failing local-relocation and no-signal tests**

```swift
func testLocalMoveRetainsIdentityRelocatesDescendantsAndDoesNotQueueSignal() async throws {
    let store = FileProviderSnapshotStore(rootURL: root)
    let folder = try item(path: "old", type: .directory)
    let child = try item(path: "old/child.txt")
    let rootRecord = try await store.record(directory: .root, items: [folder])
    _ = try await store.record(
        directory: FileProviderRemotePath(relative: "old"),
        items: [child]
    )
    let identity = rootRecord.items[0].identity

    let moved = try await store.commit(
        localMutation: FileProviderSnapshotLocalMutation(
            refreshedDirectories: [
                .init(directory: .root, items: [
                    try item(path: "new", type: .directory),
                ]),
                .init(
                    directory: FileProviderRemotePath(relative: "new"),
                    items: [try item(path: "new/child.txt")]
                ),
            ],
            relocations: [
                .init(
                    identity: identity,
                    from: FileProviderRemotePath(relative: "old"),
                    to: FileProviderRemotePath(relative: "new")
                ),
            ],
            deletedIdentities: [],
            receipt: nil
        )
    )

    XCTAssertEqual(
        try await store.path(for: identity.itemIdentifier),
        try FileProviderRemotePath(relative: "new")
    )
    XCTAssertEqual(
        moved.items.first(where: { $0.identity == identity })?.remoteItem.path,
        try FileProviderRemotePath(relative: "new")
    )
    XCTAssertNil(try await store.pendingWorkingSetSignalGeneration())
}
```

- [ ] **Step 2: Write failing bounded receipt replay test**

```swift
func testMutationReceiptPersistsAndExpiresWithRetainedGenerations() async throws {
    let store = FileProviderSnapshotStore(
        rootURL: root,
        retainedGenerationCount: 2
    )
    let key = FileProviderMutationReplayKey.create(
        templateIdentifier: "system-template-1"
    )
    let created = FileProviderIdentifiedItem(
        identity: .item(UUID()),
        remoteItem: try item(path: "created.txt")
    )

    _ = try await store.commit(
        localMutation: .init(
            refreshedDirectories: [.init(directory: .root, items: [created.remoteItem])],
            identityReservations: [.init(identity: created.identity, path: created.remoteItem.path)],
            receipt: .item(key: key, item: created)
        )
    )
    XCTAssertEqual(try await store.receipt(for: key), .item(key: key, item: created))

    _ = try await store.record(directory: .root, items: [created.remoteItem, try item(path: "a")])
    _ = try await store.record(directory: .root, items: [created.remoteItem, try item(path: "b")])

    XCTAssertNil(try await store.receipt(for: key))
}
```

- [ ] **Step 3: Run snapshot tests and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests
```

Expected: compile failures for local mutation, identity relocation, reservation,
and receipt APIs.

- [ ] **Step 4: Add structured local transaction and receipt types**

```swift
enum FileProviderMutationReplayKey: Hashable, Codable, Sendable {
    case create(templateIdentifier: String)
    case modify(
        identity: FileProviderItemIdentity,
        contentVersion: Data,
        metadataVersion: Data,
        changedFields: UInt
    )
    case delete(
        identity: FileProviderItemIdentity,
        contentVersion: Data,
        metadataVersion: Data
    )
}

enum FileProviderMutationReceipt: Equatable, Codable, Sendable {
    case item(
        key: FileProviderMutationReplayKey,
        item: FileProviderIdentifiedItem
    )
    case deleted(
        key: FileProviderMutationReplayKey
    )
}

struct FileProviderSnapshotLocalMutation: Sendable {
    struct DirectoryRefresh: Sendable {
        let directory: FileProviderRemotePath
        let items: [FileProviderRemoteItem]
    }

    struct IdentityRelocation: Sendable {
        let identity: FileProviderItemIdentity
        let from: FileProviderRemotePath
        let to: FileProviderRemotePath
    }

    struct IdentityReservation: Sendable {
        let identity: FileProviderItemIdentity
        let path: FileProviderRemotePath
    }

    let refreshedDirectories: [DirectoryRefresh]
    var identityReservations: [IdentityReservation] = []
    var relocations: [IdentityRelocation] = []
    var deletedIdentities: Set<FileProviderItemIdentity> = []
    var receipt: FileProviderMutationReceipt?
    var queuesWorkingSetSignal = false
}
```

- [ ] **Step 5: Commit local snapshots, identities, and receipts in one state save**

Implement `commit(localMutation:)` by loading state once, applying reservations,
relocations and deletions, identifying every refreshed listing from the updated
mapping, pruning or relocating descendants, appending one generation, attaching
the receipt to that generation, pruning receipts older than the oldest retained
generation, and saving once.

Do not append a `pendingSignals` entry for normal local mutations. Keep
`record(directory:items:)` as the remote-refresh path that appends pending
signals. When `queuesWorkingSetSignal` is true for a partial postcommit outcome,
append one pending signal in the same save.

- [ ] **Step 6: Run tests and verify GREEN**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests
```

Expected: all snapshot, stable identity, relocation, pruning, signal, and receipt
tests pass.

- [ ] **Step 7: Commit**

```bash
git add RemuxApp/Sources/FileProvider/FileProviderItemIdentity.swift \
  RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift \
  RemuxAppTests/FileProviderSnapshotStoreTests.swift
git commit -m "Add atomic File Provider mutation state"
```

---

### Task 3: Strict SFTP write primitives

**Files:**
- Modify: `RemuxApp/Sources/SSH/RemuxSFTPClient.swift`
- Modify: `RemuxApp/Sources/SSH/RemuxCitadelSFTPClient.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderErrorMapper.swift`
- Test: `RemuxAppTests/RemuxSFTPReadOnlyClientTests.swift`

**Interfaces:**
- Produces: `protocol RemuxSFTPFileProviderClient: RemuxSFTPReadOnlyClient`
- Produces: strict create/upload/rename/remove/rmdir methods
- Produces: normalized `RemuxSFTPClientError.permissionDenied` and `unsupportedMutation`

- [ ] **Step 1: Write failing adapter tests for every strict write operation**

```swift
func testFileProviderWriteOperationsCallExactCitadelRequests() async throws {
    let connection = FakeCitadelSFTPConnection()
    let client = makeClient(connection: connection)
    let source = temporaryFile(contents: Data("new".utf8))

    try await client.createDirectory(atPath: "/home/me/new")
    try await client.uploadFile(
        from: source,
        to: "/home/me/.remux-upload-fixture",
        progress: { _ in }
    )
    try await client.renameItem(
        from: "/home/me/.remux-upload-fixture",
        to: "/home/me/report.txt"
    )
    try await client.removeFile(atPath: "/home/me/report.txt")
    try await client.removeEmptyDirectory(atPath: "/home/me/new")

    XCTAssertEqual(await connection.mutations(), [
        .mkdir("/home/me/new"),
        .openWrite("/home/me/.remux-upload-fixture"),
        .rename("/home/me/.remux-upload-fixture", "/home/me/report.txt"),
        .removeFile("/home/me/report.txt"),
        .rmdir("/home/me/new"),
    ])
}
```

Also add tests proving `.permissionDenied` normalizes to
`RemuxSFTPClientError.permissionDenied`, and cancellation closes the remote
upload handle without issuing rename or removal.

- [ ] **Step 2: Run the focused test and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxSFTPReadOnlyClientTests
```

Expected: compile failures for the provider write protocol and strict
directory/file mutation methods.

- [ ] **Step 3: Add the provider write protocol**

```swift
protocol RemuxSFTPFileProviderClient: RemuxSFTPReadOnlyClient {
    func createDirectory(atPath path: String) async throws
    func uploadFile(
        from localURL: URL,
        to remotePath: String,
        progress: @escaping RemuxSFTPFileUploadProgressHandler
    ) async throws
    func renameItem(from sourcePath: String, to destinationPath: String) async throws
    func removeFile(atPath path: String) async throws
    func removeEmptyDirectory(atPath path: String) async throws
}
```

Keep `RemuxSFTPUploadClient` for terminal attachment transfer. Make
`RemuxCitadelSFTPClient` conform to both protocols without duplicating upload
logic.

- [ ] **Step 4: Extend the Citadel connection seam and implementation**

Add:

```swift
func remuxRemoveDirectory(atPath path: String) async throws
```

and implement it with `SFTPClient.rmdir(at:)`. Rename the provider-facing
adapter methods to the strict names above. `createDirectory` must not treat an
already existing path as success; collision detection belongs above this layer.

Normalize only Citadel `.errorStatus(.permissionDenied)` into
`RemuxSFTPClientError.permissionDenied`. Keep ambiguous `.failure` as
`unsupportedMutation` only for write operations; do not change read-error
normalization. Update the exhaustive error-mapper switch so permission denied
uses the existing Cocoa write-permission error and unsupported mutation remains
sanitized until Task 6 adds operation-specific File Provider errors.

- [ ] **Step 5: Run tests and verify GREEN**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxSFTPReadOnlyClientTests
```

Expected: all read, download, upload, timeout, close, and strict write adapter
tests pass.

- [ ] **Step 6: Commit**

```bash
git add RemuxApp/Sources/SSH/RemuxSFTPClient.swift \
  RemuxApp/Sources/SSH/RemuxCitadelSFTPClient.swift \
  RemuxApp/Sources/FileProvider/FileProviderErrorMapper.swift \
  RemuxAppTests/RemuxSFTPReadOnlyClientTests.swift
git commit -m "Add strict SFTP File Provider writes"
```

---

### Task 4: Path-contained single-lease mutation session

**Files:**
- Modify: `RemuxApp/Sources/FileProvider/FileProviderRemoteService.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderCitadelSFTPClientProvider.swift`
- Test: `RemuxAppTests/FileProviderRemoteServiceTests.swift`
- Test: `RemuxAppTests/RemuxFileProviderContractTests.swift`

**Interfaces:**
- Produces: `protocol FileProviderRemoteMutationAccess`
- Produces: `FileProviderRemoteServicing.withMutationAccess`
- Changes: `FileProviderSFTPClientProviding` yields `RemuxSFTPFileProviderClient`

- [ ] **Step 1: Write failing containment and one-lease tests**

```swift
func testMutationAccessUsesOneClientLeaseAndContainedPaths() async throws {
    let fixture = try await FileProviderRemoteServiceFixture.makeWritable()
    let parent = try FileProviderRemotePath(relative: "projects")
    let child = try FileProviderRemotePath(relative: "projects/report.txt")

    try await fixture.service.withMutationAccess { access in
        _ = try await access.list(directory: parent)
        try await access.uploadFile(
            from: fixture.localFile,
            to: child,
            progress: { _ in }
        )
        try await access.renameItem(
            from: child,
            to: FileProviderRemotePath(relative: "projects/final.txt")
        )
    }

    XCTAssertEqual(fixture.clientProvider.callCount, 1)
    XCTAssertEqual(
        await fixture.client.mutationPaths(),
        [
            "/home/reader/projects/report.txt",
            "/home/reader/projects/report.txt",
            "/home/reader/projects/final.txt",
        ]
    )
}

func testMutationAccessRejectsDestinationBelowEscapingSymlinkParent() async throws {
    let fixture = try await FileProviderRemoteServiceFixture.makeWritable(
        canonicalPaths: ["/home/reader/link": "/etc"]
    )

    await XCTAssertThrowsErrorAsync(
        try await fixture.service.withMutationAccess { access in
            try await access.createDirectory(
                at: FileProviderRemotePath(relative: "link/new")
            )
        }
    ) { error in
        XCTAssertEqual(error as? FileProviderRemotePathError, .unsafeLinkTarget)
    }
    XCTAssertTrue(await fixture.client.mutations().isEmpty)
}
```

Extend the existing remote-service fixture with:

```swift
static func makeWritable(
    canonicalPaths: [String: String] = [:]
) async throws -> FileProviderRemoteServiceFixture
```

Its `FileProviderTestSFTPClient` conforms to
`RemuxSFTPFileProviderClient`, records absolute mutation paths, and exposes:

```swift
func mutations() async -> [FileProviderTestSFTPMutation]
func mutationPaths() async -> [String]
```

- [ ] **Step 2: Run the focused test and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderRemoteServiceTests
```

Expected: compile failures because mutation access and writable client provider
do not exist.

- [ ] **Step 3: Define the path-based mutation access**

```swift
protocol FileProviderRemoteMutationAccess: Sendable {
    func item(at path: FileProviderRemotePath) async throws -> FileProviderRemoteItem
    func list(directory: FileProviderRemotePath) async throws -> [FileProviderRemoteItem]
    func createDirectory(at path: FileProviderRemotePath) async throws
    func uploadFile(
        from localURL: URL,
        to path: FileProviderRemotePath,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws
    func renameItem(
        from source: FileProviderRemotePath,
        to destination: FileProviderRemotePath
    ) async throws
    func removeFile(at path: FileProviderRemotePath) async throws
    func removeEmptyDirectory(at path: FileProviderRemotePath) async throws
}

protocol FileProviderRemoteServicing: Sendable {
    // retain item, list, fetch, invalidate
    func withMutationAccess<Value: Sendable>(
        _ operation: @Sendable (
            any FileProviderRemoteMutationAccess
        ) async throws -> Value
    ) async throws -> Value
}
```

- [ ] **Step 4: Implement one authenticated lease and canonical containment**

`withMutationAccess` loads the server and credential once, opens one combined
read/write SFTP client, resolves `realPath(".")` once, and passes a
`FileProviderRemoteMutationSession`.

For every existing parent, resolve `realPath` and call
`FileProviderSafeLinkResolver.ensureContained`. Validate destination leaf names
with the existing child-name rules. Use link-aware metadata for the final source
component so a symlink is never silently followed by a mutation.

Update every existing `FileProviderRemoteServicing` test fake in
`RemuxFileProviderContractTests.swift` with a `withMutationAccess` implementation
that records an unexpected invocation and throws its existing fixture error.
This keeps Task 4 compiling while proving read-only lookup/fetch tests never
open mutation access.

- [ ] **Step 5: Run tests and verify GREEN**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderRemoteServiceTests
```

Expected: all existing read-service tests and the mutation-session containment,
single-lease, cancellation, and path tests pass.

- [ ] **Step 6: Commit**

```bash
git add RemuxApp/Sources/FileProvider/FileProviderRemoteService.swift \
  RemuxApp/Sources/FileProvider/FileProviderCitadelSFTPClientProvider.swift \
  RemuxAppTests/FileProviderRemoteServiceTests.swift \
  RemuxAppTests/RemuxFileProviderContractTests.swift
git commit -m "Add contained File Provider mutation sessions"
```

---

### Task 5: One coordinator for polling and mutations

**Files:**
- Create: `RemuxApp/Sources/FileProvider/FileProviderDomainOperationCoordinator.swift`
- Create: `RemuxAppTests/FileProviderDomainOperationCoordinatorTests.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderEnumeratorCore.swift`
- Modify: `RemuxFileProvider/Sources/RemuxFileProviderExtension.swift`
- Delete: `RemuxApp/Sources/FileProvider/FileProviderPollingCoordinator.swift`
- Modify: `RemuxAppTests/RemuxFileProviderContractTests.swift`

**Interfaces:**
- Produces: `FileProviderDomainOperationCoordinator.performRefresh`
- Produces: `FileProviderDomainOperationCoordinator.performMutation`
- Consumes: snapshot-recording refresh closure and mutation closure

- [ ] **Step 1: Write failing ordering and cancellation tests**

```swift
func testMutationWaitsForRefreshAndNextRefreshWaitsForMutation() async throws {
    let coordinator = FileProviderDomainOperationCoordinator()
    let events = FileProviderTestEventRecorder()
    let refreshGate = FileProviderBlockingGate()
    let mutationGate = FileProviderBlockingGate()

    let firstRefresh = Task {
        try await coordinator.performRefresh(directory: .root) {
            await events.record("refresh-1-start")
            await refreshGate.wait()
            await events.record("refresh-1-end")
            return 1
        }
    }
    await refreshGate.waitUntilEntered()
    let mutation = Task {
        try await coordinator.performMutation {
            await events.record("mutation-start")
            await mutationGate.wait()
            await events.record("mutation-end")
            return 2
        }
    }
    let secondRefresh = Task {
        try await coordinator.performRefresh(directory: .root) {
            await events.record("refresh-2")
            return 3
        }
    }

    await refreshGate.release()
    await mutationGate.waitUntilEntered()
    XCTAssertEqual(await events.values(), ["refresh-1-start", "refresh-1-end", "mutation-start"])
    await mutationGate.release()
    _ = try await (firstRefresh.value, mutation.value, secondRefresh.value)
    XCTAssertEqual(
        await events.values(),
        ["refresh-1-start", "refresh-1-end", "mutation-start", "mutation-end", "refresh-2"]
    )
}
```

Define the new test file's synchronization helpers directly:

```swift
private actor FileProviderTestEventRecorder {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func values() -> [String] {
        events
    }
}

private actor FileProviderBlockingGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
```

Add tests that same-directory refreshes coalesce, different-directory refreshes
queue, a cancelled waiter detaches promptly, and cancelling the last active
waiter cancels its operation.

- [ ] **Step 2: Run coordinator tests and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderDomainOperationCoordinatorTests
```

Expected: compile failure because the coordinator does not exist.

- [ ] **Step 3: Implement the cancellable actor**

```swift
actor FileProviderDomainOperationCoordinator {
    func performRefresh(
        directory: FileProviderRemotePath,
        operation: @escaping @Sendable () async throws -> FileProviderPollingRefresh
    ) async throws -> FileProviderPollingRefresh

    func performMutation<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value
}
```

Reuse the existing continuation-based cancellation design, but represent an
active operation as either `.refresh(directory:)` or `.mutation`. Only matching
directory refreshes coalesce, using the concrete `FileProviderPollingRefresh`
result type without type erasure. Mutations never coalesce and have FIFO turns.
Once a mutation is queued, later refreshes queue behind it instead of joining an
older active refresh. Remove a cancelled queued continuation immediately.

- [ ] **Step 4: Route enumeration through the new coordinator**

Replace `FileProviderPollingCoordinator` in setup and enumerator core with
`FileProviderDomainOperationCoordinator`. Keep list-plus-snapshot-record inside
the refresh closure so no waiter can publish independently.

- [ ] **Step 5: Run focused and contract tests**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderDomainOperationCoordinatorTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests
```

Expected: all selected tests pass and no source references
`FileProviderPollingCoordinator`.

- [ ] **Step 6: Commit**

```bash
git status --short
git add RemuxApp/Sources/FileProvider/FileProviderDomainOperationCoordinator.swift \
  RemuxApp/Sources/FileProvider/FileProviderEnumeratorCore.swift \
  RemuxFileProvider/Sources/RemuxFileProviderExtension.swift \
  RemuxAppTests/FileProviderDomainOperationCoordinatorTests.swift \
  RemuxAppTests/RemuxFileProviderContractTests.swift
git add -u RemuxApp/Sources/FileProvider/FileProviderPollingCoordinator.swift
git commit -m "Serialize File Provider refreshes and mutations"
```

---

### Task 6: Structured requests, capabilities, validation, and writable errors

**Files:**
- Create: `RemuxApp/Sources/FileProvider/FileProviderMutationRequest.swift`
- Create: `RemuxApp/Sources/FileProvider/FileProviderMutationValidator.swift`
- Create: `RemuxApp/Sources/FileProvider/FileProviderSDKItem.swift`
- Create: `RemuxAppTests/FileProviderMutationValidatorTests.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderItemProjection.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderErrorMapper.swift`
- Modify: `RemuxAppTests/FileProviderRemoteItemTests.swift`
- Modify: `RemuxAppTests/FileProviderErrorMapperTests.swift`
- Delete: `RemuxApp/Sources/FileProvider/FileProviderReadOnlyMutationPolicy.swift`
- Delete: `RemuxFileProvider/Sources/RemuxFileProviderItem.swift`
- Modify: `RemuxFileProvider/Sources/RemuxFileProviderExtension.swift`
- Modify: `RemuxAppTests/RemuxFileProviderContractTests.swift`

**Interfaces:**
- Produces: create, modify, and delete request value types
- Produces: `FileProviderMutationValidator`
- Produces: exact capability projection by item type
- Produces: collision, conflict, deletion-rejected, directory-not-empty, write-permission, and cannot-synchronize errors

- [ ] **Step 1: Write failing capability and field-partition tests**

```swift
func testCapabilitiesMatchWritableTypePolicy() throws {
    XCTAssertEqual(
        projection(path: .root, type: .directory).capabilities,
        [.allowsReading, .allowsWriting, .allowsContentEnumerating, .allowsAddingSubItems]
    )
    XCTAssertEqual(
        projection(path: "folder", type: .directory).capabilities,
        [
            .allowsReading, .allowsWriting, .allowsContentEnumerating,
            .allowsAddingSubItems, .allowsRenaming, .allowsReparenting,
            .allowsDeleting,
        ]
    )
    XCTAssertEqual(
        projection(path: "file.txt", type: .regular).capabilities,
        [
            .allowsReading, .allowsWriting, .allowsRenaming,
            .allowsReparenting, .allowsDeleting,
        ]
    )
    XCTAssertEqual(
        projection(path: "link", type: .symbolicLink).capabilities,
        [.allowsReading]
    )
}

func testModifyFieldsPartitionSupportedAndPendingMetadata() {
    let partition = FileProviderMutationFieldPartition(
        changedFields: [
            .contents, .filename, .parentItemIdentifier,
            .tagData, .extendedAttributes,
        ]
    )

    XCTAssertEqual(
        partition.supported,
        [.contents, .filename, .parentItemIdentifier]
    )
    XCTAssertEqual(
        partition.stillPending,
        [.tagData, .extendedAttributes]
    )
}
```

Add local projection helpers so the tests exercise production projection:

```swift
private func projection(
    path: String,
    type: RemuxSFTPFileType
) throws -> FileProviderItemProjection {
    let remote = try item(
        path: FileProviderRemotePath(relative: path),
        type: type
    )
    return FileProviderItemProjection(
        item: FileProviderIdentifiedItem(
            identity: .item(UUID()),
            remoteItem: remote
        ),
        rootDisplayName: "Fixture"
    )
}

private func projection(
    path: FileProviderRemotePath,
    type: RemuxSFTPFileType
) throws -> FileProviderItemProjection {
    let remote = try item(path: path, type: type)
    return FileProviderItemProjection(
        item: FileProviderIdentifiedItem(
            identity: path == .root ? .root : .item(UUID()),
            remoteItem: remote
        ),
        rootDisplayName: "Fixture"
    )
}
```

- [ ] **Step 2: Write failing conflict, collision, type, and cycle tests**

```swift
func testValidatorRejectsRemoteVersionConflictWithoutChangingRemote() throws {
    let requestedItem = try identifiedItem(size: 1)
    let currentItem = try identifiedItem(size: 2)
    let result = validator.validateBaseVersion(
        requested: version(for: requestedItem),
        current: currentItem
    )

    XCTAssertEqual(result, .conflict(current: currentItem))
}

func testValidatorRejectsDirectoryMoveIntoDescendant() throws {
    XCTAssertThrowsError(
        try validator.validateMove(
            source: FileProviderRemotePath(relative: "folder"),
            destination: FileProviderRemotePath(relative: "folder/child/folder"),
            sourceType: .directory
        )
    ) { error in
        XCTAssertEqual(error as? FileProviderMutationValidationError, .directoryCycle)
    }
}
```

Define the validator result and test helpers explicitly:

```swift
enum FileProviderBaseVersionValidation: Equatable, Sendable {
    case matches
    case conflict(current: FileProviderIdentifiedItem)
}

private let validator = FileProviderMutationValidator()

private func identifiedItem(
    path: String = "report.txt",
    size: UInt64
) throws -> FileProviderIdentifiedItem {
    FileProviderIdentifiedItem(
        identity: .item(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!),
        remoteItem: try FileProviderRemoteItem(
            path: FileProviderRemotePath(relative: path),
            metadata: RemuxSFTPFileMetadata(
                size: size,
                permissions: 0o100644,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(size)),
                type: .regular
            )
        )
    )
}

private func version(
    for item: FileProviderIdentifiedItem
) -> NSFileProviderItemVersion {
    NSFileProviderItemVersion(
        contentVersion: item.remoteItem.contentVersion,
        metadataVersion: item.remoteItem.metadataVersion
    )
}
```

Also cover exact and case-insensitive occupied destinations, unsupported special
file, every symlink mutation, invalid child name, missing parent, root mutation,
and content supplied for a directory.

- [ ] **Step 3: Run validator and mapper tests and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationValidatorTests \
  -only-testing:RemuxTests/FileProviderRemoteItemTests \
  -only-testing:RemuxTests/FileProviderErrorMapperTests
```

Expected: compile failures for request, field partition, validator, writable
capabilities, and errors.

- [ ] **Step 4: Add exact structured request types**

```swift
struct FileProviderCreateRequest: @unchecked Sendable {
    let templateIdentifier: NSFileProviderItemIdentifier
    let parentIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let type: RemuxSFTPFileType
    let fields: NSFileProviderItemFields
    let contentsURL: URL?
    let options: NSFileProviderCreateItemOptions
}

struct FileProviderModifyRequest: @unchecked Sendable {
    let identifier: NSFileProviderItemIdentifier
    let parentIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let baseVersion: NSFileProviderItemVersion
    let changedFields: NSFileProviderItemFields
    let contentsURL: URL?
    let options: NSFileProviderModifyItemOptions
}

struct FileProviderDeleteRequest: @unchecked Sendable {
    let identifier: NSFileProviderItemIdentifier
    let baseVersion: NSFileProviderItemVersion
    let options: NSFileProviderDeleteItemOptions
}

struct FileProviderMutationFieldPartition: Equatable {
    let supported: NSFileProviderItemFields
    let stillPending: NSFileProviderItemFields
}
```

The supported set is exactly `.contents`, `.filename`, and
`.parentItemIdentifier`.

- [ ] **Step 5: Implement pure validation and precise errors**

`FileProviderMutationValidator` validates item type, root/symlink policy, base
versions, case-insensitive destination collision, child name, and move cycles
without performing network I/O.

Add mapper constructors:

```swift
static func filenameCollision(existingItem: FileProviderSDKItem) -> NSError
static func deletionRejected(updatedItem: FileProviderSDKItem) -> NSError
static var directoryNotEmpty: NSError
static var cannotSynchronize: NSError
static var writePermission: NSError
```

Move the existing `RemuxFileProviderItem` adapter into shared provider code as
`FileProviderSDKItem`. Use the public
`NSError.fileProviderErrorForCollision(with:)` and
`NSError.fileProviderErrorForRejectedDeletion(of:)` constructors so both errors
carry the required item. Update extension references to the shared adapter.
Remove the extension-only adapter, read-only mutation policy, and its test.

- [ ] **Step 6: Run tests and verify GREEN**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationValidatorTests \
  -only-testing:RemuxTests/FileProviderRemoteItemTests \
  -only-testing:RemuxTests/FileProviderErrorMapperTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests
```

Expected: all selected tests pass and no source references
`FileProviderReadOnlyMutationPolicy`.

- [ ] **Step 7: Commit**

```bash
git status --short
git add RemuxApp/Sources/FileProvider/FileProviderMutationRequest.swift \
  RemuxApp/Sources/FileProvider/FileProviderMutationValidator.swift \
  RemuxApp/Sources/FileProvider/FileProviderSDKItem.swift \
  RemuxApp/Sources/FileProvider/FileProviderItemProjection.swift \
  RemuxApp/Sources/FileProvider/FileProviderErrorMapper.swift \
  RemuxAppTests/FileProviderMutationValidatorTests.swift \
  RemuxAppTests/FileProviderRemoteItemTests.swift \
  RemuxAppTests/FileProviderErrorMapperTests.swift \
  RemuxAppTests/RemuxFileProviderContractTests.swift \
  RemuxFileProvider/Sources/RemuxFileProviderExtension.swift
git add -u RemuxApp/Sources/FileProvider/FileProviderReadOnlyMutationPolicy.swift \
  RemuxFileProvider/Sources/RemuxFileProviderItem.swift
git commit -m "Define writable File Provider contracts"
```

---

### Task 7: File and directory creation

**Files:**
- Create: `RemuxApp/Sources/FileProvider/FileProviderMutationCore.swift`
- Create: `RemuxAppTests/FileProviderMutationCoreTests.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderReplicatedExtensionCore.swift`

**Interfaces:**
- Produces: `FileProviderMutationResult`
- Produces: `FileProviderMutationCore.create(request:progress:)`
- Produces: `finishCommittedMutation(_:)`
- Consumes: mutation access, domain coordinator, validator, snapshots, and receipt APIs

Add a deterministic test fixture with this exact interface:

```swift
private final class MutationFixture {
    let core: FileProviderMutationCore
    let snapshots: FileProviderSnapshotStore
    let remote: FileProviderMutableRemoteService
    let progress: FileProviderTestProgressRecorder
    let nonce = "11111111-2222-3333-4444-555555555555"

    init() throws
    static func withFile(
        path: String,
        contents: Data = Data("contents".utf8)
    ) async throws -> MutationFixture
    static func withEmptyDirectory(path: String) async throws -> MutationFixture
    static func withDirectory(
        path: String,
        children: [String]
    ) async throws -> MutationFixture

    func localFile(contents: Data) -> URL
    func createRequest(
        template: String,
        parent: NSFileProviderItemIdentifier,
        filename: String,
        type: RemuxSFTPFileType,
        contentsURL: URL?
    ) -> FileProviderCreateRequest
    func modifyRequest(
        item: FileProviderIdentifiedItem,
        parent: NSFileProviderItemIdentifier? = nil,
        filename: String? = nil,
        contentsURL: URL? = nil,
        changedFields: NSFileProviderItemFields
    ) -> FileProviderModifyRequest
    func deleteRequest(
        item: FileProviderIdentifiedItem,
        options: NSFileProviderDeleteItemOptions = []
    ) -> FileProviderDeleteRequest
    func identifiedItem(path: String) async throws -> FileProviderIdentifiedItem
    func identifier(path: String) async throws -> NSFileProviderItemIdentifier
}

private actor FileProviderTestProgressRecorder {
    private var reportedBytes: [Int64] = []

    func record(_ bytes: Int64) {
        reportedBytes.append(bytes)
    }

    func values() -> [Int64] {
        reportedBytes
    }
}

private actor FileProviderMutableRemoteService: FileProviderRemoteServicing {
    enum Mutation: Equatable {
        case mkdir(String)
        case upload(URL, String)
        case rename(String, String)
        case removeFile(String)
        case rmdir(String)
    }

    func mutations() -> [Mutation]
    func listedPaths() -> [String]
    func contents(path: String) -> Data?
    func exists(_ absolutePath: String) -> Bool
}
```

`FileProviderMutableRemoteService` is an actor-backed fake implementing
`FileProviderRemoteServicing`. Store entries in
`[FileProviderRemotePath: (metadata: RemuxSFTPFileMetadata, contents: Data)]`;
record the exact structured mutation enum used in assertions; apply rename to
descendants when its source is a directory; expose deterministic gates for
upload, rename, and removal; and reject non-empty `rmdir`. It must not interpret
shell commands or serialized SFTP packets.

- [ ] **Step 1: Write failing create-file and create-directory tests**

```swift
func testCreateFileUploadsTemporarySiblingThenRenamesAndCommitsReceipt() async throws {
    let fixture = try MutationFixture()
    let localURL = fixture.localFile(contents: Data("hello".utf8))
    let request = fixture.createRequest(
        template: "template-1",
        parent: .rootContainer,
        filename: "report.txt",
        type: .regular,
        contentsURL: localURL
    )

    let result = try await fixture.core.create(request: request) { bytes in
        await fixture.progress.record(bytes)
    }

    XCTAssertEqual(await fixture.remote.mutations(), [
        .upload(localURL, "/home/me/.remux-upload-\(fixture.nonce)"),
        .rename(
            "/home/me/.remux-upload-\(fixture.nonce)",
            "/home/me/report.txt"
        ),
    ])
    XCTAssertEqual(result.item.remoteItem.path.relative, "report.txt")
    XCTAssertEqual(
        try await fixture.snapshots.receipt(
            for: .create(templateIdentifier: "template-1")
        ),
        .item(
            key: .create(templateIdentifier: "template-1"),
            item: result.item
        )
    )
}

func testCreateDirectoryUsesStrictMkdirAndReturnsAuthoritativeItem() async throws {
    let fixture = try MutationFixture()

    let result = try await fixture.core.create(
        request: fixture.createRequest(
            template: "template-dir",
            parent: .rootContainer,
            filename: "notes",
            type: .directory,
            contentsURL: nil
        )
    ) { _ in }

    XCTAssertEqual(await fixture.remote.mutations(), [.mkdir("/home/me/notes")])
    XCTAssertEqual(result.item.remoteItem.type, .directory)
}
```

- [ ] **Step 2: Write failing collision, empty-file, replay, symlink, and cleanup tests**

Add concrete tests proving:

- Existing destination returns filename collision without any mutation.
- A new regular file with `contentsURL == nil` uploads a zero-byte temporary
  file.
- A matching create receipt returns the same identity without SFTP calls.
- A dataless `.mayAlreadyExist` request matches only a recorded alias/identity.
- Symlink creation returns cannot-synchronize without SFTP calls.
- Upload failure removes the temporary sibling.
- Rename failure removes the temporary sibling and leaves an existing
  destination untouched.
- Progress reports cumulative bytes and cancellation before rename never commits
  the destination.
- Cancellation after the final rename still finishes authoritative metadata,
  snapshot, and receipt persistence and returns the committed item.

- [ ] **Step 3: Run mutation-core tests and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests
```

Expected: compile failures because `FileProviderMutationCore` and its result do
not exist.

- [ ] **Step 4: Implement create through one serialized mutation**

```swift
struct FileProviderMutationResult: Sendable {
    let item: FileProviderIdentifiedItem
    let stillPendingFields: NSFileProviderItemFields
    let shouldFetchContent: Bool
}

actor FileProviderMutationCore {
    func create(
        request: FileProviderCreateRequest,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> FileProviderMutationResult
}

private func finishCommittedMutation<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await Task.detached(operation: operation).value
}
```

The method:

1. Checks the create replay receipt.
2. Enters `coordinator.performMutation`.
3. Resolves the parent identifier through snapshots.
4. Validates type, fields, name, parent, and collision against a fresh listing.
5. Reserves a new identity and template alias.
6. Uses the injected nonce to form `.remux-upload-` followed by the lowercase
   UUID. The temporary name does not include the requested filename, so a
   maximum-length destination name cannot overflow the server's component limit.
7. Uploads then renames, or calls strict mkdir.
8. Reads the authoritative item and parent listing.
9. Uses `finishCommittedMutation` after the final rename or successful mkdir to
   read authoritative state and commit identity reservation, snapshot, and
   receipt even if the request task becomes cancelled.
10. Returns the identified item and unsupported pending fields.

On every pre-rename failure, best-effort remove only the exact temporary path
created by this request.

- [ ] **Step 5: Route extension-core creation to the mutation core**

Add:

```swift
func createItem(
    request: FileProviderCreateRequest,
    completion: @escaping @Sendable (
        Result<FileProviderMutationResult, NSError>
    ) -> Void
) -> Progress
```

Use `FileProviderRequestController.perform(progressOperation:)` and translate
uploaded bytes into `Progress.completedUnitCount`. Do not yet change the SDK
adapter; that occurs after modify and delete are complete.

- [ ] **Step 6: Run tests and verify GREEN**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests
```

Expected: all create, replay, collision, cleanup, progress, and cancellation
tests pass.

- [ ] **Step 7: Commit**

```bash
git add RemuxApp/Sources/FileProvider/FileProviderMutationCore.swift \
  RemuxApp/Sources/FileProvider/FileProviderReplicatedExtensionCore.swift \
  RemuxAppTests/FileProviderMutationCoreTests.swift \
  RemuxAppTests/RemuxFileProviderContractTests.swift
git commit -m "Create files and directories through File Provider"
```

---

### Task 8: Rename and move without contents

**Files:**
- Modify: `RemuxApp/Sources/FileProvider/FileProviderMutationCore.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift`
- Test: `RemuxAppTests/FileProviderMutationCoreTests.swift`
- Test: `RemuxAppTests/FileProviderSnapshotStoreTests.swift`

**Interfaces:**
- Produces: `FileProviderMutationCore.modify(request:progress:)`
- Consumes: stable relocation transaction and validation APIs

- [ ] **Step 1: Write failing file rename and cross-parent move tests**

```swift
func testRenameRetainsIdentityAndRefreshesParent() async throws {
    let fixture = try await MutationFixture.withFile(path: "old.txt")
    let original = try await fixture.identifiedItem(path: "old.txt")

    let result = try await fixture.core.modify(
        request: fixture.modifyRequest(
            item: original,
            filename: "new.txt",
            changedFields: [.filename]
        )
    ) { _ in }

    XCTAssertEqual(result.item.identity, original.identity)
    XCTAssertEqual(result.item.remoteItem.path.relative, "new.txt")
    XCTAssertEqual(await fixture.remote.mutations(), [
        .rename("/home/me/old.txt", "/home/me/new.txt"),
    ])
}

func testMoveRefreshesOldAndNewParentsAndRetainsIdentity() async throws {
    let fixture = try await MutationFixture.withFile(path: "from/report.txt")
    let original = try await fixture.identifiedItem(path: "from/report.txt")

    let result = try await fixture.core.modify(
        request: fixture.modifyRequest(
            item: original,
            parent: try await fixture.identifier(path: "to"),
            changedFields: [.parentItemIdentifier]
        )
    ) { _ in }

    XCTAssertEqual(result.item.identity, original.identity)
    XCTAssertEqual(result.item.remoteItem.path.relative, "to/report.txt")
    XCTAssertEqual(await fixture.remote.listedPaths(), ["/home/me/from", "/home/me/to"])
}
```

- [ ] **Step 2: Add failing directory subtree, cycle, collision, and conflict tests**

Prove that:

- Moving a known directory preserves identities for every known descendant.
- Moving a directory into its descendant makes no SFTP call.
- Occupied destination makes no SFTP call and returns filename collision.
- A changed remote base version makes no SFTP call and returns the current
  remote item.
- Root and symlink rename/move fail.
- A receipt replay returns the moved item without a second rename.
- Unsupported metadata fields alone return the current item and the exact
  `stillPendingFields`.

- [ ] **Step 3: Run mutation tests and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests
```

Expected: modify is absent or does not retain stable identities and relocated
descendants.

- [ ] **Step 4: Implement metadata-only supported moves**

`modify` checks its receipt, partitions fields, resolves current source and
destination parent, rereads the source and both parent listings, validates base
version/collision/cycle/type, performs one SFTP rename, reads authoritative
metadata, and commits:

```swift
FileProviderSnapshotLocalMutation(
    refreshedDirectories: oldAndNewParentListings,
    relocations: [
        .init(identity: source.identity, from: oldPath, to: newPath),
    ],
    receipt: .item(key: replayKey, item: moved)
)
```

If old and new parents are equal, record that directory once. Relocate every
known descendant path when the source is a directory.

- [ ] **Step 5: Run tests and verify GREEN**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests
```

Expected: all location, identity, snapshot, conflict, collision, cycle, replay,
and pending-field tests pass.

- [ ] **Step 6: Commit**

```bash
git add RemuxApp/Sources/FileProvider/FileProviderMutationCore.swift \
  RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift \
  RemuxAppTests/FileProviderMutationCoreTests.swift \
  RemuxAppTests/FileProviderSnapshotStoreTests.swift
git commit -m "Rename and move File Provider items"
```

---

### Task 9: Safe regular-file content replacement

**Files:**
- Modify: `RemuxApp/Sources/FileProvider/FileProviderMutationCore.swift`
- Test: `RemuxAppTests/FileProviderMutationCoreTests.swift`
- Test: `RemuxAppTests/RemuxFileProviderContractTests.swift`

**Interfaces:**
- Extends: `FileProviderMutationCore.modify(request:progress:)`
- Guarantees: no in-place truncation and no delete-then-rename fallback

- [ ] **Step 1: Write failing content replacement test**

```swift
func testModifyContentsUploadsTemporaryFileThenReplacesDestination() async throws {
    let fixture = try await MutationFixture.withFile(
        path: "report.txt",
        contents: Data("old".utf8)
    )
    let original = try await fixture.identifiedItem(path: "report.txt")
    let localURL = fixture.localFile(contents: Data("new".utf8))

    let result = try await fixture.core.modify(
        request: fixture.modifyRequest(
            item: original,
            contentsURL: localURL,
            changedFields: [.contents]
        )
    ) { bytes in
        await fixture.progress.record(bytes)
    }

    XCTAssertEqual(await fixture.remote.mutations(), [
        .upload(localURL, "/home/me/.remux-upload-\(fixture.nonce)"),
        .rename(
            "/home/me/.remux-upload-\(fixture.nonce)",
            "/home/me/report.txt"
        ),
    ])
    XCTAssertEqual(result.item.identity, original.identity)
    XCTAssertEqual(await fixture.remote.contents(path: "/home/me/report.txt"), Data("new".utf8))
}
```

- [ ] **Step 2: Add failing safety and combined-change tests**

Add tests proving:

- Replacement rename refusal leaves the old destination contents unchanged and
  never calls remove on it.
- Upload failure and precommit cancellation clean the exact temporary file.
- Cancellation after the final rename returns committed success, not
  `NSUserCancelledError`.
- Content plus filename commits the new bytes under the new extension in one
  operation.
- Content plus cross-parent move commits the destination before removing the old
  source.
- Failure before destination commit keeps the old source.
- Failure removing an old source after a cross-path content commit returns the
  committed destination as success, retains both paths, assigns the retained
  old path a new identity, and queues one working-set signal; it never deletes
  the committed destination.
- Remote base-version mismatch preserves the remote contents.
- Directory and symlink content changes make no upload call.
- Receipt replay makes no second upload.

- [ ] **Step 3: Run focused tests and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests
```

Expected: content replacement paths are absent or violate at least one safety
assertion.

- [ ] **Step 4: Implement temporary upload and commit boundary**

Inside the already serialized `modify` turn:

1. Validate live base version and destination before upload.
2. Upload to the nonce-based temporary destination sibling.
3. Recheck cancellation before final rename.
4. Rename temporary to final without deleting the existing destination.
5. Treat successful final rename as the remote commit boundary.
6. For a changed path, remove the old source only after commit.
7. Read authoritative destination metadata and affected parent listings.
8. Atomically commit identity relocation, snapshots, and receipt.
9. If cancellation arrives after step 4, finish the committed result.

If step 6 cannot remove the old source, record both authoritative parent
listings with `queuesWorkingSetSignal: true`, retain the original identity at
the committed destination, allocate a new identity for the retained old path,
and return the committed destination as success.

Do not add `NSExtensionFileProviderAppliesChangesAtomically`.

- [ ] **Step 5: Run focused tests and verify GREEN**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests
```

Expected: all content, progress, cancellation, combined-location, conflict,
cleanup, replay, and old-destination preservation tests pass.

- [ ] **Step 6: Commit**

```bash
git add RemuxApp/Sources/FileProvider/FileProviderMutationCore.swift \
  RemuxAppTests/FileProviderMutationCoreTests.swift \
  RemuxAppTests/RemuxFileProviderContractTests.swift
git commit -m "Safely replace File Provider file contents"
```

---

### Task 10: File and empty-directory deletion

**Files:**
- Modify: `RemuxApp/Sources/FileProvider/FileProviderMutationCore.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift`
- Test: `RemuxAppTests/FileProviderMutationCoreTests.swift`
- Test: `RemuxAppTests/FileProviderSnapshotStoreTests.swift`

**Interfaces:**
- Produces: `FileProviderMutationCore.delete(request:)`
- Guarantees: no recursive or partial directory deletion

- [ ] **Step 1: Write failing regular-file and empty-directory deletion tests**

```swift
func testDeleteRegularFileRemovesOneFileAndCommitsReceipt() async throws {
    let fixture = try await MutationFixture.withFile(path: "report.txt")
    let item = try await fixture.identifiedItem(path: "report.txt")

    try await fixture.core.delete(
        request: fixture.deleteRequest(item: item)
    )

    XCTAssertEqual(await fixture.remote.mutations(), [
        .removeFile("/home/me/report.txt"),
    ])
    XCTAssertNil(try await fixture.snapshots.item(for: item.itemIdentifier))
}

func testDeleteEmptyDirectoryListsThenUsesRmdir() async throws {
    let fixture = try await MutationFixture.withEmptyDirectory(path: "empty")
    let item = try await fixture.identifiedItem(path: "empty")

    try await fixture.core.delete(
        request: fixture.deleteRequest(item: item)
    )

    XCTAssertEqual(await fixture.remote.mutations(), [
        .rmdir("/home/me/empty"),
    ])
}
```

- [ ] **Step 2: Write failing non-empty and idempotency tests**

```swift
func testRecursiveOptionStillRejectsNonEmptyDirectoryWithoutRemovingChildren() async throws {
    let fixture = try await MutationFixture.withDirectory(
        path: "folder",
        children: ["child.txt"]
    )
    let item = try await fixture.identifiedItem(path: "folder")

    await XCTAssertThrowsErrorAsync(
        try await fixture.core.delete(
            request: fixture.deleteRequest(item: item, options: [.recursive])
        )
    ) { error in
        XCTAssertEqual(
            (error as NSError).code,
            NSFileProviderError.directoryNotEmpty.rawValue
        )
    }

    XCTAssertTrue(await fixture.remote.exists("/home/me/folder"))
    XCTAssertTrue(await fixture.remote.exists("/home/me/folder/child.txt"))
    XCTAssertTrue(await fixture.remote.mutations().isEmpty)
}
```

Also test already-absent success, stale-base deletion rejection, root and symlink
rejection, permission denial, receipt replay, and snapshot descendant pruning
after a confirmed empty-directory deletion.

- [ ] **Step 3: Run deletion tests and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests
```

Expected: delete is absent or non-empty directory behavior is not enforced.

- [ ] **Step 4: Implement idempotent non-recursive deletion**

Inside `coordinator.performMutation`:

1. Return an existing delete receipt immediately.
2. Resolve the identity and current path.
3. Treat an already missing item as successful and commit the deleted receipt.
4. Reject root/symlink/unsupported types.
5. Compare the fresh remote version with `baseVersion`.
6. For a directory, list immediately before deletion and return
   directory-not-empty if the listing is non-empty, regardless of options.
7. Call `removeFile` or `removeEmptyDirectory`.
8. Treat successful remove or `rmdir` as the remote commit boundary.
9. Use `finishCommittedMutation` to refresh the parent, delete the identity,
   prune tracked descendants, and commit the delete receipt in one snapshot
   save even if cancellation arrives after step 8.

- [ ] **Step 5: Run tests and verify GREEN**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests
```

Expected: file, empty-directory, non-empty, recursive-option, conflict,
idempotency, replay, permission, and pruning tests pass.

- [ ] **Step 6: Commit**

```bash
git add RemuxApp/Sources/FileProvider/FileProviderMutationCore.swift \
  RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift \
  RemuxAppTests/FileProviderMutationCoreTests.swift \
  RemuxAppTests/FileProviderSnapshotStoreTests.swift
git commit -m "Delete files and only empty directories"
```

---

### Task 11: SDK mutation callbacks and lifecycle

**Files:**
- Modify: `RemuxFileProvider/Sources/RemuxFileProviderExtension.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderSDKItem.swift`
- Modify: `RemuxApp/Sources/FileProvider/FileProviderReplicatedExtensionCore.swift`
- Modify: `RemuxAppTests/RemuxFileProviderContractTests.swift`

**Interfaces:**
- Consumes: structured mutation requests and mutation-core APIs
- Produces: working SDK `createItem`, `modifyItem`, and `deleteItem` callbacks

- [ ] **Step 1: Write failing adapter-shaping tests**

Add pure adapter tests that construct a test `NSFileProviderItem` and assert:

```swift
let request = try FileProviderSDKRequestAdapter.createRequest(
    itemTemplate: template,
    fields: [.filename, .contents],
    contentsURL: localURL,
    options: [.mayAlreadyExist]
)

XCTAssertEqual(request.parentIdentifier, template.parentItemIdentifier)
XCTAssertEqual(request.filename, template.filename)
XCTAssertEqual(request.type, .regular)
XCTAssertEqual(request.templateIdentifier, template.itemIdentifier)
XCTAssertEqual(request.contentsURL, localURL)
```

Cover directory type mapping, unsupported special types, modify field
preservation, and delete options.

- [ ] **Step 2: Write failing exactly-once lifecycle tests**

Add tests proving:

- Create, modify, and delete success each complete once.
- Every mapped failure completes once with no item.
- Progress cancellation before commit completes with `NSUserCancelledError`.
- Cancellation after commit returns the committed result.
- Extension invalidation cancels queued mutations, waits for active mutation
  cleanup, invalidates enumerators, and only then closes the remote service.
- A request started after invalidation never reaches the mutation core.

- [ ] **Step 3: Run contract tests and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxFileProviderContractTests
```

Expected: SDK adapter and mutation callback assertions fail.

- [ ] **Step 4: Add a testable SDK request adapter**

Define `FileProviderSDKRequestAdapter` in
`RemuxFileProviderExtension.swift` with static create/modify/delete conversion
methods. Determine the remote type from `contentType`:

- `.folder` becomes `.directory`.
- `.symbolicLink` is rejected.
- Other regular data types become `.regular`.

Do not copy tag, permission, extended-attribute, or other unsupported metadata
into the core request.

- [ ] **Step 5: Replace mutation rejection callbacks**

Each SDK callback converts its request, calls the corresponding extension-core
method, projects the returned identified item, and returns:

```swift
completionHandler(
    FileProviderSDKItem(item: result.item, rootDisplayName: domain.displayName),
    result.stillPendingFields,
    result.shouldFetchContent,
    nil
)
```

Delete returns only the mapped error. The returned `Progress` is the exact
request-controller progress. No callback launches an untracked `Task`.

- [ ] **Step 6: Drain mutation work during invalidation**

Use the same `FileProviderRequestController` for item lookup, fetch, create,
modify, and delete. Preserve the existing ordering:

1. Mark the core invalidated.
2. Reject new requests.
3. Invalidate registered enumerators.
4. Cancel and drain request-controller work.
5. Close the remote service.

- [ ] **Step 7: Run tests and verify GREEN**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxFileProviderContractTests \
  -only-testing:RemuxTests/FileProviderMutationCoreTests
```

Expected: all adapter, success, error, progress, cancellation, replay,
invalidation, and exactly-once tests pass.

- [ ] **Step 8: Commit**

```bash
git add RemuxFileProvider/Sources/RemuxFileProviderExtension.swift \
  RemuxApp/Sources/FileProvider/FileProviderSDKItem.swift \
  RemuxApp/Sources/FileProvider/FileProviderReplicatedExtensionCore.swift \
  RemuxAppTests/RemuxFileProviderContractTests.swift
git commit -m "Connect writable File Provider callbacks"
```

---

### Task 12: Writable extension configuration

**Files:**
- Modify: `project.yml`
- Regenerate: `RemuxFileProvider/Info.plist`
- Regenerate: `Remux.xcodeproj/project.pbxproj`
- Modify: `RemuxAppTests/FileProviderExtensionConfigurationTests.swift`

**Interfaces:**
- Produces: writable extension bundle with upload pipeline depth one
- Removes: `NSExtensionFileProviderReadOnly`

- [ ] **Step 1: Replace the built-extension read-only assertion**

```swift
func testExtensionDeclaresWritableSerialUploadPipelines() throws {
    let extensionURL = Bundle(for: Self.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("RemuxFileProvider.appex")
    let extensionBundle = try XCTUnwrap(Bundle(url: extensionURL))
    let configuration = try XCTUnwrap(
        extensionBundle.infoDictionary?["NSExtension"] as? [String: Any]
    )

    XCTAssertNil(configuration["NSExtensionFileProviderReadOnly"])
    XCTAssertEqual(
        configuration["NSExtensionFileProviderUploadPipelineDepth"] as? Int,
        1
    )
    XCTAssertEqual(
        configuration["NSExtensionFileProviderMetadataOnlyUploadPipelineDepth"] as? Int,
        1
    )
}
```

- [ ] **Step 2: Run the focused test and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderExtensionConfigurationTests
```

Expected: the built extension still contains the private read-only key and lacks
both upload-depth values.

- [ ] **Step 3: Change only authoritative XcodeGen configuration**

Under `RemuxFileProvider.info.properties.NSExtension`:

```yaml
NSExtensionFileProviderDownloadPipelineDepth: 1
NSExtensionFileProviderUploadPipelineDepth: 1
NSExtensionFileProviderMetadataOnlyUploadPipelineDepth: 1
NSExtensionFileProviderSupportsEnumeration: true
```

Delete `NSExtensionFileProviderReadOnly`.

- [ ] **Step 4: Regenerate project outputs**

```bash
xcodegen generate
git diff -- project.yml RemuxFileProvider/Info.plist Remux.xcodeproj/project.pbxproj
```

Expected: generated files contain the two upload-depth keys and no read-only
key; unrelated project structure is unchanged.

- [ ] **Step 5: Run configuration test and verify GREEN**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderExtensionConfigurationTests
```

Expected: the built-extension configuration test passes.

- [ ] **Step 6: Commit**

```bash
git add project.yml RemuxFileProvider/Info.plist \
  Remux.xcodeproj/project.pbxproj \
  RemuxAppTests/FileProviderExtensionConfigurationTests.swift
git commit -m "Configure the File Provider for writes"
```

---

### Task 13: Real SFTP mutation qualification

**Files:**
- Modify: `RemuxAppTests/RemuxSFTPReadOnlyClientTests.swift`
- Create: `scripts/qualify-writable-file-provider.sh`
- Create: `docs/superpowers/plans/2026-07-25-writable-file-provider-progress.md`

**Interfaces:**
- Consumes: combined Citadel client and writable extension bundle
- Produces: disposable-directory live evidence and a non-destructive qualification helper

- [ ] **Step 1: Add opt-in disposable-host integration tests**

Gate the tests on:

```swift
guard ProcessInfo.processInfo.environment[
    "REMUX_WRITABLE_SFTP_INTEGRATION"
] == "1" else {
    throw XCTSkip("Set REMUX_WRITABLE_SFTP_INTEGRATION=1 for disposable-host tests")
}
```

Require `REMUX_WRITABLE_SFTP_TEST_ROOT` to name an already-created empty remote
directory dedicated to the test. Refuse `/`, `.`, an empty value, a path
containing `..`, or a path with fewer than two non-empty components.

Within that exact root, exercise:

- Create directory.
- Upload/download round trip.
- Rename file.
- Rename directory.
- Replace an existing file by temporary upload plus rename.
- Remove file.
- Remove empty directory.
- Attempt non-empty `rmdir` and assert its child remains.
- Cancel a large upload and assert the old destination remains unchanged.

Cleanup names explicitly beneath the validated root. Do not call recursive
remove.

- [ ] **Step 2: Run the integration test without environment and verify safe skip**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxSFTPReadOnlyClientTests
```

Expected: normal unit tests pass and disposable-host tests report skipped.

- [ ] **Step 3: Add the non-destructive qualification helper**

The script must:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

xcodegen generate
test -z "$(git diff --name-only -- Remux.xcodeproj/project.pbxproj RemuxFileProvider/Info.plist)"
rg -q 'NSExtensionFileProviderUploadPipelineDepth' project.yml
rg -q 'NSExtensionFileProviderMetadataOnlyUploadPipelineDepth' project.yml
if rg -q 'NSExtensionFileProviderReadOnly' project.yml RemuxFileProvider/Info.plist; then
  echo "read-only File Provider key is still present" >&2
  exit 1
fi

echo "Automated configuration checks passed."
echo "Live gate: manually reset only the development simulator domain."
echo "Live gate: run Files create/edit/rename/move/delete checks in the spec."
echo "Live gate: confirm non-empty directory deletion preserves every child."
```

It must not run `simctl erase`, remove a File Provider domain, connect to SSH,
or mutate a remote path.

Mark the checked-in helper executable:

```bash
chmod +x scripts/qualify-writable-file-provider.sh
```

- [ ] **Step 4: Record exact evidence**

Create the progress file with one row per task:

```markdown
| Task | Commit | Focused tests | Review | Status |
| --- | --- | --- | --- | --- |
| 1 | pending | not run | not reviewed | pending |
```

Update each row with actual evidence as its task finishes. Add separate
unchecked manual gates for physical device and disposable host; do not report
them complete without running them.

- [ ] **Step 5: Run live disposable-host tests only with Jesse-provided scope**

```bash
test -n "${REMUX_WRITABLE_SFTP_TEST_ROOT:?Set the exact pre-created disposable remote directory}"
REMUX_WRITABLE_SFTP_INTEGRATION=1 \
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxSFTPReadOnlyClientTests
```

Expected: every mutation stays beneath the exact supplied root; non-empty
directory rejection preserves its child; no recursive cleanup occurs.

- [ ] **Step 6: Commit**

```bash
git add RemuxAppTests/RemuxSFTPReadOnlyClientTests.swift \
  scripts/qualify-writable-file-provider.sh \
  docs/superpowers/plans/2026-07-25-writable-file-provider-progress.md
git commit -m "Qualify writable SFTP behavior"
```

---

### Task 14: Full regression, simulator Files qualification, and final review

**Files:**
- Modify: `docs/superpowers/plans/2026-07-25-writable-file-provider-progress.md`

**Interfaces:**
- Consumes: Tasks 1–13
- Produces: release evidence with automated, simulator, disposable-host, and physical-device gates separated

- [ ] **Step 1: Run the focused writable-provider suite**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderRemoteItemTests \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests \
  -only-testing:RemuxTests/FileProviderDomainOperationCoordinatorTests \
  -only-testing:RemuxTests/FileProviderMutationValidatorTests \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/FileProviderRemoteServiceTests \
  -only-testing:RemuxTests/RemuxSFTPReadOnlyClientTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests \
  -only-testing:RemuxTests/FileProviderErrorMapperTests \
  -only-testing:RemuxTests/FileProviderExtensionConfigurationTests
```

Expected: all focused tests pass with zero failures.

- [ ] **Step 2: Run the complete automated suite**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

Expected: every Remux unit test passes; no pre-existing test is skipped except
the explicitly opt-in disposable-host tests.

- [ ] **Step 3: Verify generated project and built extension**

```bash
scripts/qualify-writable-file-provider.sh

derived_data=".derived-data/writable-file-provider"
xcodebuild build -project Remux.xcodeproj -scheme Remux \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_data"

appex="$derived_data/Build/Products/Debug-iphonesimulator/Remux.app/PlugIns/RemuxFileProvider.appex"
test -d "$appex"
plutil -extract NSExtension xml1 -o - "$appex/Info.plist"
codesign -d --entitlements :- "$appex"
```

Expected: the extension is embedded, has both pipeline depths set to one, lacks
the private read-only key, and retains the App Group and shared Keychain
entitlements.

- [ ] **Step 4: Reset only the development simulator domain**

Use the File Provider manager or Files development UI to remove and recreate
the Remux domain. Do not erase the simulator. Verify saved Remux profiles,
credentials, and trusted-host state remain present before continuing.

- [ ] **Step 5: Run the simulator Files matrix**

For both one password-authenticated and one private-key-authenticated server:

1. Create and reopen a text file.
2. Modify it from a document editor.
3. Rename and move it.
4. Create, rename, and move an empty directory.
5. Delete a file and an empty directory.
6. Attempt to delete a non-empty directory and verify every child remains.
7. Modify a remote file through SSH after Files materializes it, then attempt a
   stale local save and verify the remote edit is not silently overwritten.
8. Create a remote file through SSH while its parent is open and verify polling
   shows it within ten seconds.
9. Cancel a large upload and verify the previous destination remains intact.
10. Restart the extension and verify a completed request is not replayed as a
    duplicate mutation.
11. Verify symlink and metadata-only mutation paths do not succeed.

Record each result separately in the progress file. Include screenshots or log
artifact paths for failures and fixes; do not collapse the matrix into one
"manual testing passed" statement.

- [ ] **Step 6: Request task-by-task code review**

Review each task commit against its task interfaces and behavioral tests. Fix
Critical and Important findings with a failing regression test first, rerun the
focused gate, and commit each review fix separately.

- [ ] **Step 7: Run final branch review and verification**

Run:

```bash
git status --short
git log --oneline 527604b..HEAD
git diff --check 527604b..HEAD
```

Expected: clean worktree, coherent task commits, and no whitespace errors.
Then rerun Steps 1–3 after the last review fix.

- [ ] **Step 8: Update evidence and commit**

Write exact test counts, build result, simulator matrix results, disposable-host
result, open physical-device gate, and review disposition into the progress
file.

```bash
git add docs/superpowers/plans/2026-07-25-writable-file-provider-progress.md
git commit -m "Record writable File Provider verification"
```

Do not mark physical-device or disposable-host gates complete unless they were
actually run.
