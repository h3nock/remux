# Read-Only SSH File Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose each eligible saved Remux SSH server as a read-only iOS Files location that browses the remote home directory, downloads files, and discovers new remote files during an active session.

**Architecture:** The app migrates provider-relevant profiles, trust, and credentials into shared App Group and Keychain stores, then reconciles one `NSFileProviderDomain` per eligible server. A replicated File Provider extension loads the same records and opens independent timeout-bounded Citadel SFTP leases; pure path, metadata, identifier, snapshot, and error-mapping code is compiled into both targets while extension glue remains thin.

**Tech Stack:** Swift 6, iOS 18+, XcodeGen, XCTest, FileProvider, UniformTypeIdentifiers, Security, Citadel, SwiftNIO.

## Global Constraints

- The provider is read-only: never upload, create, rename, move, or delete a remote item.
- Support existing password and private-key credentials.
- Require a stored credential and already-trusted host key before registering a domain.
- The extension never accepts or changes trust and never prompts for a password.
- One domain maps to one stable `SavedServer.id` and starts at `realPath(".")`.
- Remote paths must remain beneath the canonical home root.
- Expose regular files, directories, dotfiles, and only canonical in-root symbolic links; hide sockets, devices, FIFOs, cyclic links, and escaping links.
- Active directory polling interval is five seconds; an open directory must show a new remote file within ten seconds.
- Whole-file downloads use bounded chunks, report progress, respond to cancellation, and remove partial local files.
- Snapshots and logs contain no passwords, private keys, passphrases, or file contents.
- Do not add another SSH implementation, a host-side agent, remote search, partial fetching, push invalidation, or custom File Provider UI.
- Keep the existing iOS 18.0 deployment target and pinned Citadel revision.

---

## File Map

### Shared persistence and registration

- `RemuxApp/Sources/Persistence/ApplicationStorage.swift`: legacy and App Group root resolution.
- `RemuxApp/Sources/Persistence/SSHCredentialStore.swift`: optional Keychain access-group queries.
- `RemuxApp/Sources/Persistence/TrustedHostStore.swift`: snapshot/import APIs used by migration and eligibility.
- `RemuxApp/Sources/Persistence/FileProviderSharedStorageMigrator.swift`: verified, retryable one-time migration.
- `RemuxApp/Sources/FileProvider/FileProviderDomainReconciler.swift`: pure desired-domain calculation plus live `NSFileProviderManager` adapter.

### Shared SFTP and provider model

- `RemuxApp/Sources/SSH/RemuxSFTPClient.swift`: link-aware metadata, directory entry, and download contracts.
- `RemuxApp/Sources/SSH/RemuxCitadelSFTPClient.swift`: Citadel list/realpath/download implementation.
- `RemuxApp/Sources/SSH/RemuxSSHAuthenticationMethodFactory.swift`: extension-safe construction of Citadel authentication methods.
- `RemuxApp/Sources/SSH/RemuxTransportStartupTrace.swift`: existing app trace behavior with an extension-safe no-op build path.
- `RemuxApp/Sources/SSH/RemuxSSHRootService.swift`: provider-safe root key initializer.
- `RemuxApp/Sources/FileProvider/FileProviderRemotePath.swift`: normalized in-root paths and identifier codec.
- `RemuxApp/Sources/FileProvider/FileProviderRemoteItem.swift`: remote metadata, safe-link resolution, item versions, and UTType projection.
- `RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift`: persisted bounded generations and deltas.
- `RemuxApp/Sources/FileProvider/FileProviderErrorMapper.swift`: stable File Provider/Cocoa errors.
- `RemuxApp/Sources/FileProvider/FileProviderReadOnlyMutationPolicy.swift`: tested write rejection shared by extension callbacks.
- `RemuxApp/Sources/FileProvider/FileProviderRemoteService.swift`: load domain profile/auth/trust and execute one short-lived SFTP operation.

### Extension and app integration

- `RemuxFileProvider/Sources/RemuxFileProviderItem.swift`: `NSFileProviderItem` projection.
- `RemuxFileProvider/Sources/RemuxFileProviderEnumerator.swift`: initial enumeration, changes, anchors, polling, and invalidation.
- `RemuxFileProvider/Sources/RemuxFileProviderExtension.swift`: replicated extension methods and read-only mutation failures.
- `RemuxFileProvider/Info.plist`: non-UI replicated provider declaration.
- `RemuxApp/Remux.entitlements` and `RemuxFileProvider/RemuxFileProvider.entitlements`: shared App Group and Keychain groups.
- `RemuxApp/Sources/App/RemuxAppDependencies.swift`: live shared stores, migrator, and reconciler.
- `RemuxApp/Sources/App/RemuxRootModel.swift`: migration/reconciliation lifecycle hooks.
- `project.yml` and generated `Remux.xcodeproj/project.pbxproj`: extension target, embedding, frameworks, package, and entitlements.

---

### Task 1: Shared storage roots and Keychain access groups

**Files:**
- Modify: `RemuxApp/Sources/Persistence/ApplicationStorage.swift`
- Modify: `RemuxApp/Sources/Persistence/SSHCredentialStore.swift`
- Test: `RemuxAppTests/FileProviderSharedStorageTests.swift`

**Interfaces:**
- Produces: `ApplicationStorage.sharedRemuxRoot(appGroupIdentifier:fileManager:containerURL:) throws -> URL`
- Produces: `FileProviderSharedConfiguration.keychainAccessGroup(infoDictionary:) throws -> String`
- Produces: `KeychainSSHCredentialStore.init(service:accessGroup:)`

- [ ] **Step 1: Write failing root and Keychain query tests**

