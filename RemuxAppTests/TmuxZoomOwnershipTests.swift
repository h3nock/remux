import Combine
import Foundation
import XCTest

@testable import Remux

@MainActor
final class TmuxZoomOwnershipTests: XCTestCase {
    private let owner = TmuxZoomOwner(
        serverID: UUID(uuidString: "0D9F2A6C-5E1B-4C07-9A3D-8B6E2F4C1A75")!
    )

    func testClaimMarksTheWindowOnlyIfItsCommandLineCreatesTheZoom() {
        XCTAssertEqual(
            owner.claimCommand(windowID: 3),
            "set-option -F -w -t @3 @remux-zoom-owner "
                + "'#{?#{||:#{window_zoomed_flag},#{==:#{window_panes},1}},#{@remux-zoom-owner},"
                + "0D9F2A6C-5E1B-4C07-9A3D-8B6E2F4C1A75}'"
        )
    }

    func testForgetClearsOnlyThisOwnersMarkOfAnUnzoomedWindow() {
        XCTAssertEqual(
            owner.forgetCommand(windowID: 3),
            "set-option -F -w -t @3 @remux-zoom-owner "
                + "'#{?#{&&:#{==:#{@remux-zoom-owner},0D9F2A6C-5E1B-4C07-9A3D-8B6E2F4C1A75},"
                + "#{!=:#{window_zoomed_flag},1}},,#{@remux-zoom-owner}}'"
        )
    }

    func testReadbackHasTheMarksQueryLineShape() {
        XCTAssertEqual(
            owner.readbackCommand(windowID: 3),
            "display-message -p -t @3 '#{window_id} #{window_zoomed_flag} #{@remux-zoom-owner}'"
        )
        XCTAssertEqual(
            owner.marks(fromQueryReply: "@3 1 \(owner.id)\n"),
            [TmuxZoomMark(windowID: 3, zoomed: true, isOwn: true)]
        )
        XCTAssertEqual(
            owner.marks(fromQueryReply: "@3 0 \n"),
            [TmuxZoomMark(windowID: 3, zoomed: false, isOwn: false)]
        )
    }

    func testMarksReplyDistinguishesOwnOtherAndUnmarkedWindows() {
        let reply = """
        @0 1 \(owner.id)
        @1 1 3C1E7B0A-0000-4000-8000-000000000000
        @2 0 \(owner.id)
        @3 0
        @4 1
        """

        XCTAssertEqual(owner.marks(fromQueryReply: reply), [
            TmuxZoomMark(windowID: 0, zoomed: true, isOwn: true),
            TmuxZoomMark(windowID: 1, zoomed: true, isOwn: false),
            TmuxZoomMark(windowID: 2, zoomed: false, isOwn: true),
            TmuxZoomMark(windowID: 3, zoomed: false, isOwn: false),
            TmuxZoomMark(windowID: 4, zoomed: true, isOwn: false),
        ])
    }

    func testMarksReplySkipsLinesThatAreNotWindowRecords() {
        let reply = "no windows\n@x 1 owner\n@5 2 owner\n@6 1 \(owner.id)\n"

        XCTAssertEqual(owner.marks(fromQueryReply: reply), [
            TmuxZoomMark(windowID: 6, zoomed: true, isOwn: true),
        ])
    }

    func testEveryZoomGroupWithoutAnOwnerLeavesOutTheMarks() {
        let commands = TmuxZoomCommands(owner: nil)

        XCTAssertEqual(
            commands.ensureZoomed(windowID: 1).commands,
            ["resize-pane -t @1", "resize-pane -Z -t @1"]
        )
        XCTAssertEqual(commands.ensureUnzoomed(windowID: 1).commands, ["resize-pane -t @1"])
        XCTAssertNil(commands.forgetAndReadback(windowID: 1))
        XCTAssertEqual(
            commands.split("split-window -h -t %0", windowID: 0, form: .creatingZoom).commands,
            ["split-window -h -t %0", "resize-pane -t @0", "resize-pane -Z -t @0"]
        )
        XCTAssertEqual(
            commands.closePaneOfZoomedWindow(paneID: 1, windowID: 0, leavesSeveralPanes: true).commands,
            ["kill-pane -t %1", "resize-pane -t @0", "resize-pane -Z -t @0"]
        )
    }

    func testTheDefaultLeavesAWindowWithAZoomInFlightForALaterTopology() {
        var policy = TmuxMultipaneZoomDefaultPolicy(isEnabled: true)
        let unzoomed = Self.policyTopology(zoomed: false)

        XCTAssertEqual(policy.windowIDsNeedingChange(in: unzoomed, zoomingWindowIDs: [1]), [])
        XCTAssertEqual(policy.windowIDsNeedingChange(in: unzoomed), [1])
        XCTAssertEqual(policy.windowIDsNeedingChange(in: unzoomed), [])
    }

