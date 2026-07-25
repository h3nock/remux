# Writable SSH File Provider Design

**Status:** Draft for written review
**Date:** 2026-07-25

## Context

Remux has an implemented native replicated File Provider that exposes the
authenticated SSH user's home directory through SFTP. The current implementation
lists directories, downloads regular files, polls active directories, persists
working-set snapshots, and rejects every mutation.

The read-only provider has not shipped. Existing path-derived item identifiers
and read-only domains therefore need no production compatibility or migration.
Development simulator domains may be removed and recreated while this feature is
qualified.

Remux already has SFTP operations for bounded upload, directory creation, rename,
and file removal. Writable File Provider support should reuse those operations
and the existing SSH connection, trust, credential, path-containment,
cancellation, and snapshot boundaries.

## Goals

- Create and overwrite regular files from Files and document-based applications.
- Create directories.
- Rename and move regular files and directories.
- Delete regular files and empty directories.
- Preserve remote changes made by coding agents or other SSH clients instead of
  silently overwriting them.
- Keep File Provider's local replica, persisted snapshots, and remote SFTP state
  consistent across concurrent enumeration and mutation callbacks.
- Give locally initiated renames and moves stable item identity.
- Report upload progress and respond promptly to cancellation.
- Recover idempotently when File Provider replays a completed request.
- Keep every remote operation confined beneath the authenticated user's
  canonical home directory.

## Non-Goals

- Recursive deletion of non-empty directories.
- Creating, modifying, renaming, moving, or deleting symbolic links.
- Synchronizing permissions, tags, favorite rank, extended attributes,
  creation date, or other metadata-only fields.
- Offline writes or a background upload queue.
- Merging concurrent content changes.
- Remote trash semantics.
- Partial-file upload.
- Preserving development-only path identifiers or simulator domain state.
- Providing backward compatibility for a shipped read-only provider.

## Chosen Approach

Remux will use serialized, remote-authoritative mutations.

All namespace-affecting polls and mutations for one domain pass through one
coordinator. A mutation validates current remote state, applies one bounded SFTP
transaction, reads the authoritative result, updates the identity and snapshot
stores, and then completes the File Provider callback.

This avoids two rejected alternatives:

- An optimistic local journal would require an offline sync engine, retry UI,
  and broader conflict resolution that are outside this version.
- Direct SFTP callbacks followed by eventual polling would allow a stale poll
  to overwrite or reverse newly committed mutation state.

Downloads may continue independently because they do not modify namespace or
snapshot state. Uploading file content remains inside the serialized mutation
operation so a poll cannot expose Remux's temporary upload file.

## Development Domain Reset

The writable implementation changes item identity and provider capabilities.
Because the read-only implementation never shipped, Remux will not add a
production migration.

During development qualification, existing simulator File Provider domains are
removed and recreated once. This clears only File Provider's local replica and
snapshot cache. It does not remove:

- Saved Remux server profiles.
- Credentials or trusted-host records.
- Remote files or directories.

The production domain-reconciliation path remains free of legacy identifier
translation, compatibility markers, and one-time migration code.

## Stable Item Identity

The root retains `NSFileProviderItemIdentifier.rootContainer`. Every other item
receives a persisted opaque UUID identifier. Identifiers contain no path,
hostname, username, or other sensitive data.

The snapshot state stores both directions of the current mapping:

- Item identifier to normalized remote path.
- Normalized remote path to item identifier.

Identity rules are:

1. Re-enumerating an unchanged path retains its identifier.
2. A local rename or move changes the mapped path while retaining the
   identifier.
3. A newly observed remote path receives a new identifier.
4. SFTP does not expose a dependable cross-rename identity, so a rename made
   independently on the host is represented as deletion of the old item and
   creation of a new item.
5. Deleted identifiers are not reused.
6. The item identifier supplied by File Provider in a create template is
   recorded as a replay alias, not adopted as the provider identifier.

Item content and metadata versions remain derived from remote type, size,
modification time, permissions, name, and path. A local rename therefore keeps
the item identifier while advancing its metadata version.

## Advertised Capabilities

The root directory advertises reading, content enumeration, writing, and adding
subitems. It cannot be renamed, moved, or deleted.

Regular directories advertise:

- Reading and content enumeration.
- Writing and adding subitems.
- Renaming and reparenting.
- Deleting.

Regular files advertise:

- Reading and writing.
- Renaming and reparenting.
- Deleting.

Symbolic links continue to advertise reading only. Trashing is not advertised;
deletion is permanent. The undocumented `NSExtensionFileProviderReadOnly` key is
removed.

The extension configures upload and metadata-only upload pipeline depths of one.
The model coordinator remains the correctness boundary even if platform
scheduling behavior changes.

## Supported Fields

Creation accepts:

- Filename.
- Parent item identifier.
- Contents for a regular file.
- Directory content type with no contents URL.

Modification accepts:

- Contents for a regular file.
- Filename.
- Parent item identifier.
- Any supported combination of those fields in one callback.