```swift
final class FileProviderSharedStorageTests: XCTestCase {
    func testSharedRootAppendsRemuxToResolvedContainer() throws {
        XCTAssertEqual(
            try ApplicationStorage.sharedRemuxRoot(
                appGroupIdentifier: "group.dev.remux",
                fileManager: .default,
                containerURL: { _ in URL(fileURLWithPath: "/shared") }
            ).path,
            "/shared/Remux"
        )
    }

    func testCredentialQueryIncludesExplicitAccessGroup() {
        let query = KeychainSSHCredentialStore.query(
            service: "dev.remux.ssh-credentials",
            accessGroup: "TEAM.dev.remux.shared",
            identityID: UUID(),
            returnData: false
        )
        XCTAssertEqual(query[kSecAttrAccessGroup] as? String, "TEAM.dev.remux.shared")
    }

    func testSharedConfigurationReadsExpandedAccessGroup() throws {
        XCTAssertEqual(
            try FileProviderSharedConfiguration.keychainAccessGroup(
                infoDictionary: ["RemuxSharedKeychainAccessGroup": "TEAM.dev.remux.shared"]
            ),
            "TEAM.dev.remux.shared"
        )
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderSharedStorageTests
```

Expected: compile failure because `sharedRemuxRoot` and the `accessGroup` initializer do not exist.

- [ ] **Step 3: Add the smallest storage configuration**

```swift
enum FileProviderSharedConfiguration {
    static let appGroupIdentifier = "group.dev.remux"
    static let credentialService = "dev.remux.ssh-credentials"

    static func keychainAccessGroup(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) throws -> String {
        guard let value = infoDictionary["RemuxSharedKeychainAccessGroup"] as? String,
              !value.isEmpty else {
            throw FileProviderSharedConfigurationError.missingKeychainAccessGroup
        }
        return value
    }
}

static func sharedRemuxRoot(
    appGroupIdentifier: String = FileProviderSharedConfiguration.appGroupIdentifier,
    fileManager: FileManager = .default,
    containerURL: @Sendable (String) -> URL? = {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: $0
        )
    }
) throws -> URL
```

Add `accessGroup: String?` to `KeychainSSHCredentialStore`; include
`kSecAttrAccessGroup` in every base query only when non-nil. Preserve the
existing initializer defaults so current callers and tests remain source
compatible. Extract the existing structured query construction into an
internal static `query(service:accessGroup:identityID:returnData:)` function;
all live Security operations and the focused test use that same function.

- [ ] **Step 4: Run focused and existing persistence tests**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderSharedStorageTests \
  -only-testing:RemuxTests/ConnectionProfileRepositoryTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add RemuxApp/Sources/Persistence/ApplicationStorage.swift \
  RemuxApp/Sources/Persistence/SSHCredentialStore.swift \
  RemuxAppTests/FileProviderSharedStorageTests.swift
git commit -m "Add shared storage configuration for File Provider"
```

---

### Task 2: Verified one-time migration

**Files:**
- Modify: `RemuxApp/Sources/Persistence/TrustedHostStore.swift`
- Create: `RemuxApp/Sources/Persistence/FileProviderSharedStorageMigrator.swift`
- Create: `RemuxAppTests/FileProviderSharedStorageMigratorTests.swift`

**Interfaces:**
- Consumes: legacy/shared `ConnectionProfileRepository` and `SSHCredentialStore`
- Produces: `TrustedHostStore.loadIdentities() throws -> [TrustedHostIdentity]`
- Produces: `TrustedHostStore.replaceIdentities(_:) throws`
- Produces: `protocol FileProviderSharedStorageMigrating { func migrateIfNeeded() async throws }`
- Produces: `FileProviderSharedStorageMigrator.migrateIfNeeded()`

- [ ] **Step 1: Write failing migration contract tests**

```swift
func testMigrationCopiesProfilesTrustAndEveryReferencedCredentialBeforeMarkingComplete() async throws {
    let fixture = try MigrationFixture()
    try await fixture.seedLegacy(password: "secret")
    try await fixture.migrator.migrateIfNeeded()

    XCTAssertEqual(try await fixture.sharedProfiles.loadSnapshot(), fixture.legacySnapshot)
    XCTAssertEqual(try fixture.sharedTrust.loadIdentities(), fixture.legacyTrust)
    XCTAssertEqual(
        try await fixture.sharedCredentials.loadCredential(identityID: fixture.identity.id),
        .password("secret")
    )
    XCTAssertTrue(fixture.markerExists)
}

func testMigrationFailureLeavesSourceIntactDoesNotMarkAndRetriesIdempotently() async throws {
    let fixture = try MigrationFixture(sharedCredentials: FailingOnceCredentialStore())
    try await fixture.seedLegacy(password: "secret")
    await XCTAssertThrowsErrorAsync { try await fixture.migrator.migrateIfNeeded() }
    XCTAssertFalse(fixture.markerExists)
    XCTAssertEqual(try await fixture.legacyCredentials.loadCredential(identityID: fixture.identity.id), .password("secret"))

    try await fixture.migrator.migrateIfNeeded()
    try await fixture.migrator.migrateIfNeeded()
    XCTAssertTrue(fixture.markerExists)
    XCTAssertEqual(try await fixture.sharedProfiles.loadSnapshot(), fixture.legacySnapshot)
}
```

- [ ] **Step 2: Run the migration tests and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderSharedStorageMigratorTests
```

Expected: compile failure because the migrator and trust snapshot APIs do not exist.

- [ ] **Step 3: Implement source-authoritative, marker-last migration**