    func testASettingChangeGoesToAWindowWithAZoomInFlightWhateverItsTopologyShows() {
        var policy = TmuxMultipaneZoomDefaultPolicy(isEnabled: true)
        let unzoomed = Self.policyTopology(zoomed: false)
        XCTAssertEqual(policy.windowIDsNeedingChange(in: unzoomed), [1])

        XCTAssertTrue(policy.setEnabled(false))
        XCTAssertEqual(policy.windowIDsNeedingChange(in: unzoomed, afterSettingChange: true), [])
        XCTAssertTrue(policy.setEnabled(true))
        XCTAssertTrue(policy.setEnabled(false))
        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: unzoomed, zoomingWindowIDs: [1], afterSettingChange: true),
            [1]
        )
    }

    // MARK: Case 1: attach with the default on

    func testAttachSendsNoZoomForASinglePaneWindow() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: true,
                windows: Self.window(0, active: true, pane: 0, layout: Self.single(0))
            )
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.marksQuery], version)
            await t.tearDown()
        }
    }

    func testAttachZoomsAnUnzoomedSplitBeforeLoadingItsPanes() async throws {
        for version in Self.versions {
            for splitIsCurrent in [false, true] {
                let t = try await ZoomTranscript.attach(
                    version: version,
                    zoomsByDefault: true,
                    windows: Self.window(0, active: !splitIsCurrent, pane: 0, layout: Self.single(0))
                        + Self.window(1, active: splitIsCurrent, pane: 1, layout: Self.split(1, 2))
                )
                let sent = t.sent()
                let label = "\(version), split current: \(splitIsCurrent)"
                XCTAssertEqual(Self.zoomLines(sent), [Self.ensureZoomed(1), Self.marksQuery], label)
                Self.assertBeforeTheFirstLoad(Self.ensureZoomed(1), in: sent, label)
                await t.tearDown()
            }
        }
    }

    func testAttachAdoptsAZoomedSplitCarryingThisOwnersMark() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: true,
                windows: Self.window(1, active: true, pane: 1, layout: Self.split(1, 2), zoomed: true)
            )
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.marksQuery], version)
            await t.answer { $0 == Self.marksQuery ? .ok("@1 1 \(Self.ownerID)\n") : .ok("") }
            XCTAssertEqual(Self.zoomLines(t.sent()), [], version)

            t.adapter.releaseZoomOwnership()
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureUnzoomed(1)], version)
            await t.tearDown()
        }
    }

    func testAttachNeitherClaimsNorReleasesAZoomedSplitWithoutThisOwnersMark() async throws {
        for version in Self.versions {
            for mark in ["", "3C1E7B0A-0000-4000-8000-000000000000"] {
                let t = try await ZoomTranscript.attach(
                    version: version,
                    zoomsByDefault: true,
                    windows: Self.window(1, active: true, pane: 1, layout: Self.split(1, 2), zoomed: true)
                )
                XCTAssertEqual(Self.zoomLines(t.sent()), [Self.marksQuery], version)
                await t.answer { $0 == Self.marksQuery ? .ok("@1 1 \(mark)\n") : .ok("") }

                t.adapter.releaseZoomOwnership()
                await t.settle()
                XCTAssertEqual(Self.zoomLines(t.sent()), [], "\(version), mark: \(mark)")
                await t.tearDown()
            }
        }
    }

    func testAttachForgetsThisOwnersMarkWhoseZoomIsGone() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: true,
                windows: Self.window(0, active: true, pane: 0, layout: Self.single(0))
            )
            _ = t.sent()
            await t.answer { $0 == Self.marksQuery ? .ok("@0 0 \(Self.ownerID)\n") : .ok("") }
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.forget(0)], version)
            await t.tearDown()
        }
    }

    // MARK: Case 2: attach with the default off

    func testAttachWithTheDefaultOffUnzoomsAZoomedSplitBeforeLoadingItsPanes() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: false,
                windows: Self.window(0, active: true, pane: 0, layout: Self.single(0))
                    + Self.window(1, active: false, pane: 1, layout: Self.split(1, 2), zoomed: true)
            )
            let sent = t.sent()
            XCTAssertEqual(Self.zoomLines(sent), [Self.ensureUnzoomed(1), Self.marksQuery], version)
            Self.assertBeforeTheFirstLoad(Self.ensureUnzoomed(1), in: sent, version)
            await t.tearDown()
        }
    }

    func testAttachWithTheDefaultOffLeavesAnUnzoomedSplitAlone() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: false,
                windows: Self.window(1, active: true, pane: 1, layout: Self.split(1, 2))
            )
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.marksQuery], version)
            await t.tearDown()
        }
    }

    // MARK: Case 3: several split windows at attach

    func testAttachZoomsEverySplitWindowInItsOwnCommandLineBeforeLoadingPanes() async throws {
        for version in Self.versions {
            for windowCount in [2, 6] {
                let windows = (0..<windowCount).map {
                    Self.window($0, active: $0 == 0, pane: 2 * $0, layout: Self.split(2 * $0, 2 * $0 + 1))
                }.joined()
                let t = try await ZoomTranscript.attach(version: version, zoomsByDefault: true, windows: windows)
                let sent = t.sent()
                let zooms = (0..<windowCount).map { Self.ensureZoomed($0) }
                XCTAssertEqual(Self.zoomLines(sent), zooms + [Self.marksQuery], "\(version), \(windowCount)")
                for zoom in zooms {
                    Self.assertBeforeTheFirstLoad(zoom, in: sent, "\(version), \(windowCount)")
                }
                await t.tearDown()
            }
        }
    }

    // MARK: Case 4: the setting changes while connected

    func testTurningTheDefaultOnAndOffWhileConnected() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: false,
                windows: Self.window(0, active: true, pane: 0, layout: Self.single(0))
                    + Self.window(1, active: false, pane: 1, layout: Self.split(1, 2))
            )
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.marksQuery], version)
            await t.answer()

            t.adapter.setZoomMultipaneWindowsByDefault(true)
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureZoomed(1)], version)
            await t.answer(Self.readbacks([1: "@1 1 \(Self.ownerID)"]))
            await t.receive(Self.layoutChange(1, Self.split(1, 2), zoomedOn: 1))
            XCTAssertEqual(Self.zoomLines(t.sent()), [], version)

            t.adapter.setZoomMultipaneWindowsByDefault(false)
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureUnzoomed(1)], version)
            await t.tearDown()
        }
    }

    func testASettingFlippedBackWhileItsZoomIsUnansweredIsSentAtOnce() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: false,
                windows: Self.window(0, active: true, pane: 0, layout: Self.single(0))
                    + Self.window(1, active: false, pane: 1, layout: Self.split(1, 2))
            )
            _ = t.sent()
            await t.answer()

            t.adapter.setZoomMultipaneWindowsByDefault(true)
            t.adapter.setZoomMultipaneWindowsByDefault(false)
            await t.settle()
            // The topology still shows the window unzoomed, as the setting
            // now asks; the zoom ahead of it is what tmux will have.
            XCTAssertEqual(
                Self.zoomLines(t.sent()),
                [Self.ensureZoomed(1), Self.ensureUnzoomed(1)],
                version
            )
            await t.tearDown()
        }
    }

    // MARK: Case 5: a window becomes split later

    func testAWindowSplitByAnotherClientIsZoomedOnceAndAgainAfterItsNextSplit() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: true,
                windows: Self.window(0, active: true, pane: 0, layout: Self.single(0))
                    + Self.window(1, active: false, pane: 2, layout: Self.single(2))
            )
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.marksQuery], version)
            await t.answer()

            await t.receive(Self.layoutChange(1, Self.split(2, 3)))
            var sent = t.sent()
            XCTAssertEqual(Self.zoomLines(sent), [Self.ensureZoomed(1)], version)
            XCTAssertTrue(sent.contains("capture-pane -p -P -C -t %3"), "the new pane was not loaded: \(sent)")
            Self.assertBeforeTheFirstLoad(Self.ensureZoomed(1), in: sent, version)

            await t.receive(Self.layoutChange(1, Self.split(2, 3)))
            XCTAssertEqual(Self.zoomLines(t.sent()), [], "a second topology zoomed again (\(version))")
            await t.answer(Self.readbacks([1: "@1 1 \(Self.ownerID)"]))
            await t.receive(Self.layoutChange(1, Self.split(2, 3), zoomedOn: 2))
            XCTAssertEqual(Self.zoomLines(t.sent()), [], version)

            // Closing a pane unzoomed the window; Remux's mark goes with it.
            await t.receive(Self.layoutChange(1, Self.single(2)))
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.forgetAndReadback(1)], version)
            await t.answer(Self.readbacks([1: "@1 0 "]))

            await t.receive(Self.layoutChange(1, Self.split(2, 4)))
            sent = t.sent()
            XCTAssertEqual(Self.zoomLines(sent), [Self.ensureZoomed(1)], version)
            Self.assertBeforeTheFirstLoad(Self.ensureZoomed(1), in: sent, version)
            await t.tearDown()
        }
    }

    // MARK: Case 6: another client unzooms a window Remux zoomed

    func testAnUnzoomByAnotherClientIsForgottenOnlyWhenTmuxSaysSo() async throws {
        for version in Self.versions {
            for readback in ["@1 0 ", "@1 1 \(Self.ownerID)"] {
                let t = try await Self.attachWithOwnedHiddenZoom(version: version)

                await t.receive(Self.layoutChange(1, Self.split(1, 2)))
                XCTAssertEqual(Self.zoomLines(t.sent()), [Self.forgetAndReadback(1)], version)
                await t.receive(Self.layoutChange(1, Self.split(1, 2)))
                XCTAssertEqual(Self.zoomLines(t.sent()), [], "the forget went out twice (\(version))")

                await t.answer(Self.readbacks([1: readback]))
                t.adapter.releaseZoomOwnership()
                await t.settle()
                // Remux never zooms the window again; it releases the zoom
                // only if tmux still reads it back as Remux's.
                XCTAssertEqual(
                    Self.zoomLines(t.sent()),
                    readback.hasSuffix(Self.ownerID) ? [Self.ensureUnzoomed(1)] : [],
                    "\(version), readback: \(readback)"
                )
                await t.tearDown()
            }
        }
    }

    func testAZoomIsStillRemuxsUntilTheForgetsReadbackArrives() async throws {
        for version in Self.versions {
            let t = try await Self.attachWithOwnedHiddenZoom(version: version)
            await t.receive(Self.layoutChange(1, Self.split(1, 2)))
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.forgetAndReadback(1)], version)

            t.adapter.releaseZoomOwnership()
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureUnzoomed(1)], version)
            await t.tearDown()
        }
    }

    // MARK: Case 7: a readback ahead of the topology that shows the zoom

    func testAReadbackAheadOfTheZoomedTopologyKeepsTheZoomRemuxsToRelease() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: true,
                windows: Self.window(1, active: true, pane: 1, layout: Self.split(1, 2))
            )
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureZoomed(1), Self.marksQuery], version)
            // tmux ran the zoom before the pane-state scan, so it reports
            // pane 1 at the window's width; the layout change is still to come.
            await t.answer { command in
                if command == Self.readback(1) { return .ok("@1 1 \(Self.ownerID)\n") }
                if command == Self.marksQuery { return .ok("@1 1 \(Self.ownerID)\n") }
                if command.hasPrefix("list-panes -s -F") {
                    return .ok(Self.paneState(1, width: 83) + Self.paneState(2, width: 41))
                }
                return .ok("")
            }
            // The scan's topology still shows the window unzoomed: tmux, not
            // the topology, decides the zoom is still there.
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.forgetAndReadback(1)], version)
            await t.answer(lines: 1, Self.readbacks([1: "@1 1 \(Self.ownerID)"]))

            t.adapter.releaseZoomOwnership()
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureUnzoomed(1)], version)
            await t.tearDown()
        }
    }

    // MARK: Case 8: splits

    func testASplitOfAWindowsOnlyPaneWithTheDefaultOnZoomsTheNewPaneWithoutSplitZoom() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: true,
                windows: Self.window(0, active: true, pane: 0, layout: Self.single(0))
            )
            _ = t.sent()
            await t.answer()

            t.controller.requestSplit(paneID: 0, direction: .right)
            await t.settle()
            let split = "split-window -h -t %0 ; \(Self.claim(0)) ; resize-pane -t @0 ; "
                + "resize-pane -Z -t @0 ; \(Self.readback(0))"
            XCTAssertEqual(Self.zoomLines(t.sent()), [split], version)

            // tmux's layout for the split, before its zoom shows, applies no
            // default of its own.
            await t.receive(Self.layoutChange(0, Self.split(0, 1)))
            XCTAssertEqual(Self.zoomLines(t.sent()), [], version)
            let splits = t.allSent.split(separator: "\n")
                .flatMap { $0.components(separatedBy: " ; ") }
                .filter { $0.hasPrefix("split-window") }
            XCTAssertEqual(splits, ["split-window -h -t %0"], version)
            await t.tearDown()
        }
    }

    func testASplitOfAZoomedWindowKeepsItZoomed() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: true,
                windows: Self.window(1, active: true, pane: 1, layout: Self.split(1, 2), zoomed: true)
            )
            _ = t.sent()
            await t.answer()

            t.controller.requestSplit(paneID: 1, direction: .down)
            await t.settle()
            XCTAssertEqual(
                Self.zoomLines(t.sent()),
                ["split-window -v -t %1 ; resize-pane -t @1 ; resize-pane -Z -t @1"],
                version
            )
            await t.tearDown()
        }
    }

    func testASplitWithoutTheDefaultsZoomIsPlain() async throws {
        for version in Self.versions {
            for layout in [Self.single(0), Self.split(0, 1)] {
                let t = try await ZoomTranscript.attach(
                    version: version,
                    zoomsByDefault: false,
                    windows: Self.window(0, active: true, pane: 0, layout: layout)
                )
                _ = t.sent()
                await t.answer()

                t.controller.requestSplit(paneID: 0, direction: .left)
                await t.settle()
                XCTAssertEqual(Self.zoomLines(t.sent()), ["split-window -h -b -t %0"], version)
                await t.tearDown()
            }
        }
    }

    func testOnlyAFailedSplitReportsAFailure() async throws {
        let t = try await ZoomTranscript.attach(
            version: "3.1",
            zoomsByDefault: true,
            windows: Self.window(0, active: true, pane: 0, layout: Self.single(0))
        )
        _ = t.sent()
        await t.answer()

        t.controller.requestSplit(paneID: 0, direction: .right)
        await t.settle()
        _ = t.sent()
        await t.answer { $0.hasPrefix("resize-pane -t") ? .error("no space for new pane") : .ok("") }
        XCTAssertNil(t.session.lastFailedRequest)

        t.controller.requestSplit(paneID: 0, direction: .right)
        await t.settle()
        _ = t.sent()
        await t.answer { $0.hasPrefix("split-window") ? .error("no space for new pane") : .ok("") }
        XCTAssertEqual(t.session.lastFailedRequest, .splitPane)
        await t.tearDown()
    }

    // MARK: Case 9: closing a pane of a zoomed window

    func testClosingAPaneOfAZoomedWindowZoomsItsSuccessor() async throws {
        for version in Self.versions {
            for layout in [Self.split(0, 1), Self.three(0, 1, 2)] {
                let t = try await ZoomTranscript.attach(
                    version: version,
                    zoomsByDefault: true,
                    windows: Self.window(0, active: true, pane: 0, layout: layout, zoomed: true)
                )
                _ = t.sent()
                await t.answer()

                t.controller.requestClosePane(paneID: 1)
                await t.settle()
                XCTAssertEqual(
                    Self.zoomLines(t.sent()),
                    ["kill-pane -t %1 ; resize-pane -t @0 ; resize-pane -Z -t @0 ; "
                        + "\(Self.forget(0)) ; \(Self.readback(0))"],
                    "\(version), \(layout)"
                )
                await t.tearDown()
            }
        }
    }

    func testAKillThatClosesTheWindowIsNoFailure() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: true,
                windows: Self.window(0, active: true, pane: 0, layout: Self.split(0, 1), zoomed: true)
                    + Self.window(1, active: false, pane: 2, layout: Self.single(2))
            )
            _ = t.sent()
            await t.answer()

            // Another client closed pane 1 first, so this kill closes the
            // window and the rezoom finds none.
            t.controller.requestClosePane(paneID: 0)
            await t.settle()
            _ = t.sent()
            await t.answer { $0.hasPrefix("resize-pane -t @0") ? .error("can't find window: @0") : .ok("") }
            XCTAssertNil(t.session.lastFailedRequest, version)
            XCTAssertEqual(t.session.state, .ready, version)
            await t.tearDown()
        }
    }

    func testAFailedKillReportsTheClose() async throws {
        let t = try await ZoomTranscript.attach(
            version: "3.1",
            zoomsByDefault: true,
            windows: Self.window(0, active: true, pane: 0, layout: Self.split(0, 1), zoomed: true)
        )
        _ = t.sent()
        await t.answer()

        t.controller.requestClosePane(paneID: 1)
        await t.settle()
        _ = t.sent()
        await t.answer { $0.hasPrefix("kill-pane") ? .error("can't find pane: %1") : .ok("") }
        XCTAssertEqual(t.session.lastFailedRequest, .closePane)
        await t.tearDown()
    }

    // MARK: Splits and closes while a zoom line is unanswered

    func testClosingAPaneWhileTheDefaultsZoomIsUnansweredKeepsTheWindowZoomed() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: true,
                windows: Self.window(0, active: true, pane: 0, layout: Self.three(0, 1, 2))
            )
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureZoomed(0), Self.marksQuery], version)

            // The topology shows the window unzoomed; tmux zooms it first.
            t.controller.requestClosePane(paneID: 1)
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.closeOfZoomedWindow(1, in: 0)], version)

            await t.answer { command in
                command == Self.readback(0) || command == Self.marksQuery
                    ? .ok("@0 1 \(Self.ownerID)\n")
                    : .ok("")
            }
            await t.receive(Self.layoutChange(0, Self.split(0, 2), zoomedOn: 0))
            XCTAssertEqual(Self.zoomLines(t.sent()), [], version)
            t.adapter.releaseZoomOwnership()
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureUnzoomed(0)], version)
            await t.tearDown()
        }
    }

    func testSplittingWhileTheDefaultsZoomIsUnansweredZoomsTheNewPane() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: true,
                windows: Self.window(0, active: true, pane: 0, layout: Self.split(0, 1))
            )
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureZoomed(0), Self.marksQuery], version)

            t.controller.requestSplit(paneID: 0, direction: .right)
            await t.settle()
            XCTAssertEqual(
                Self.zoomLines(t.sent()),
                ["split-window -h -t %0 ; resize-pane -t @0 ; resize-pane -Z -t @0"],
                version
            )

            await t.answer { command in
                command == Self.readback(0) || command == Self.marksQuery
                    ? .ok("@0 1 \(Self.ownerID)\n")
                    : .ok("")
            }
            await t.receive(Self.layoutChange(0, Self.three(0, 3, 1), zoomedOn: 3))
            XCTAssertEqual(Self.zoomLines(t.sent()), [], version)
            t.adapter.releaseZoomOwnership()
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureUnzoomed(0)], version)
            await t.tearDown()
        }
    }

    func testAnUnansweredUnzoomMakesTheNextSplitAndClosePlain() async throws {
        for version in Self.versions {
            for closes in [true, false] {
                let t = try await ZoomTranscript.attach(
                    version: version,
                    zoomsByDefault: true,
                    windows: Self.window(0, active: true, pane: 0, layout: Self.three(0, 1, 2), zoomed: true)
                )
                XCTAssertEqual(Self.zoomLines(t.sent()), [Self.marksQuery], version)
                await t.answer()
                t.adapter.setZoomMultipaneWindowsByDefault(false)
                await t.settle()
                XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureUnzoomed(0)], version)

                // The topology still shows the window zoomed; tmux unzooms it first.
                if closes {
                    t.controller.requestClosePane(paneID: 1)
                } else {
                    t.controller.requestSplit(paneID: 0, direction: .right)
                }
                await t.settle()
                XCTAssertEqual(
                    Self.zoomLines(t.sent()),
                    [closes ? "kill-pane -t %1" : "split-window -h -t %0"],
                    version
                )
                await t.tearDown()
            }
        }
    }

    func testAForgetInFlightLeavesTheSplitAndCloseToTheTopology() async throws {
        for version in Self.versions {
            for rezoomed in [false, true] {
                for closes in [true, false] {
                    let label = "\(version), rezoomed: \(rezoomed), closes: \(closes)"
                    let t = try await Self.attachWithOwnedHiddenZoom(version: version)
                    await t.receive(Self.layoutChange(1, Self.split(1, 2)))
                    XCTAssertEqual(Self.zoomLines(t.sent()), [Self.forgetAndReadback(1)], label)
                    if rezoomed {
                        // Another client zooms the window again while the forget is unanswered.
                        await t.receive(Self.layoutChange(1, Self.split(1, 2), zoomedOn: 1))
                        XCTAssertEqual(Self.zoomLines(t.sent()), [], label)
                    }

                    if closes {
                        t.controller.requestClosePane(paneID: 2)
                    } else {
                        t.controller.requestSplit(paneID: 1, direction: .right)
                    }
                    await t.settle()
                    let expected = switch (closes, rezoomed) {
                    case (true, true): Self.closeOfZoomedWindow(2, in: 1)
                    case (true, false): "kill-pane -t %2"
                    case (false, true): "split-window -h -t %1 ; resize-pane -t @1 ; resize-pane -Z -t @1"
                    case (false, false): "split-window -h -t %1"
                    }
                    XCTAssertEqual(Self.zoomLines(t.sent()), [expected], label)
                    await t.tearDown()
                }
            }
        }
    }

    // MARK: Case 10: the user zooms the focused pane

    func testTheUsersZoomOnAndOff() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: false,
                windows: Self.window(1, active: true, pane: 1, layout: Self.split(1, 2))
            )
            _ = t.sent()
            await t.answer()

            t.controller.requestSetPaneZoomed(paneID: 2, zoomed: true)
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureZoomed(1, pane: 2)], version)
            await t.answer(Self.readbacks([1: "@1 1 \(Self.ownerID)"]))
            await t.receive(Self.layoutChange(1, Self.split(1, 2), zoomedOn: 2))
            XCTAssertEqual(Self.zoomLines(t.sent()), [], "the default overrode the user's zoom (\(version))")

            t.controller.requestSetPaneZoomed(paneID: 2, zoomed: false)
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureUnzoomed(1)], version)
            await t.tearDown()
        }
    }

    func testAZoomOffWhileTheDefaultsZoomIsUnansweredEndsUnzoomed() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: true,
                windows: Self.window(1, active: true, pane: 1, layout: Self.split(1, 2))
            )
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureZoomed(1), Self.marksQuery], version)

            // The topology shows the window unzoomed, but the default's zoom
            // runs first.
            t.controller.requestSetPaneZoomed(paneID: 1, zoomed: false)
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureUnzoomed(1)], version)

            var readbacks = ["@1 1 \(Self.ownerID)\n", "@1 0 \n"]
            await t.answer { command in
                command == Self.readback(1) ? .ok(readbacks.removeFirst()) : .ok("")
            }
            await t.receive(Self.layoutChange(1, Self.split(1, 2)))
            XCTAssertEqual(Self.zoomLines(t.sent()), [], "the default zoomed the window again (\(version))")
            t.adapter.releaseZoomOwnership()
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [], version)
            await t.tearDown()
        }
    }

    func testAZoomOnWhileTheDefaultsZoomIsUnansweredIsSent() async throws {
        let t = try await ZoomTranscript.attach(
            version: "3.1",
            zoomsByDefault: true,
            windows: Self.window(1, active: true, pane: 1, layout: Self.split(1, 2))
        )
        XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureZoomed(1), Self.marksQuery])

        t.controller.requestSetPaneZoomed(paneID: 2, zoomed: true)
        await t.settle()
        XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureZoomed(1, pane: 2)])
        await t.tearDown()
    }

    func testAZoomOnOfAWindowShownZoomedWithNothingInFlightSendsNothing() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: true,
                windows: Self.window(1, active: true, pane: 1, layout: Self.split(1, 2), zoomed: true)
            )
            _ = t.sent()
            await t.answer()

            t.controller.requestSetPaneZoomed(paneID: 1, zoomed: true)
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [], version)
            await t.tearDown()
        }
    }

    func testAUserZoomReportsAFailureOnce() async throws {
        let t = try await ZoomTranscript.attach(
            version: "3.1",
            zoomsByDefault: false,
            windows: Self.window(1, active: true, pane: 1, layout: Self.split(1, 2))
        )
        _ = t.sent()
        await t.answer()
        var failures: [TmuxSessionController.Request] = []
        let observation = t.session.$lastFailedRequest.dropFirst().sink { failures += $0.map { [$0] } ?? [] }

        t.controller.requestSetPaneZoomed(paneID: 2, zoomed: true)
        await t.settle()
        _ = t.sent()
        await t.answer { $0.hasPrefix("set-option") ? .error("can't find window: @1") : .ok("") }
        XCTAssertEqual(failures, [.zoomPane])
        observation.cancel()
        await t.tearDown()
    }

    // MARK: Case 11: the session ends

    func testReleaseUnzoomsExactlyRemuxsZoomsOneWindowPerCommandLine() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: true,
                windows: Self.window(0, active: true, pane: 0, layout: Self.split(0, 1), zoomed: true)
                    + Self.window(1, active: false, pane: 2, layout: Self.split(2, 3), zoomed: true)
                    + Self.window(2, active: false, pane: 4, layout: Self.split(4, 5), zoomed: true)
            )
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.marksQuery], version)
            await t.answer { command in
                command == Self.marksQuery
                    ? .ok("@0 1 \(Self.ownerID)\n@1 1 3C1E7B0A-0000-4000-8000-000000000000\n@2 1 \(Self.ownerID)\n")
                    : .ok("")
            }

            t.adapter.releaseZoomOwnership()
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureUnzoomed(0), Self.ensureUnzoomed(2)], version)

            // Window 0 closed meanwhile: its line fails alone.
            await t.answer { $0 == "resize-pane -t @0" ? .error("can't find window: @0") : .ok("") }
            XCTAssertEqual(t.session.state, .ready, version)
            XCTAssertEqual(t.session.lastFailedRequest, .zoomPane, version)
            await t.tearDown()
        }
    }

    func testReleaseCoversAZoomStillUnansweredAndEndsTheDefault() async throws {
        for version in Self.versions {
            let t = try await ZoomTranscript.attach(
                version: version,
                zoomsByDefault: true,
                windows: Self.window(0, active: true, pane: 0, layout: Self.single(0))
                    + Self.window(1, active: false, pane: 1, layout: Self.split(1, 2))
            )
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureZoomed(1), Self.marksQuery], version)

            // tmux runs the release after the zoom it hasn't answered yet.
            t.adapter.releaseZoomOwnership()
            await t.settle()
            XCTAssertEqual(Self.zoomLines(t.sent()), [Self.ensureUnzoomed(1)], version)

            await t.receive(Self.layoutChange(0, Self.split(0, 3)))
            XCTAssertEqual(Self.zoomLines(t.sent()), [], "the default zoomed after the release (\(version))")
            await t.tearDown()
        }
    }

    // MARK: Failure reporting

    func testTheDefaultsFailedZoomIsReportedAndBookkeepingFailuresAreNot() async throws {
        let failed = try await ZoomTranscript.attach(
            version: "3.1",
            zoomsByDefault: true,
            windows: Self.window(1, active: true, pane: 1, layout: Self.split(1, 2))
        )
        _ = failed.sent()
        await failed.answer { $0 == Self.claim(1) ? .error("can't find window: @1") : .ok("") }
        XCTAssertEqual(failed.session.lastFailedRequest, .zoomPane)
        await failed.tearDown()

        let bookkeeping = try await ZoomTranscript.attach(
            version: "3.1",
            zoomsByDefault: true,
            windows: Self.window(1, active: true, pane: 1, layout: Self.split(1, 2))
        )
        _ = bookkeeping.sent()
        await bookkeeping.answer { command in
            command == Self.readback(1) || command == Self.marksQuery ? .error("bad format") : .ok("")
        }
        XCTAssertNil(bookkeeping.session.lastFailedRequest)
        await bookkeeping.tearDown()
    }

    // MARK: Transcript helpers

    private static let versions = ["3.1", "3.5a"]
    private static let ownerID = ZoomTranscript.ownerID
    private static let marksQuery = "list-windows -F '#{window_id} #{window_zoomed_flag} #{@remux-zoom-owner}'"

    private static func claim(_ window: Int) -> String {
        "set-option -F -w -t @\(window) @remux-zoom-owner "
            + "'#{?#{||:#{window_zoomed_flag},#{==:#{window_panes},1}},#{@remux-zoom-owner},\(ownerID)}'"
    }

    private static func forget(_ window: Int) -> String {
        "set-option -F -w -t @\(window) @remux-zoom-owner "
            + "'#{?#{&&:#{==:#{@remux-zoom-owner},\(ownerID)},#{!=:#{window_zoomed_flag},1}},,#{@remux-zoom-owner}}'"
    }

    private static func readback(_ window: Int) -> String {
        "display-message -p -t @\(window) '#{window_id} #{window_zoomed_flag} #{@remux-zoom-owner}'"
    }

    private static func ensureZoomed(_ window: Int, pane: Int? = nil) -> String {
        let target = pane.map { "%\($0)" } ?? "@\(window)"
        return "\(claim(window)) ; resize-pane -t \(target) ; resize-pane -Z -t \(target) ; \(readback(window))"
    }

    private static func ensureUnzoomed(_ window: Int) -> String {
        "resize-pane -t @\(window) ; \(forget(window)) ; \(readback(window))"
    }

    private static func forgetAndReadback(_ window: Int) -> String {
        "\(forget(window)) ; \(readback(window))"
    }

    private static func closeOfZoomedWindow(_ pane: Int, in window: Int) -> String {
        "kill-pane -t %\(pane) ; resize-pane -t @\(window) ; resize-pane -Z -t @\(window) ; "
            + "\(forget(window)) ; \(readback(window))"
    }

    /// Answers each window's readback with `lines`, every other command with
    /// an empty reply.
    private static func readbacks(_ lines: [Int: String]) -> (String) -> ZoomTranscript.Reply {
        { command in
            for (window, line) in lines where command == readback(window) { return .ok(line + "\n") }
            return .ok("")
        }
    }

    /// The command lines that change or record a zoom, split, close or select.
    private static func zoomLines(_ sent: String) -> [String] {
        sent.split(separator: "\n").map(String.init).filter { line in
            ["resize-pane", "@remux-zoom-owner", "split-window", "kill-pane", "select-pane"]
                .contains { line.contains($0) }
        }
    }

    private static func assertBeforeTheFirstLoad(
        _ line: String,
        in sent: String,
        _ message: String,
        file: StaticString = #filePath,
        lineNumber: UInt = #line
    ) {
        guard let zoom = sent.range(of: line + "\n") else {
            return XCTFail("\(line) was not sent: \(sent) (\(message))", file: file, line: lineNumber)
        }
        for load in ["list-panes -s -F", "capture-pane"] {
            guard let first = sent.range(of: load) else { continue }
            XCTAssertLessThan(
                zoom.lowerBound, first.lowerBound,
                "the zoom must reach tmux before the client's \(load) (\(message))",
                file: file, line: lineNumber
            )
        }
    }

    /// Attaches with the default on to a current one-pane window and a hidden
    /// split that Remux zoomed and tmux shows zoomed.
    private static func attachWithOwnedHiddenZoom(version: String) async throws -> ZoomTranscript {
        let t = try await ZoomTranscript.attach(
            version: version,
            zoomsByDefault: true,
            windows: window(0, active: true, pane: 0, layout: single(0))
                + window(1, active: false, pane: 1, layout: split(1, 2))
        )
        XCTAssertEqual(zoomLines(t.sent()), [ensureZoomed(1), marksQuery], version)
        await t.answer { command in
            command == readback(1) || command == marksQuery ? .ok("@1 1 \(ownerID)\n") : .ok("")
        }
        await t.receive(layoutChange(1, split(1, 2), zoomedOn: 1))
        XCTAssertEqual(zoomLines(t.sent()), [], version)
        return t
    }

    private static func window(
        _ id: Int,
        active: Bool,
        pane activePaneID: Int,
        layout: String,
        zoomed: Bool = false
    ) -> String {
        "$42 @\(id) \(active ? 1 : 0) %\(activePaneID) 83 44 \(layout) "
            + "\(zoomed ? single(activePaneID) : layout) window-\(id)\n"
    }

    private static func layoutChange(_ id: Int, _ layout: String, zoomedOn paneID: Int? = nil) -> String {
        "%layout-change @\(id) \(layout) \(paneID.map(single) ?? layout) *\(paneID == nil ? "" : "Z")\n"
    }

    private static func single(_ pane: Int) -> String { layout("83x44,0,0,\(pane)") }

    private static func split(_ left: Int, _ right: Int) -> String {
        layout("83x44,0,0{41x44,0,0,\(left),41x44,42,0,\(right)}")
    }

    private static func three(_ first: Int, _ second: Int, _ third: Int) -> String {
        layout("83x44,0,0{27x44,0,0,\(first),27x44,28,0,\(second),27x44,56,0,\(third)}")
    }

    /// A tmux layout string with its checksum.
    private static func layout(_ body: String) -> String {
        var checksum: UInt16 = 0
        for byte in body.utf8 {
            checksum = (checksum >> 1) &+ ((checksum & 1) << 15)
            checksum = checksum &+ UInt16(byte)
        }
        return String(format: "%04x,", checksum) + body
    }

    /// One line of the client's pane-state scan for a 44-row pane at the prompt.
    private static func paneState(_ id: Int, width: Int) -> String {
        "%\(id);\(width);44;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;43;8,16;zsh;/tmp\n"
    }

    private static func policyTopology(zoomed: Bool) -> TmuxSessionController.TopologySnapshot {
        TmuxSessionController.TopologySnapshot(
            sessionName: "zoom-default-test",
            windows: [TmuxSessionController.WindowInfo(
                id: 1, name: "", active: true, zoomed: zoomed, width: 80, height: 24, activePaneID: 10
            )],
            panes: ([10, 11] as [TmuxPaneID]).map { id in
                TmuxSessionController.PaneInfo(
                    id: id, windowID: 1, x: 0, y: 0, width: 39, height: 24,
                    currentCommand: "", currentPath: "", phase: .live
                )
            },
            activeWindowID: 1
        )
    }
}