Filename and contents are committed together. Unsupported metadata-only fields
are returned as `stillPendingFields` while supported fields are applied. If the
callback contains only unsupported fields, Remux returns the current
authoritative item with those fields still pending.

A symbolic-link creation is refused without touching the remote filesystem.
Any direct symbolic-link modification or deletion request fails with a stable
cannot-synchronize error even though the UI does not advertise those actions.

## Path and Type Safety

All source and destination paths are derived from stable item identifiers and
validated child names; callers cannot submit raw remote paths.

Before every operation, Remux:

1. Resolves the canonical remote home.
2. Resolves and containment-checks each existing parent directory.
3. Validates each new leaf name as one path component.
4. Reads link-aware metadata without following the final component.
5. Rejects unsupported special files and symbolic links.

Move-cycle validation is performed against the latest identity hierarchy before
SFTP rename. A directory cannot move into itself or one of its descendants.

Temporary upload names are hidden, validated sibling names containing a random
nonce. They never appear in a File Provider snapshot.

## Remote Mutation Operations

The shared SFTP client gains the smallest structured operations required by the
provider:

- Create one directory.
- Upload a local file to a new remote path with progress.
- Rename a file or directory.
- Remove one regular file.
- Remove one empty directory using SFTP `rmdir`.

These operations remain separately testable and reuse the existing timeout and
lease lifecycle.

### Create File

1. Validate that the parent exists and is a directory.
2. Reject an occupied destination with File Provider's filename-collision
   error, unless a replay receipt proves this request already committed.
3. Allocate and persist the provider identifier and create-template replay
   alias.
4. Upload contents to a hidden temporary sibling.
5. Rename the temporary file to the final destination.
6. Read the final link-aware metadata and record the parent snapshot.
7. Persist a completion receipt, then complete with the authoritative item.

If no contents URL is supplied for a genuinely new regular file, Remux uploads
an empty file. A dataless `mayAlreadyExist` reimport is matched only when the
persisted replay alias or identity mapping proves the item already exists.

### Create Directory

Directory creation follows the same collision, identity, replay, authoritative
metadata, and snapshot rules, using one SFTP directory-create request.

### Modify File Contents

1. Resolve the stable identifier to its current remote path.
2. Read current remote metadata and perform the version-conflict check.
3. Validate the requested destination when filename or parent also changed.
4. Upload new contents to a hidden temporary sibling in the destination
   directory.
5. Rename the temporary file into the final destination.
6. If the server refuses replacement-by-rename, fail while preserving the old
   destination. Remux must not delete the old file as a fallback.
7. When the destination differs from the source, remove the old source only
   after the new destination has committed.
8. Read authoritative metadata, preserve the stable identifier at its new path,
   and record every affected parent snapshot.

The provider does not claim `NSExtensionFileProviderAppliesChangesAtomically`.
SFTP server rename behavior is qualified against supported hosts, but Remux
never truncates an existing remote file in place.

### Rename or Move Without Contents

After conflict, collision, containment, and cycle checks, Remux performs one
SFTP rename. It retains the item identifier, updates its mapped path, and
refreshes both the old and new parent snapshots before completing.

Moving a directory updates the persisted paths of every known descendant while
retaining their identifiers. Descendants not yet known to File Provider are
discovered normally when the destination is enumerated.

### Delete

Deleting an already absent item succeeds idempotently.

For a regular file, Remux checks the base version and removes that file.

For a directory, Remux lists it immediately before deletion:

- If it contains any item, deletion fails with
  `NSFileProviderError.directoryNotEmpty`.
- If it is empty, Remux removes it using SFTP `rmdir`.

This rule applies even when File Provider supplies its recursive-delete option.
Remux never recursively traverses or partially deletes a directory. A
successful delete removes the identity mapping, prunes tracked descendant
snapshots, records the parent snapshot, and persists a replay receipt before
completion.

## Conflict and Collision Policy

The remote host is authoritative.

For modify and delete callbacks, Remux compares the supplied base content and
metadata versions with freshly read remote metadata. If the remote item changed,
Remux does not overwrite or delete it.

- A modify request with `failOnConflict` fails as required by File Provider.
- Other conflicting modifications return the latest remote item and request
  that File Provider fetch current content when necessary.
- A conflicting deletion fails with File Provider's deletion-rejected error.
- A non-empty-directory deletion fails with directory-not-empty.
- An occupied create, rename, or move destination fails with a filename
  collision so File Provider can choose a bounced name.

Remux does not merge file contents or pick a local-wins resolution.

## Replay and Completion Receipts

File Provider may replay creation and modification after extension or system
failure. The persistent identity/snapshot state therefore keeps a bounded set
of completion receipts.

A receipt contains only non-secret structured state:

- Operation kind.
- Replay key: create-template alias, or stable item identifier plus base
  version and changed-field set.
- Resulting item identifier and versions, or confirmed deletion.
- A bounded generation number used for retention.

The receipt is saved after the authoritative remote result and snapshots are
stored, but before the completion handler is called. A replay returns that
result without repeating the remote mutation.