```swift
protocol FileProviderSharedStorageMigrating: Sendable {
    func migrateIfNeeded() async throws
}

actor FileProviderSharedStorageMigrator: FileProviderSharedStorageMigrating {
    func migrateIfNeeded() async throws {
        guard !fileManager.fileExists(atPath: markerURL.path) else { return }
        let snapshot = try await legacyProfiles.loadSnapshot()
        let trusted = try legacyTrust.loadIdentities()

        for identity in snapshot.identities {
            try await sharedProfiles.saveIdentity(identity)
            if let credential = try await legacyCredentials.loadCredential(identityID: identity.id) {
                try await sharedCredentials.saveCredential(credential, identityID: identity.id)
                guard try await sharedCredentials.loadCredential(identityID: identity.id) == credential else {
                    throw FileProviderSharedStorageMigrationError.credentialVerificationFailed(identity.id)
                }
            }
        }
        for server in snapshot.servers { try await sharedProfiles.saveServer(server) }
        for workspace in snapshot.workspaces { try await sharedProfiles.saveWorkspace(workspace) }
        try sharedTrust.replaceIdentities(trusted)
        guard try await sharedProfiles.loadSnapshot() == snapshot,
              try sharedTrust.loadIdentities() == trusted else {
            throw FileProviderSharedStorageMigrationError.verificationFailed
        }
        try Data("1".utf8).write(to: markerURL, options: .atomic)
    }
}
```

The source stores are never deleted. Equivalent shared values are overwritten
with the legacy source value before verification, making retries deterministic.

- [ ] **Step 4: Run migration and trust tests**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderSharedStorageMigratorTests \
  -only-testing:RemuxTests/TrustedHostStoreTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add RemuxApp/Sources/Persistence/TrustedHostStore.swift \
  RemuxApp/Sources/Persistence/FileProviderSharedStorageMigrator.swift \
  RemuxAppTests/FileProviderSharedStorageMigratorTests.swift
git commit -m "Migrate File Provider state into shared stores"
```

---

### Task 3: Domain eligibility and reconciliation

**Files:**
- Create: `RemuxApp/Sources/FileProvider/FileProviderDomainReconciler.swift`
- Create: `RemuxAppTests/FileProviderDomainReconcilerTests.swift`

**Interfaces:**
- Consumes: shared profile, credential, and trust stores
- Produces: `FileProviderDomainRecord(serverID:displayName:)`
- Produces: `protocol FileProviderDomainRegistering`
- Produces: `protocol FileProviderDomainReconciling { func reconcile() async throws }`
- Produces: `FileProviderDomainReconciler.reconcile()`

- [ ] **Step 1: Write failing eligibility and exact-set tests**

```swift
func testOnlyServersWithCredentialAndTrustedHostBecomeDomains() async throws {
    let fixture = DomainFixture(passwordServer: .eligible, keyServer: .missingTrust, thirdServer: .missingCredential)
    try await fixture.reconciler.reconcile()
    XCTAssertEqual(await fixture.registry.records, [
        FileProviderDomainRecord(serverID: fixture.passwordServer.id, displayName: "Password")
    ])
}

func testReconcileAddsRenamesAndRemovesToMatchDesiredSet() async throws {
    let fixture = DomainFixture(existing: [.init(serverID: UUID(), displayName: "Removed")])
    try await fixture.reconciler.reconcile()
    XCTAssertEqual(await fixture.registry.records, fixture.expectedRecords)
    XCTAssertEqual(await fixture.registry.maximumConcurrentMutationCount, 1)
}
```

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderDomainReconcilerTests
```

Expected: compile failure because domain reconciliation types do not exist.

- [ ] **Step 3: Implement the pure record model and live registry adapter**

```swift
struct FileProviderDomainRecord: Equatable, Sendable {
    let serverID: SavedServer.ID
    let displayName: String
}

protocol FileProviderDomainRegistering: Sendable {
    func records() async throws -> [FileProviderDomainRecord]
    func add(_ record: FileProviderDomainRecord) async throws
    func remove(serverID: SavedServer.ID) async throws
}

actor FileProviderDomainReconciler: FileProviderDomainReconciling {
    func reconcile() async throws {
        let snapshot = try await profiles.loadSnapshot()
        let trustedIDs = Set(try trust.loadIdentities().map(\.serverID))
        var desired: [FileProviderDomainRecord] = []
        for server in snapshot.servers where trustedIDs.contains(server.id) {
            guard try await credentials.loadCredential(identityID: server.identityID) != nil else { continue }
            desired.append(.init(serverID: server.id, displayName: server.displayName))
        }
        let existing = try await registry.records()
        for record in existing
        where desired.first(where: { $0.serverID == record.serverID }) != record {
            try await registry.remove(serverID: record.serverID)
        }
        for record in desired
        where existing.first(where: { $0.serverID == record.serverID }) != record {
            try await registry.add(record)
        }
    }
}
```

The live adapter wraps `NSFileProviderManager.getDomainsWithCompletionHandler`,
`add(_:completionHandler:)`, and `remove(_:completionHandler:)`. Domain raw
identifiers are exactly `server.id.uuidString.lowercased()`.

- [ ] **Step 4: Run focused tests**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderDomainReconcilerTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add RemuxApp/Sources/FileProvider/FileProviderDomainReconciler.swift \
  RemuxAppTests/FileProviderDomainReconcilerTests.swift
git commit -m "Reconcile eligible SSH servers as File Provider domains"
```

---

### Task 4: Read-only SFTP listing and bounded download

**Files:**
- Modify: `RemuxApp/Sources/SSH/RemuxSFTPClient.swift`
- Modify: `RemuxApp/Sources/SSH/RemuxCitadelSFTPClient.swift`
- Create: `RemuxAppTests/RemuxSFTPReadOnlyClientTests.swift`
- Modify: `RemuxAppTests/GhosttyRemoteAttachmentPathBuilderTests.swift`

**Interfaces:**
- Produces: `RemuxSFTPFileType`
- Produces: `RemuxSFTPDirectoryEntry`
- Produces: expanded `RemuxSFTPFileMetadata.type`
- Produces: `RemuxSFTPReadOnlyClient.realPath`, `listDirectory`, `linkMetadata`, and `downloadFile`

- [ ] **Step 1: Write failing structured behavior tests**

```swift
func testDirectoryListingDropsDotEntriesPreservesDotfilesAndClassifiesModes() async throws {
    let entries = try await fixture.client.listDirectory(atPath: ".")
    XCTAssertFalse(entries.map(\.name).contains("."))
    XCTAssertFalse(entries.map(\.name).contains(".."))
    XCTAssertTrue(entries.map(\.name).contains(".env"))
    XCTAssertEqual(entries.first(named: "folder")?.metadata.type, .directory)
    XCTAssertEqual(entries.first(named: "link")?.metadata.type, .symbolicLink)
}

