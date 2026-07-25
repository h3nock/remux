# Read-Only SSH File Provider Design

**Status:** Approved for implementation
**Date:** 2026-07-24

## Context

Remux already stores SSH server profiles, host-key trust, and either password or
private-key credentials. It also has SFTP primitives used by terminal file
transfer. This feature exposes each eligible saved server as a location in the
iOS Files app without requiring Remux to be running or an interactive terminal
session to remain connected.

The first version is deliberately read-only. Its primary use case is browsing
and opening files created on a remote host, including files created by coding
agents while the Files directory is open.

## Goals

- Show each eligible saved SSH server as an independent Files location.
- Start the location at the authenticated user's remote home directory.
- Support the password and private-key authentication modes Remux already
  stores.
- List directories and download files without modifying the remote host.
- Reflect files created during an active Files session within ten seconds.
- Reuse Remux's SSH implementation, profile model, trust policy, and credential
  parsing rather than introducing a second SSH stack.
- Keep credentials device-local and out of snapshots and logs.

## Non-Goals

- Uploading, creating, renaming, moving, or deleting remote items.
- Partial-content fetching or streaming a requested byte range.
- Remote search.
- A host-side agent or push notification service.
- A custom File Provider authentication or recovery UI.
- Allowing the extension to accept or change an SSH host key.

## Architecture

Remux will add an `NSFileProviderReplicatedExtension` target. Each saved server
that is eligible for file access maps to one `NSFileProviderDomain`:

- The domain identifier is derived from the stable server UUID.
- The display name is the saved server name.
- The domain root is the canonical path returned by `realpath(".")` after
  authentication.

The app owns domain reconciliation. When saved servers or their usable
credentials change, it compares the desired domain set with the registered
domains and adds, updates, or removes domains as needed.

The extension owns independent, short-lived SSH/SFTP connections. It never
borrows an app terminal connection and does not require the app process to be
running. Existing SSH and storage source files that are safe in an extension
will be included in both targets; this version does not introduce a separate
framework.

## Shared Storage and Migration

The app and extension share non-secret state through an App Group container:

- Saved server profiles required to establish a connection.
- Known-host entries required to verify the server.
- Schema and migration state.

Credentials are shared through a Keychain access group:

- Passwords remain Keychain generic-password values.
- Private keys remain Keychain data in their current representation.
- The extension reads credentials but never creates, edits, or deletes them.

The app performs a one-time, idempotent migration of existing profiles,
known-host entries, and credentials into the shared stores. Migration rules are:

1. Existing values remain authoritative during the migration transaction.
2. A successfully copied item is verified before the migration marker advances.
3. Re-running migration does not duplicate or replace an already equivalent
   shared item.
4. Failure leaves the source intact and keeps the migration retryable.
5. Once migration completes, both the app and extension use the shared stores.

This is an intentional one-time compatibility path for already configured
Remux installations.

## Domain Eligibility

A server receives a File Provider domain only when all of the following are
true:

- The server has a stable saved-server identifier.
- A supported stored credential is available.
- A matching host key is already trusted.

The extension never presents an interactive password prompt and never accepts a
new or changed host key. A missing or rejected credential, unknown host key, or
changed host key makes the domain unavailable with an authentication error.

## SFTP Capabilities

The shared SFTP layer will gain the smallest general-purpose operations needed
by the provider:

- List one directory with file name and metadata.
- Read an item's link-aware attributes without automatically following a
  symbolic link. The pinned Citadel API supplies these attributes through the
  parent directory listing rather than a public `lstat` call.
- Resolve a symbolic link to its canonical target with SFTP `realpath`.
- Download a regular file in bounded chunks to a supplied local URL.
- Support cancellation and preserve existing operation timeouts.

These operations return structured values. Tests exercise their behavior
against an SFTP server rather than matching generated command or packet text.

## Paths and Symbolic Links

Every provider item is addressed by a normalized remote path beneath the
canonical home root. Path components that escape the root are rejected.

The provider exposes:

- Regular files.
- Directories.
- Dotfiles.
- Symbolic links whose fully resolved target remains beneath the home root.