Receipts are pruned after a bounded number of later snapshot generations.
Pending upload contents and credentials are never persisted in receipts.

No protocol can eliminate an ambiguous network failure between a remote server
commit and the follow-up metadata read. On retry, Remux inspects the remote path,
identity mapping, and replay alias before deciding whether to continue, report
success, or surface a conflict. It never resolves ambiguity by blindly
overwriting or deleting an existing remote item.

## Snapshot and Signal Semantics

The domain operation coordinator serializes:

- Remote directory refresh plus snapshot recording.
- Create, modify, move, rename, and delete transactions.

This prevents an older directory listing from being recorded after a newer
mutation.

Successful local mutations advance persisted snapshot state but do not enqueue a
duplicate remote-change signal: File Provider already knows the local operation
through its callback. Subsequent genuinely remote changes still enter the
existing persisted working-set signal path.

Changing a directory into a file, deleting a directory, or moving a known
directory prunes or relocates tracked descendant snapshots in the same
generation as the parent changes.

## Progress, Cancellation, and Invalidation

Each File Provider mutation uses the existing request controller to guarantee
one completion.

- File upload progress reflects bytes sent from the supplied contents URL.
- Cancelling before remote commit stops work, cleans the temporary file when
  reachable, and completes with `NSUserCancelledError`.
- Once the final remote rename or removal commits, cancellation cannot report
  that the remote mutation did not happen. Remux completes from the committed
  result or its receipt.
- Extension invalidation cancels queued work, drains active mutation and
  enumeration operations, then closes idle SSH/SFTP connections.

Known temporary files are removed on cancellation and failure. Cleanup failures
are logged without paths containing credentials or file contents and are
retried when the same operation is replayed.

## Error Mapping

The writable provider adds stable mappings for:

- Remote permission failure: Cocoa write-no-permission.
- Destination collision: File Provider filename-collision.
- Missing source or parent: File Provider no-such-item with the applicable
  identifier.
- Base-version deletion conflict: File Provider deletion-rejected.
- Non-empty directory: File Provider directory-not-empty.
- Unsupported symbolic-link mutation or unsynchronizable field combination:
  File Provider cannot-synchronize.
- Authentication, host trust, timeout, network, cancellation, and unknown
  errors: the existing sanitized mappings.

Errors and logs never include passwords, private keys, file contents, or raw
credential records.

## Test Strategy

Tests exercise structured operations and observable behavior rather than
matching generated commands or large serialized values.

### Unit and Contract Tests

- Stable identity allocation, lookup, local move retention, external
  delete-plus-create, non-reuse, and simulator-reset assumptions.
- Create-template alias and bounded completion-receipt replay.
- Capability projection by root, regular directory, regular file, and symlink.
- Supported and unsupported field partitioning.
- Conflict, collision, cycle, containment, and type validation.
- Create file, create directory, content replacement, combined
  content-and-rename, move, rename, file deletion, empty-directory deletion,
  and non-empty-directory rejection.
- Recursive-delete option still rejects a non-empty directory without removing
  children.
- Poll/mutation serialization and stale-refresh prevention.
- Local snapshot updates do not create duplicate working-set signals.
- Upload progress, cancellation before commit, cancellation after commit,
  temporary cleanup, one completion, and extension invalidation.
- Every new error mapping is sanitized and contains the required File Provider
  item metadata.

### SFTP Integration Tests

All destructive tests operate beneath a uniquely created disposable remote test
directory.

- Upload and download round trip.
- Safe replacement of an existing regular file.
- Server behavior when rename targets an existing path.
- File and directory rename and move.
- Empty `rmdir`.
- Non-empty directory rejection with every child preserved.
- Permission-denied behavior.
- Connection loss and cancellation leave the previous destination intact.

Tests never target the authenticated user's home root directly and never use
recursive cleanup outside the unique test directory.

### Simulator Qualification

Qualification uses fresh writable domains for at least one password-authenticated
and one private-key-authenticated server.

In Files and at least one document-based editor:

1. Create and reopen a text file.
2. Modify and save it through an editor that uses temporary-file rename.
3. Rename and move the file.
4. Create, rename, and move an empty directory.
5. Delete a file and an empty directory.
6. Confirm non-empty-directory deletion fails and preserves every child.
7. Confirm a remote agent edit is not silently overwritten by a stale local
   save.
8. Confirm remote files created during the session still appear through
   polling.
9. Cancel a large upload and confirm the previous remote destination remains
   intact.
10. Relaunch the extension and verify request replay does not duplicate or
    repeat a completed mutation.
11. Confirm symlink and metadata-only mutations do not succeed.

## Rollout

Writable support replaces the unshipped read-only behavior before release.
There is no production compatibility mode or migration.

Release gates are:

- Focused writable-provider tests pass.
- The complete Remux test suite passes.
- App and extension entitlements and embedded products remain correct.
- Disposable-host SFTP mutation tests pass.
- Simulator Files and document-editor qualification passes.
- No private read-only configuration remains in the built extension.

Physical-device qualification remains a required release gate if simulator and
device File Provider behavior differ.