func testDownloadUsesBoundedMonotonicReadsReportsProgressAndRemovesPartialOnCancellation() async throws {
    let remote = RecordingReadableFile(chunks: [Data(repeating: 1, count: 4 * 1024 * 1024), Data([2])])
    let url = temporaryURL()
    try await fixture.client.downloadFile(atPath: "/large", to: url) { fixture.progress.append($0) }
    XCTAssertEqual(remote.requests, [.init(offset: 0, length: 4 * 1024 * 1024), .init(offset: 4 * 1024 * 1024, length: 4 * 1024 * 1024)])
    XCTAssertEqual(fixture.progress, [4 * 1024 * 1024, 4 * 1024 * 1024 + 1])
    XCTAssertEqual(try Data(contentsOf: url).count, 4 * 1024 * 1024 + 1)
}
```

Also cover missing paths, timeout propagation, and cancellation cleanup with
fakes. Keep one opt-in real-host test fixture for dotfiles, safe/unsafe links,
and multi-chunk downloads; skip it with an explicit reason when its environment
variables are absent.

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxSFTPReadOnlyClientTests
```

Expected: compile failure because the listing/download contracts do not exist.

- [ ] **Step 3: Implement metadata classification, listing, and download**

```swift
enum RemuxSFTPFileType: String, Codable, Sendable {
    case regular, directory, symbolicLink, other
}

struct RemuxSFTPDirectoryEntry: Equatable, Sendable {
    let name: String
    let metadata: RemuxSFTPFileMetadata
}

protocol RemuxSFTPReadOnlyClient: Sendable {
    func realPath(atPath path: String) async throws -> String
    func listDirectory(atPath path: String) async throws -> [RemuxSFTPDirectoryEntry]
    func metadata(atPath path: String) async throws -> RemuxSFTPFileMetadata
    func linkMetadata(atPath path: String) async throws -> RemuxSFTPFileMetadata
    func downloadFile(
        atPath remotePath: String,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws
}
```

Use Citadel `listDirectory(atPath:)`, flatten `SFTPMessage.Name.components`,
drop only `"."` and `".."`, and classify the `permissions` POSIX type bits.
Implement `linkMetadata` by listing the parent directory and matching the final
component so symlinks are not followed. Implement downloads with the existing
`withFile`/4 MiB read bound, `Task.checkCancellation()` around remote reads and
local writes, cumulative progress, and `FileManager.removeItem` on every
failure.

- [ ] **Step 4: Run SFTP and existing transfer tests**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxSFTPReadOnlyClientTests \
  -only-testing:RemuxTests/RemuxSFTPReadableFileTests \
  -only-testing:RemuxTests/TerminalPreviewFileLoaderTests \
  -only-testing:RemuxTests/GhosttyAttachmentSFTPTransferServiceTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add RemuxApp/Sources/SSH/RemuxSFTPClient.swift \
  RemuxApp/Sources/SSH/RemuxCitadelSFTPClient.swift \
  RemuxAppTests/RemuxSFTPReadOnlyClientTests.swift \
  RemuxAppTests/GhosttyRemoteAttachmentPathBuilderTests.swift
git commit -m "Add read-only SFTP directory and download operations"
```

---

### Task 5: Remote paths, item identities, safe links, and versions

**Files:**
- Create: `RemuxApp/Sources/FileProvider/FileProviderRemotePath.swift`
- Create: `RemuxApp/Sources/FileProvider/FileProviderRemoteItem.swift`
- Create: `RemuxAppTests/FileProviderRemoteItemTests.swift`

**Interfaces:**
- Consumes: `RemuxSFTPFileMetadata`
- Produces: `FileProviderRemotePath`
- Produces: `FileProviderItemIdentifierCodec`
- Produces: `FileProviderRemoteItem`
- Produces: `FileProviderSafeLinkResolver`

- [ ] **Step 1: Write failing path, identity, version, and link tests**

```swift
func testNormalizationRejectsTraversalAndAcceptsDotfiles() throws {
    XCTAssertEqual(try FileProviderRemotePath(relative: ".config/tool").relative, ".config/tool")
    XCTAssertThrowsError(try FileProviderRemotePath(relative: "../escape"))
    XCTAssertThrowsError(try FileProviderRemotePath(relative: "folder/../../escape"))
}

func testIdentifierRoundTripsUnicodeAndRoot() throws {
    let path = try FileProviderRemotePath(relative: "資料/a b.txt")
    XCTAssertEqual(try codec.path(for: codec.identifier(for: path)), path)
    XCTAssertEqual(codec.identifier(for: .root), .rootContainer)
}

func testVersionsChangeForDesignedFieldsOnly() throws {
    let original = fixture.item(size: 4, mtime: 100, permissions: 0o100644)
    XCTAssertNotEqual(original.contentVersion, fixture.item(size: 5, mtime: 100, permissions: 0o100644).contentVersion)
    XCTAssertNotEqual(original.metadataVersion, fixture.item(size: 4, mtime: 100, permissions: 0o100600).metadataVersion)
}

func testLinkResolverAcceptsOnlyCanonicalTargetsUnderHome() throws {
    XCTAssertEqual(try resolver.resolve("/home/me/project", home: "/home/me"), "project")
    XCTAssertThrowsError(try resolver.resolve("/etc/passwd", home: "/home/me"))
    XCTAssertThrowsError(try resolver.resolve("/home/other", home: "/home/me"))
}
```

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderRemoteItemTests
```

Expected: compile failure because provider model types do not exist.

- [ ] **Step 3: Implement deterministic pure provider models**