It hides sockets, devices, FIFOs, cyclic links, and links that resolve outside
the home root. Safe symbolic links use the canonical in-root target as File
Provider symbolic-link metadata rather than being silently converted into
unrelated regular files. This avoids adding a custom Citadel fork solely to
expose raw `lstat` and `readlink` request wrappers.

## Item Identity and Versions

Item identifiers are deterministic encodings of normalized remote paths. The
root uses `NSFileProviderItemIdentifier.rootContainer`. Because the provider is
read-only, a remote rename is observed as deletion of the old item and creation
of the new item.

Versions are derived without reading all file contents:

- Content version: item type, size, and modification time.
- Metadata version: normalized path, display name, permissions, item type,
  size, and modification time.

This accepts the normal SFTP limitation that a same-size rewrite preserving the
same timestamp may not be detected. Hashing every remote file is outside the
scope of this version.

## Enumeration, Snapshots, and Change Detection

Directory enumerators list the current remote directory and compare the result
with a persisted snapshot. Snapshots contain only normalized paths and remote
metadata; they contain no credentials or file contents.

An active enumerator polls every five seconds:

- Only one poll per domain runs at a time.
- Concurrent requests are coalesced.
- A changed snapshot advances the domain generation and signals both the
  affected directory and the working set.
- Invalidation cancels the timer and any in-flight operation.
- If iOS suspends the extension, enumeration refreshes immediately when the
  location is reopened.

The snapshot store keeps a bounded number of recent generations. A request
using an evicted anchor returns `syncAnchorExpired`, causing Files to enumerate
again from a current snapshot.

The acceptance target is that a file created remotely while its containing
directory is open in Files appears within ten seconds. If the extension is
suspended, it must appear when the directory is reopened.

## Content Fetching

`fetchContents` downloads the entire regular file into a temporary local URL
using bounded SFTP reads. It reports progress, responds to cancellation, and
cleans up incomplete temporary files. The File Provider runtime receives the
completed URL and item metadata.

Directories, unsupported special files, unsafe links, and missing paths do not
produce content URLs.

## Error Mapping

SSH and SFTP failures map to stable File Provider errors:

- DNS, connection, timeout, offline, and sleeping-host failures:
  `serverUnreachable`.
- Missing or rejected credentials and unknown or changed host keys:
  `notAuthenticated`.
- A removed remote path: a `noSuchItem` error containing the requested item
  identifier.
- Every mutation request: a write-permission error.
- An evicted snapshot generation: `syncAnchorExpired`.

Errors shown by Files must not include passwords, private-key material, or raw
credential records.

## Security and Trust Boundaries

- SSH host-key verification remains mandatory.
- Only the containing app can add or change trusted host keys.
- The extension has read-only access to the shared credential records.
- The extension never writes to the remote filesystem.
- App Group state and diagnostic logs exclude secrets.
- Remote paths are normalized and checked against the domain root before every
  operation.

## Test Strategy

Development proceeds in four independently testable slices:

1. Shared storage, idempotent migration, and domain reconciliation.
2. SFTP listing, link-aware metadata, canonical link handling, and cancellable
   download.
3. Read-only File Provider items, enumeration, versions, and content fetching.
4. Snapshot deltas, polling, error mapping, and simulator qualification.

Automated tests cover:

- Successful migration, retry after partial failure, and idempotency.
- Domain eligibility and reconciliation.
- Path normalization, escape rejection, item identifiers, metadata, and
  versions.
- Snapshot comparison, bounded retention, and expired anchors.
- Error mapping and read-only mutation rejection.
- Real SFTP listing including dotfiles, safe and unsafe symbolic links,
  downloads, cancellation, and missing paths.
- Existing Remux unit and integration tests.

Simulator qualification uses at least one password-authenticated and one
private-key-authenticated saved server. The Files app must:

- Show both locations.
- Browse directories and open a file.
- Show a remotely created file within ten seconds while its directory remains
  open.
- Offer no successful mutation path.
- Leave known-host state unchanged.

## Rollout

The feature ships enabled for eligible saved servers after successful
migration. A server that becomes ineligible remains saved in Remux but its File
Provider domain is removed until its credential and trusted host key are
restored.

Write support, remote search, partial fetching, push-driven invalidation, and
custom recovery UI remain explicit follow-up work.
