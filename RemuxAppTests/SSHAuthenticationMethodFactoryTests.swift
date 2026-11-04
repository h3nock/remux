@preconcurrency import Citadel
import CryptoKit
import LocalAuthentication
import NIOCore
import NIOEmbedded
import NIOPosix
@preconcurrency import NIOSSH
import UIKit
import XCTest
@testable import Remux

final class SSHAuthenticationMethodFactoryTests: XCTestCase {
    func testNoneDelegateOffersNoneAuthenticationExactlyOnce() async throws {
        let eventLoop = EmbeddedEventLoop()
        let delegate = NoneSSHAuthenticationDelegate(username: "demo")
        let firstOffer = eventLoop.makePromise(
            of: NIOSSHUserAuthenticationOffer?.self
        )

        delegate.nextAuthenticationType(
            availableMethods: [],
            nextChallengePromise: firstOffer
        )

        let offer = try await firstOffer.futureResult.get()
        XCTAssertEqual(offer?.username, "demo")
        guard let offer, case .none = offer.offer else {
            return XCTFail("expected SSH none authentication")
        }

        let secondOffer = eventLoop.makePromise(
            of: NIOSSHUserAuthenticationOffer?.self
        )
        delegate.nextAuthenticationType(
            availableMethods: [],
            nextChallengePromise: secondOffer
        )

        do {
            _ = try await secondOffer.futureResult.get()
            XCTFail("expected the delegate to reject a second offer")
        } catch SSHClientError.allAuthenticationOptionsFailed {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A login to a server whose key on this device the user hasn't approved stops before it connects, at the
    /// locked key, so nothing that comes after joins it; one the user approved goes on to connect.
    @MainActor
    func testALoginStopsBeforeConnectingUntilTheUserApprovesTheServer() async throws {
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.close(promise: nil)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { listener.close(promise: nil) }
        let port = try XCTUnwrap(listener.localAddress?.port)
        let approvals = DeviceKeyFixture.approvals(evaluate: { _, _ in })
        let target = DeviceKeyFixture.target(server: SavedServer(
            displayName: "Mac mini",
            host: "127.0.0.1",
            port: port,
            username: "test",
            identityID: UUID()
        ))
        let check = try XCTUnwrap(approvals.check(for: target))
        let configuration = RemuxSSHRootConfiguration(
            host: "127.0.0.1",
            port: port,
            loginPrecondition: { try check.requireApproval() },
            authenticationMethod: { try SSHAuthenticationMethodFactory.make(username: "test", credential: .none) },
            hostKeyValidator: .acceptAnything(),
            connectTimeout: .seconds(2)
        )

        do {
            _ = try await RemuxSSHRootBootstrap.authenticate(using: configuration, trace: RemuxTransportStartupTrace(flowID: nil))
            XCTFail("a login the user hasn't approved logged in")
        } catch {
            XCTAssertEqual(error as? SSHKeyApprovalError, .required)
        }

        try await approvals.approve(check.scope, serverName: "Mac mini")
        do {
            _ = try await RemuxSSHRootBootstrap.authenticate(using: configuration, trace: RemuxTransportStartupTrace(flowID: nil))
            XCTFail("the listener closes every connection")
        } catch {
            XCTAssertNil(error as? SSHKeyApprovalError, "an approved login stopped at the key: \(error)")
        }
    }

    /// A key that asks for the user itself on every use can't log in without a prompt in the middle of a login,
    /// and one the Secure Enclave can't use here, as with any in the simulator, needs replacing.
    func testADeviceKeyThatCantSignHereNeedsReplacing() {
        for key in [
            SecureEnclaveSSHKey(representation: Data([1]), publicKey: DeviceKeyFixture.publicKey, signsWithoutPrompt: false),
            SecureEnclaveSSHKey(representation: Data([1]), publicKey: DeviceKeyFixture.publicKey),
        ] {
            XCTAssertThrowsError(try SSHAuthenticationMethodFactory.make(
                username: "test",
                credential: DeviceKeyFixture.target(key: key).sshAuth.credential
            )) { XCTAssertEqual($0 as? SecureEnclaveSSHError, .keyUnusable, "\(key.signsWithoutPrompt)") }
        }
    }
}

@MainActor
final class SecureEnclaveSSHApprovalsTests: XCTestCase {
    private struct Hold {
        let started: XCTestExpectation
        let answer: AsyncStream<Result<Void, Error>>
        let reply: AsyncStream<Result<Void, Error>>.Continuation
    }

    /// One approval covers every later login to its server: asking again doesn't bring up another prompt.
    func testApprovingAServerOnceCoversItsLaterLogins() async throws {
        var prompts: [String] = []
        let approvals = DeviceKeyFixture.approvals(evaluate: { _, reason in prompts.append(reason) })
        let scope = try DeviceKeyFixture.scope(approvals)

        try await approvals.approve(scope, serverName: "Mac mini")
        try await approvals.approve(scope, serverName: "Mac mini")

        XCTAssertTrue(approvals.isApproved(scope))
        XCTAssertEqual(prompts, ["Connect to Mac mini"])
    }

    /// Requests for one server while its prompt is up share it, and one that stops waiting leaves it to the
    /// others.
    func testRequestsForOneServerShareItsPrompt() async throws {
        let hold = makeHold()
        var prompts = 0
        let approvals = DeviceKeyFixture.approvals(evaluate: { _, _ in
            prompts += 1
            hold.started.fulfill()
            for await answer in hold.answer { return try answer.get() }
        })
        let scope = try DeviceKeyFixture.scope(approvals)

        let leaving = Task { try await approvals.approve(scope, serverName: "Mac mini") }
        let staying = Task { try await approvals.approve(scope, serverName: "Mac mini") }
        await fulfillment(of: [hold.started], timeout: 3)
        leaving.cancel()
        hold.reply.yield(.success(()))

        try await staying.value
        XCTAssertTrue(approvals.isApproved(scope))
        XCTAssertEqual(prompts, 1)
    }

    /// The device shows one prompt at a time: a second server's prompt waits for the first one's answer.
    func testServersTakeTurns() async throws {
        let hold = makeHold()
        var order: [String] = []
        let approvals = DeviceKeyFixture.approvals(evaluate: { _, reason in
            order.append(reason)
            guard reason == "Connect to Mac mini" else { return }
            hold.started.fulfill()
            for await answer in hold.answer { return try answer.get() }
        })
        let first = try DeviceKeyFixture.scope(approvals)
        let second = try DeviceKeyFixture.scope(approvals, host: "build.example.test")

        let firstApproval = Task { try await approvals.approve(first, serverName: "Mac mini") }
        await fulfillment(of: [hold.started], timeout: 3)
        let secondApproval = Task { try await approvals.approve(second, serverName: "Build Host") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(order, ["Connect to Mac mini"], "two prompts at once")

        hold.reply.yield(.success(()))
        try await firstApproval.value
        try await secondApproval.value
        XCTAssertEqual(order, ["Connect to Mac mini", "Connect to Build Host"])
        XCTAssertTrue(approvals.isApproved(second))
    }

    /// Locking the device, reported as protected data going away or, after a lock Remux slept through, coming
    /// back, ends every approval; the next request asks again.
    func testLockingTheDeviceEndsEveryApproval() async throws {
        var prompts = 0
        let center = NotificationCenter()
        let approvals = DeviceKeyFixture.approvals(center: center, evaluate: { _, _ in prompts += 1 })
        let first = try DeviceKeyFixture.scope(approvals)
        let second = try DeviceKeyFixture.scope(approvals, host: "build.example.test")

        for notification in [
            UIApplication.protectedDataWillBecomeUnavailableNotification,
            UIApplication.protectedDataDidBecomeAvailableNotification,
        ] {
            try await approvals.approve(first, serverName: "Mac mini")
            try await approvals.approve(second, serverName: "Build Host")
            center.post(name: notification, object: nil)
            XCTAssertFalse(approvals.isApproved(first), "\(notification.rawValue)")
            XCTAssertFalse(approvals.isApproved(second), "\(notification.rawValue)")
        }
        XCTAssertEqual(prompts, 4)
    }

    /// An answer that comes after the device locked grants nothing: the lock ended the approval it would give.
    func testAnAnswerAfterTheDeviceLockedGrantsNothing() async throws {
        let hold = makeHold()
        let center = NotificationCenter()
        let approvals = DeviceKeyFixture.approvals(center: center, evaluate: { _, _ in
            hold.started.fulfill()
            for await answer in hold.answer { return try answer.get() }
        })
        let scope = try DeviceKeyFixture.scope(approvals)

        let approval = Task { try await approvals.approve(scope, serverName: "Mac mini") }
        await fulfillment(of: [hold.started], timeout: 3)
        center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        hold.reply.yield(.success(()))

        let result = await approval.result
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? SSHKeyApprovalError, .required) }
        XCTAssertFalse(approvals.isApproved(scope))
    }

    /// No prompt over another app, or while the device is locked and the key can't be used.
    func testNoPromptOverAnotherAppOrWhileTheDeviceIsLocked() async throws {
        for (isActive, isProtectedDataAvailable) in [(false, true), (true, false)] {
            let approvals = SecureEnclaveSSHApprovals(
                notificationCenter: NotificationCenter(),
                isActive: { isActive },
                isProtectedDataAvailable: { isProtectedDataAvailable },
                evaluate: { _, _ in XCTFail("prompted") }
            )
            let scope = try DeviceKeyFixture.scope(approvals)
            do {
                try await approvals.approve(scope, serverName: "Mac mini")
                XCTFail("expected the approval to wait for the user")
            } catch {
                XCTAssertEqual(error as? SSHKeyApprovalError, .required)
            }
            XCTAssertFalse(approvals.isApproved(scope))
        }
    }

    /// iOS's prompt retries a face or finger it didn't recognize itself; Remux doesn't bring up another one for
    /// a prompt the user cancelled.
    func testACancelledPromptIsntAskedAgain() async throws {
        var prompts = 0
        let approvals = DeviceKeyFixture.approvals(evaluate: { _, _ in
            prompts += 1
            throw LAError(.userCancel)
        })
        let scope = try DeviceKeyFixture.scope(approvals)

        do {
            try await approvals.approve(scope, serverName: "Mac mini")
            XCTFail("expected the cancelled prompt")
        } catch {
            XCTAssertEqual((error as? LAError)?.code, .userCancel)
        }
        XCTAssertEqual(prompts, 1)
        XCTAssertFalse(approvals.isApproved(scope))
    }

    /// An approval covers one server's address and account with one key: changing any of them needs another.
    func testAnotherAddressAccountOrKeyNeedsItsOwnApproval() async throws {
        let approvals = DeviceKeyFixture.approvals(evaluate: { _, _ in })
        let target = DeviceKeyFixture.target()
        let scope = try XCTUnwrap(approvals.check(for: target)?.scope)
        try await approvals.approve(scope, serverName: "Mac mini")

        let otherKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let others = [
            DeviceKeyFixture.target(server: SavedServer(
                id: target.server.id,
                displayName: "Mac mini",
                host: "mac-mini.local",
                port: 2222,
                username: "test",
                identityID: target.server.identityID
            )),
            DeviceKeyFixture.target(server: target.server, username: "admin"),
            DeviceKeyFixture.target(
                server: target.server,
                key: SecureEnclaveSSHKey(representation: Data([2]), publicKey: otherKey)
            ),
            DeviceKeyFixture.target(),
        ]
        XCTAssertTrue(try XCTUnwrap(approvals.check(for: target)).isApproved)
        for other in others {
            XCTAssertFalse(try XCTUnwrap(approvals.check(for: other)).isApproved, "\(other.server) \(other.sshAuth.username)")
        }
        XCTAssertNil(approvals.check(for: SessionTarget(
            server: target.server,
            workspace: target.workspace,
            sshAuth: .password(username: "test", password: "secret", identityID: UUID(), displayLabel: "test")
        )))
    }

    private func makeHold() -> Hold {
        let (answer, reply) = AsyncStream<Result<Void, Error>>.makeStream()
        return Hold(started: expectation(description: "prompt shown"), answer: answer, reply: reply)
    }
}

/// A server whose key was made on the device, with approvals that prompt through the test's `evaluate`.
enum DeviceKeyFixture {
    static let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation

    static func target(
        server: SavedServer = SavedServer(
            displayName: "Mac mini",
            host: "mac-mini.local",
            username: "test",
            identityID: UUID()
        ),
        username: String = "test",
        key: SecureEnclaveSSHKey = SecureEnclaveSSHKey(representation: Data([1]), publicKey: publicKey)
    ) -> SessionTarget {
        SessionTarget(
            server: server,
            workspace: SavedWorkspace(serverID: server.id, sessionName: "main"),
            sshAuth: try! ResolvedSSHAuth.privateKey(
                username: username,
                credential: SSHPrivateKeyCredential(privateKeyPEM: "", secureEnclaveKey: key),
                identityID: server.identityID,
                displayLabel: server.displayName
            )
        )
    }

    static func scope(
        _ approvals: SecureEnclaveSSHApprovals,
        host: String = "mac-mini.local"
    ) throws -> SecureEnclaveSSHApprovals.Scope {
        try XCTUnwrap(approvals.check(for: target(server: SavedServer(
            displayName: host,
            host: host,
            username: "test",
            identityID: UUID()
        )))?.scope)
    }

    static func approvals(
        center: NotificationCenter = NotificationCenter(),
        evaluate: @escaping SecureEnclaveSSHApprovals.Evaluate
    ) -> SecureEnclaveSSHApprovals {
        SecureEnclaveSSHApprovals(
            notificationCenter: center,
            isActive: { true },
            isProtectedDataAvailable: { true },
            evaluate: evaluate
        )
    }
}