```swift
struct FileProviderRemotePath: Hashable, Codable, Sendable {
    static let root = try! FileProviderRemotePath(relative: "")
    let relative: String
    init(relative: String) throws
    func remotePath(beneath canonicalHome: String) throws -> String
}

struct FileProviderRemoteItem: Equatable, Codable, Sendable {
    let path: FileProviderRemotePath
    let parent: FileProviderRemotePath
    let name: String
    let type: RemuxSFTPFileType
    let size: UInt64?
    let permissions: UInt32?
    let modificationDate: Date?
    let symlinkTargetRelativePath: String?
}
```

Identifiers use URL-safe base64 of UTF-8 relative paths with a fixed `"p:"`
prefix; decoding validates normalization again. Content version encodes type,
size, and integer modification timestamp. Metadata version additionally
encodes normalized path, name, and permissions. Use deterministic JSON with
sorted keys or a fixed binary field order.

- [ ] **Step 4: Run focused tests**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderRemoteItemTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add RemuxApp/Sources/FileProvider/FileProviderRemotePath.swift \
  RemuxApp/Sources/FileProvider/FileProviderRemoteItem.swift \
  RemuxAppTests/FileProviderRemoteItemTests.swift
git commit -m "Model safe remote File Provider items"
```

---

### Task 6: Bounded snapshot generations and File Provider errors

**Files:**
- Create: `RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift`
- Create: `RemuxApp/Sources/FileProvider/FileProviderErrorMapper.swift`
- Create: `RemuxAppTests/FileProviderSnapshotStoreTests.swift`
- Create: `RemuxAppTests/FileProviderErrorMapperTests.swift`

**Interfaces:**
- Consumes: `[FileProviderRemoteItem]`
- Produces: `FileProviderSnapshotDelta(updated:deleted:)`
- Produces: `FileProviderSnapshotStore.record/items/delta`
- Produces: `FileProviderErrorMapper.map(_:itemIdentifier:)`

- [ ] **Step 1: Write failing snapshot and mapping tests**

```swift
func testRecordProducesInsertUpdateDeleteAndStableGeneration() async throws {
    let first = try await store.record(directory: .root, items: [a, b])
    let unchanged = try await store.record(directory: .root, items: [a, b])
    let changed = try await store.record(directory: .root, items: [aChanged, c])
    XCTAssertEqual(first.anchor, unchanged.anchor)
    XCTAssertEqual(changed.delta.updated, [aChanged, c])
    XCTAssertEqual(changed.delta.deleted, [b.identifier])
}

func testEvictedAnchorThrowsSyncAnchorExpired() async throws {
    let store = FileProviderSnapshotStore(rootURL: root, retainedGenerationCount: 2)
    let old = try await store.record(directory: .root, items: [a]).anchor
    _ = try await store.record(directory: .root, items: [b])
    _ = try await store.record(directory: .root, items: [c])
    await XCTAssertThrowsErrorAsync { try await store.delta(directory: .root, from: old) }
}

func testErrorMapperDoesNotReflectSecretsAndUsesStableCodes() {
    XCTAssertEqual(mapper.map(RemuxSFTPClientError.operationTimedOut).code, NSFileProviderError.serverUnreachable.rawValue)
    XCTAssertEqual(mapper.map(SSHAuthResolverError.missingCredential(id)).code, NSFileProviderError.notAuthenticated.rawValue)
    XCTAssertFalse(String(reflecting: mapper.map(SecretError("password"))).contains("password"))
}
```

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests \
  -only-testing:RemuxTests/FileProviderErrorMapperTests
```

Expected: compile failure because snapshot/error types do not exist.

- [ ] **Step 3: Implement atomic persisted snapshots and closed error mapping**

Persist one Codable state file per domain beneath the File Provider state
directory. Serialize all actor access, retain eight generations, reuse the
current anchor for identical item arrays, and create monotonically increasing
`UInt64` anchors only for changes. Store metadata only.

```swift
struct FileProviderSnapshotDelta: Equatable, Sendable {
    let updated: [FileProviderRemoteItem]
    let deleted: [NSFileProviderItemIdentifier]
}

actor FileProviderSnapshotStore {
    func record(
        directory: FileProviderRemotePath,
        items: [FileProviderRemoteItem]
    ) throws -> (anchor: NSFileProviderSyncAnchor, delta: FileProviderSnapshotDelta)

    func delta(
        directory: FileProviderRemotePath,
        from anchor: NSFileProviderSyncAnchor
    ) throws -> (anchor: NSFileProviderSyncAnchor, delta: FileProviderSnapshotDelta)
}
```

Map authentication/trust failures to `NSFileProviderError.notAuthenticated`,
network/connect/timeout/session failures to `.serverUnreachable`, missing
paths to `NSFileProviderError.noSuchItem` with
`NSFileProviderErrorItemKey`, expired generations to `.syncAnchorExpired`, and
all unknown underlying errors to a sanitized `NSCocoaErrorDomain` error with
`NSXPCConnectionReplyInvalid`.

```swift
enum FileProviderErrorMapper {
    static func map(
        _ error: Error,
        itemIdentifier: NSFileProviderItemIdentifier? = nil
    ) -> NSError

    static var writePermission: NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }
}
```

- [ ] **Step 4: Run focused tests**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests \
  -only-testing:RemuxTests/FileProviderErrorMapperTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift \
  RemuxApp/Sources/FileProvider/FileProviderErrorMapper.swift \
  RemuxAppTests/FileProviderSnapshotStoreTests.swift \
  RemuxAppTests/FileProviderErrorMapperTests.swift