/// A session whose own controller and native client are fed tmux's bytes
/// directly, with every outbound byte recorded and every command answered in
/// the order it was sent.
@MainActor
private final class ZoomTranscript {
    enum Reply {
        case ok(String)
        case error(String)
    }

    static let ownerID = "6B1E0C3A-9F24-4D8B-A5C7-2E9D3F60B714"

    let runtime: GhosttyKitRuntime
    let session: TmuxTerminalSession
    let adapter: TmuxTerminalScreenAdapter
    private let outbound = ZoomTranscriptRecorder()
    private var nextCommandNumber = 5
    private(set) var allSent = ""

    var controller: TmuxSessionController { session.controller }

    private init(runtime: GhosttyKitRuntime, session: TmuxTerminalSession, adapter: TmuxTerminalScreenAdapter) {
        self.runtime = runtime
        self.session = session
        self.adapter = adapter
    }

    /// Attaches to a session whose `list-windows` reply is `windows`, with
    /// `version` as the tmux version.
    static func attach(version: String, zoomsByDefault: Bool, windows: String) async throws -> ZoomTranscript {
        let runtime = try GhosttyKitRuntime()
        let session = TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            transport: DeterministicTmuxControlTransport(chunks: []),
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark },
            zoomOwner: TmuxZoomOwner(serverID: UUID(uuidString: ownerID)!)
        )
        let adapter = TmuxTerminalScreenAdapter()
        adapter.activate(
            session: session,
            zoomMultipaneWindowsByDefault: zoomsByDefault,
            initialViewportHandler: { _, _, _ in },
            viewportStabilityHandler: { _ in }
        )
        let transcript = ZoomTranscript(runtime: runtime, session: session, adapter: adapter)
        session.controller.setOutboundSink { [outbound = transcript.outbound] in outbound.append($0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.controller.start(initialSize: .init(cols: 83, rows: 44)) {
                continuation.resume(with: $0)
            }
        }
        await transcript.receive("%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n")
        let handshake = transcript.outbound.take()
        XCTAssertTrue(handshake.contains("list-windows -F"), handshake)
        _ = transcript.outbound.takeUnanswered(3)
        await transcript.receive(
            "%begin 2 2 1\n\(version)\n%end 2 2 1\n%begin 3 3 1\n%end 3 3 1\n"
                + "%begin 4 4 1\n\(windows)%end 4 4 1\n"
        )
        return transcript
    }

    /// Everything sent since the last call.
    func sent() -> String {
        let text = outbound.take()
        allSent += text
        return text
    }

    /// Lets the writer queue and the main actor finish what each sent the other.
    func settle() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                session.controller.queue.async {
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }
    }

    func receive(_ text: String) async {
        session.controller.pump(Data(text.utf8))
        await settle()
    }

    /// Answers the oldest `lines` unanswered command lines, all by default,
    /// member by member. An error ends its line: tmux skips the rest.
    func answer(lines: Int? = nil, _ reply: (String) -> Reply = { _ in .ok("") }) async {
        var blocks = ""
        for commandLine in outbound.takeUnanswered(lines) {
            members: for member in commandLine {
                let number = nextCommandNumber
                nextCommandNumber += 1
                switch reply(member) {
                case .ok(let body):
                    blocks += "%begin \(number) \(number) 1\n\(body)%end \(number) \(number) 1\n"
                case .error(let body):
                    blocks += "%begin \(number) \(number) 1\n\(body)\n%error \(number) \(number) 1\n"
                    break members
                }
            }
        }
        await receive(blocks)
    }

    /// Every `resize-pane -Z` is the second half of `resize-pane -t T ;
    /// resize-pane -Z -t T`: none toggles.
    func tearDown(file: StaticString = #filePath, line: UInt = #line) async {
        let everything = allSent + outbound.take()
        for commandLine in everything.split(separator: "\n") {
            let members = commandLine.components(separatedBy: " ; ")
            for (index, member) in members.enumerated() where member.hasPrefix("resize-pane -Z") {
                let target = member.dropFirst("resize-pane -Z ".count)
                XCTAssertTrue(
                    index > 0 && members[index - 1] == "resize-pane \(target)",
                    "a toggle was sent: \(commandLine)",
                    file: file,
                    line: line
                )
            }
        }
        adapter.invalidate()
        await session.shutdown()
        withExtendedLifetime(runtime) {}
    }
}

private final class ZoomTranscriptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var partialLine = ""
    private var unanswered: [[String]] = []

    func append(_ data: Data) {
        lock.withLock {
            let chunk = String(decoding: data, as: UTF8.self)
            text += chunk
            partialLine += chunk
            while let newline = partialLine.firstIndex(of: "\n") {
                unanswered.append(partialLine[..<newline].components(separatedBy: " ; "))
                partialLine = String(partialLine[partialLine.index(after: newline)...])
            }
        }
    }

    func take() -> String {
        lock.withLock {
            defer { text = "" }
            return text
        }
    }

    /// Removes and returns the oldest `count` command lines not yet answered,
    /// or all of them.
    func takeUnanswered(_ count: Int?) -> [[String]] {
        lock.withLock {
            let taken = Array(unanswered.prefix(count ?? unanswered.count))
            unanswered.removeFirst(taken.count)
            return taken
        }
    }
}