git commit -m "Persist File Provider snapshots and stable errors"
```

---

### Task 7: Remote domain service and replicated extension

**Files:**
- Create: `RemuxApp/Sources/SSH/RemuxSSHAuthenticationMethodFactory.swift`
- Create: `RemuxApp/Sources/SSH/RemuxTransportStartupTrace.swift`
- Modify: `RemuxApp/Sources/SSH/RemuxSSHRootService.swift`
- Modify: `RemuxApp/Sources/Tmux/GhosttyRuntimeTrace.swift`
- Modify: `RemuxApp/Sources/App/RemuxAppDependencies.swift`
- Create: `RemuxApp/Sources/FileProvider/FileProviderReadOnlyMutationPolicy.swift`
- Create: `RemuxApp/Sources/FileProvider/FileProviderRemoteService.swift`
- Create: `RemuxFileProvider/Sources/RemuxFileProviderItem.swift`
- Create: `RemuxFileProvider/Sources/RemuxFileProviderEnumerator.swift`
- Create: `RemuxFileProvider/Sources/RemuxFileProviderExtension.swift`
- Create: `RemuxAppTests/FileProviderRemoteServiceTests.swift`
- Create: `RemuxAppTests/RemuxFileProviderContractTests.swift`

**Interfaces:**
- Consumes: shared stores, `RemuxCitadelSFTPClientProvider`, path/items/snapshots
- Produces: `FileProviderRemoteServicing`
- Produces: `RemuxFileProviderItem`
- Produces: `RemuxFileProviderEnumerator`
- Produces: `RemuxFileProviderExtension`

- [ ] **Step 1: Write failing service and read-only contract tests**

```swift
func testServiceListsHomeAndFiltersUnsupportedAndUnsafeLinks() async throws {
    let items = try await fixture.service.list(directory: .root)
    XCTAssertEqual(items.map(\.name), [".env", "folder", "safe-link", "file.txt"])
    XCTAssertFalse(items.map(\.name).contains("socket"))
    XCTAssertFalse(items.map(\.name).contains("escape-link"))
    XCTAssertEqual(items.first(named: "safe-link")?.symlinkTargetRelativePath, "folder/target")
}

func testMutationsReturnWritePermissionAndNeverCallRemoteService() {
    let error = FileProviderReadOnlyMutationPolicy.rejection
    XCTAssertEqual(error.domain, NSCocoaErrorDomain)
    XCTAssertEqual(error.code, NSFileWriteNoPermissionError)
    XCTAssertEqual(remoteService.mutationCallCount, 0)
}

func testFetchCancellationCancelsRemoteTaskAndRemovesPartialURL() async throws {
    let task = Task {
        try await fixture.service.fetch(
            path: try FileProviderRemotePath(relative: "large.bin"),
            to: fixture.partialURL,
            progress: { _ in }
        )
    }
    await fixture.waitUntilRemoteReadStarts()
    task.cancel()
    await XCTAssertThrowsErrorAsync { try await task.value }
    XCTAssertTrue(remoteService.wasCancelled)
    XCTAssertFalse(fileManager.fileExists(atPath: fixture.partialURL.path))
}
```

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderRemoteServiceTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests
```

Expected: compile failure because the service and extension contracts do not exist.

- [ ] **Step 3: Extract extension-safe authentication and implement service**

```swift
enum RemuxSSHAuthenticationMethodFactory {
    static func make(for auth: ResolvedSSHAuth) throws -> SSHAuthenticationMethod
}

protocol FileProviderRemoteServicing: Sendable {
    func item(at path: FileProviderRemotePath) async throws -> FileProviderRemoteItem
    func list(directory: FileProviderRemotePath) async throws -> [FileProviderRemoteItem]
    func fetch(
        path: FileProviderRemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> FileProviderRemoteItem
}
```

Move the current authentication construction from `RemuxAppDependencies` into
the factory and delegate to it from the app. Add
`RemuxSSHRootKey(server:auth:)`. The service selects the server from the domain
UUID, resolves its stored credential, validates through the read-only
`TrustedHostStore.validator`, obtains `realPath(".")`, and performs one
`RemuxCitadelSFTPClientProvider.withClient` operation.

Move `RemuxTransportStartupTrace` unchanged into the SSH source folder, with
its existing `GhosttyRuntimeTrace` calls compiled for the app and a no-op sink
under the extension target's `REMUX_FILE_PROVIDER_EXTENSION` compilation
condition. This keeps the SSH root source extension-safe without pulling the
tmux/Ghostty source graph into the extension.

- [ ] **Step 4: Implement item and extension callbacks**

`RemuxFileProviderItem` advertises only `.allowsReading` and provides identifier,
parent, filename, UTType, size, modification date, version, and optional
canonical in-root symlink target.

`RemuxFileProviderExtension` implements every required SDK method. Item lookup
and fetch launch cancellable tasks and complete exactly once. Fetch writes into
`NSFileProviderManager(for: domain).temporaryDirectoryURL()`. Create, modify,
and delete immediately return `NSFileWriteNoPermissionError`.

```swift
enum FileProviderReadOnlyMutationPolicy {
    static let rejection = NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileWriteNoPermissionError
    )
}

final class RemuxFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    required init(domain: NSFileProviderDomain)
    func invalidate()
    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress
    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress
    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?,
            NSFileProviderItemFields,
            Bool,
            Error?
        ) -> Void
    ) -> Progress
    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?,
            NSFileProviderItemFields,
            Bool,
            Error?
        ) -> Void
    ) -> Progress
    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress
    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> any NSFileProviderEnumerator
}
```

- [ ] **Step 5: Implement enumeration, deltas, polling, and invalidation**

`RemuxFileProviderEnumerator` performs initial enumeration through the service,
records the result, and finishes with no next page. Change enumeration loads
the requested retained generation and reports updated/deleted identifiers.
`currentSyncAnchor` returns the latest persisted anchor.

Start one five-second polling task for active directory enumerators. A
domain-scoped actor coalesces concurrent refreshes. When a snapshot changes,
call `NSFileProviderManager(for: domain).signalEnumerator` for the directory and
`.workingSet`. `invalidate()` cancels polling and the current request task.

```swift
final class RemuxFileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate()
    func enumerateItems(
        for observer: any NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    )
    func enumerateChanges(
        for observer: any NSFileProviderChangeObserver,
        from syncAnchor: NSFileProviderSyncAnchor
    )
    func currentSyncAnchor(
        completionHandler: @escaping @Sendable (NSFileProviderSyncAnchor?) -> Void
    )
}

actor FileProviderPollingCoordinator {
    func refresh(
        directory: FileProviderRemotePath,
        operation: @Sendable () async throws -> [FileProviderRemoteItem]
    ) async throws -> [FileProviderRemoteItem]
}
```

- [ ] **Step 6: Run focused service/contract tests**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderRemoteServiceTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests
```

Expected: PASS, including deterministic virtual-clock polling tests proving a
change signals once by five seconds and coalesces overlapping refreshes.

- [ ] **Step 7: Commit**

```bash
git add RemuxApp/Sources/SSH/RemuxSSHAuthenticationMethodFactory.swift \
  RemuxApp/Sources/SSH/RemuxTransportStartupTrace.swift \
  RemuxApp/Sources/SSH/RemuxSSHRootService.swift \
  RemuxApp/Sources/Tmux/GhosttyRuntimeTrace.swift \
  RemuxApp/Sources/App/RemuxAppDependencies.swift \
  RemuxApp/Sources/FileProvider/FileProviderReadOnlyMutationPolicy.swift \
  RemuxApp/Sources/FileProvider/FileProviderRemoteService.swift \
  RemuxFileProvider/Sources \
  RemuxAppTests/FileProviderRemoteServiceTests.swift \
  RemuxAppTests/RemuxFileProviderContractTests.swift
git commit -m "Implement the read-only replicated File Provider"
```

---

### Task 8: Target wiring and app lifecycle reconciliation

**Files:**
- Create: `RemuxApp/Remux.entitlements`
- Create: `RemuxFileProvider/RemuxFileProvider.entitlements`
- Create: `RemuxFileProvider/Info.plist`
- Modify: `project.yml`
- Modify: `Remux.xcodeproj/project.pbxproj` through `xcodegen generate`
- Modify: `RemuxApp/Sources/App/RemuxAppDependencies.swift`
- Modify: `RemuxApp/Sources/App/RemuxRootModel.swift`
- Modify: `RemuxAppTests/RemuxRootModelTests.swift`

**Interfaces:**
- Consumes: migrator and reconciler from Tasks 2–3
- Produces: embedded `RemuxFileProvider.appex`
- Produces: migration/reconciliation at load and provider-relevant mutations

- [ ] **Step 1: Write failing lifecycle tests**

```swift
func testLoadMigratesBeforeReadingSharedLibraryThenReconciles() async {
    let harness = RootModelHarness(migrator: recorder, reconciler: recorder)
    await harness.model.load()
    XCTAssertEqual(recorder.events.prefix(3), [.migrate, .loadSnapshot, .reconcile])
}

func testProviderRelevantMutationsReconcileButWorkspaceOnlySaveDoesNot() async {
    await harness.saveServer()
    await harness.acceptHostTrust()
    await harness.deleteServer()
    XCTAssertEqual(reconciler.callCount, 3)
    await harness.saveWorkspace()
    XCTAssertEqual(reconciler.callCount, 3)
}
```

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxRootModelTests
```

Expected: lifecycle assertions fail because migration and reconciliation are
not dependencies.

- [ ] **Step 3: Add entitlements, extension plist, and XcodeGen target**

Both entitlements files contain:

```xml
<key>com.apple.security.application-groups</key>
<array><string>group.dev.remux</string></array>
<key>keychain-access-groups</key>
<array><string>$(AppIdentifierPrefix)dev.remux.shared</string></array>
```

The extension declares `com.apple.fileprovider-nonui`,
`group.dev.remux`, `$(PRODUCT_MODULE_NAME).RemuxFileProviderExtension`,
enumeration support, and download pipeline depth `1`.
Both the app and extension Info dictionaries define
`RemuxSharedKeychainAccessGroup` as
`$(AppIdentifierPrefix)dev.remux.shared`, providing the fully expanded runtime
value used in Security queries.

Add an `app-extension` XcodeGen target with bundle ID
`dev.remux.app.file-provider`, `APPLICATION_EXTENSION_API_ONLY: YES`,
`SWIFT_ACTIVE_COMPILATION_CONDITIONS: REMUX_FILE_PROVIDER_EXTENSION`,
FileProvider/UniformTypeIdentifiers/Security, Citadel, exact shared source
files, and the three extension files. Embed it from `Remux`; link FileProvider
in the app; point both targets at their entitlements.

```yaml
RemuxFileProvider:
  type: app-extension
  platform: iOS
  deploymentTarget: "18.0"
  sources:
    - path: RemuxFileProvider/Sources
    - path: RemuxApp/Sources/Domain/TmuxConnectionTarget.swift
    - path: RemuxApp/Sources/Domain/SSHPrivateKeyInspector.swift
    - path: RemuxApp/Sources/Persistence/ApplicationStorage.swift
    - path: RemuxApp/Sources/Persistence/ConnectionProfileRepository.swift
    - path: RemuxApp/Sources/Persistence/JSONFileStore.swift
    - path: RemuxApp/Sources/Persistence/SSHCredentialStore.swift
    - path: RemuxApp/Sources/Persistence/TrustedHostStore.swift
    - path: RemuxApp/Sources/App/SSHAuthResolver.swift
    - path: RemuxApp/Sources/SSH/RemuxSFTPClient.swift
    - path: RemuxApp/Sources/SSH/RemuxCitadelSFTPClient.swift
    - path: RemuxApp/Sources/SSH/RemuxSSHRootService.swift
    - path: RemuxApp/Sources/SSH/RemuxSSHAuthenticationMethodFactory.swift
    - path: RemuxApp/Sources/SSH/RemuxTransportStartupTrace.swift
    - path: RemuxApp/Sources/FileProvider
  dependencies:
    - package: Citadel
  settings:
    base:
      PRODUCT_BUNDLE_IDENTIFIER: dev.remux.app.file-provider
      CODE_SIGN_ENTITLEMENTS: RemuxFileProvider/RemuxFileProvider.entitlements
      APPLICATION_EXTENSION_API_ONLY: YES
      SWIFT_ACTIVE_COMPILATION_CONDITIONS: REMUX_FILE_PROVIDER_EXTENSION
  info:
    path: RemuxFileProvider/Info.plist
```

- [ ] **Step 4: Regenerate and prove both targets compile**

```bash
xcodegen generate
xcodebuild build -project Remux.xcodeproj -scheme Remux \
  -destination 'generic/platform=iOS Simulator'
```

Expected: `BUILD SUCCEEDED` and the app product contains
`PlugIns/RemuxFileProvider.appex`.

- [ ] **Step 5: Wire live stores, migration, and reconciliation**

`RemuxAppDependencies.live()` keeps settings/shortcuts at the legacy root but
uses shared roots for profiles/trust and the shared Keychain access group for
credentials. It injects the migrator and domain reconciler with default no-op
test doubles.

At the start of `RemuxRootModel.load()`, await migration before any profile
read, then reconcile after the library loads. Reconcile after successful new
server save, server/credential edit, accepted trust, and server deletion.
Workspace-only mutations do not reconcile. Reconciliation errors are logged
without hiding or disconnecting the saved terminal profile; migration errors
fail loading because reading an uninitialized shared store would silently hide
existing servers.

```swift
func load() async {
    do {
        try await dependencies.fileProviderStorageMigrator.migrateIfNeeded()
        terminalSettings = try await dependencies.settingsRepository.load()
        library = try await dependencies.profileRepository.loadSnapshot()
        await reconcileFileProviderDomains()
    } catch {
        state = .failed(String(describing: error))
    }
}

private func reconcileFileProviderDomains() async {
    do {
        try await dependencies.fileProviderDomainReconciler.reconcile()
    } catch {
        NSLog(
            "Remux File Provider domain reconciliation failed: %@",
            String(describing: error)
        )
    }
}
```

- [ ] **Step 6: Run lifecycle, focused feature, and full tests**

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxRootModelTests \
  -only-testing:RemuxTests/FileProviderSharedStorageMigratorTests \
  -only-testing:RemuxTests/FileProviderDomainReconcilerTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests

xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

Expected: focused and full schemes PASS.

- [ ] **Step 7: Commit**

```bash
git add RemuxApp/Remux.entitlements \
  RemuxFileProvider/RemuxFileProvider.entitlements \
  RemuxFileProvider/Info.plist \
  project.yml Remux.xcodeproj/project.pbxproj \
  RemuxApp/Sources/App/RemuxAppDependencies.swift \
  RemuxApp/Sources/App/RemuxRootModel.swift \
  RemuxAppTests/RemuxRootModelTests.swift
git commit -m "Embed and synchronize the SSH File Provider"
```

---

### Task 9: Simulator qualification

**Files:**
- Create: `scripts/qualify_file_provider.sh`
- Create: `docs/file-provider-qualification.md`

**Interfaces:**
- Consumes: built app, saved password/key hosts, simulator Files app
- Produces: repeatable build/install/domain inspection commands and recorded evidence

- [ ] **Step 1: Add a non-destructive qualification script**

The script accepts a simulator UDID, builds the `Remux` scheme, installs the
app, launches it, and prints the exact `PlugIns/RemuxFileProvider.appex`,
application-group, and keychain-access-group entitlements from the built
products. It must not erase the simulator, remove saved hosts, or mutate remote
files.

```bash
#!/bin/zsh
set -euo pipefail
simulator_udid="${1:?usage: qualify_file_provider.sh SIMULATOR_UDID}"
xcodebuild build -project Remux.xcodeproj -scheme Remux \
  -destination "platform=iOS Simulator,id=${simulator_udid}" \
  -derivedDataPath .derived-data/file-provider-qualification
app_path="$(find .derived-data/file-provider-qualification/Build/Products \
  -path '*iphonesimulator/Remux.app' -print -quit)"
test -d "${app_path}/PlugIns/RemuxFileProvider.appex"
xcrun simctl install "${simulator_udid}" "${app_path}"
xcrun simctl launch "${simulator_udid}" dev.remux.app
codesign -d --entitlements :- "${app_path}"
codesign -d --entitlements :- "${app_path}/PlugIns/RemuxFileProvider.appex"
```

- [ ] **Step 2: Run static product qualification**

```bash
scripts/qualify_file_provider.sh "$(xcrun simctl list devices available -j | jq -r '.devices[][] | select(.name == "iPhone 17") | .udid' | head -1)"
```

Expected: app installs and launches; extension is embedded; app/extension App
Group and Keychain groups match exactly.

- [ ] **Step 3: Qualify existing password and private-key hosts in Files**

Open Remux once to migrate/reconcile, then open Files:

1. Confirm both saved host locations appear.
2. Browse the remote home, including a dotfile and directory.
3. Open a remote regular file and compare its bytes with the remote file.
4. Confirm unsafe/special files do not appear.
5. Confirm create, rename, move, and delete do not succeed.
6. Capture known-host JSON before and after and confirm it is byte-identical.

- [ ] **Step 4: Prove live agent-created file discovery**

Keep one remote directory open in Files. From the existing coding-agent/SSH
session create a uniquely named file in that directory, record start time, and
observe it appearing without leaving the directory. The elapsed time must be
at most ten seconds. Repeat once after backgrounding/reopening Files to prove
the refresh-on-reopen path.

- [ ] **Step 5: Document exact evidence and remaining device-only gate**

Record simulator model/OS, app commit, host authentication modes without
credentials, elapsed poll result, focused/full test totals, and screenshots.
Explicitly state that distribution provisioning and real-device shared
Keychain/App Group access remain a device-only release gate.

- [ ] **Step 6: Commit**

```bash
git add scripts/qualify_file_provider.sh docs/file-provider-qualification.md
git commit -m "Document File Provider simulator qualification"
```
