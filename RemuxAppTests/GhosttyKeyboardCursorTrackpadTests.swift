import CoreGraphics
import XCTest
@testable import Remux

final class GhosttyKeyboardCursorTrackpadTests: XCTestCase {
    private typealias Trackpad = GhosttyKeyboardCursorTrackpad
    private typealias Metrics = GhosttyKeyboardCursorTrackpad.Metrics

    private let hold = CGPoint(x: 200, y: 300)

    // MARK: Following the thumb

    func testNothingIsSentBeforeTheAxisIsChosen() {
        var trackpad = Trackpad(at: hold, edges: nil)

        XCTAssertEqual(trackpad.move(to: point(down: 5), at: 0).arrows, 0)
        XCTAssertFalse(trackpad.hasMoved)
    }

    func testOneArrowGoesPerRowOfTravelHoweverTheTravelIsSliced() {
        var trackpad = Trackpad(at: hold, edges: nil)
        var arrows = 0
        for y in stride(from: 3, through: 80, by: 3) {
            arrows += trackpad.move(to: point(down: CGFloat(y)), at: 0).arrows
        }

        XCTAssertEqual(arrows, Int(78 / Metrics.rowTravel))
        XCTAssertEqual(trackpad.direction, .down)
        XCTAssertEqual(trackpad.progress, 78 / Metrics.preciseReach, accuracy: 0.001)
        XCTAssertFalse(trackpad.isRepeating)
    }

    func testSidewaysTravelCountsColumns() {
        var trackpad = Trackpad(at: hold, edges: nil)

        let step = trackpad.move(to: point(right: 40), at: 0)

        XCTAssertEqual(step.direction, .right)
        XCTAssertEqual(step.arrows, Int(40 / Metrics.columnTravel))
    }

    func testTurningBackStartsANewRunFromTheTurn() {
        var trackpad = Trackpad(at: hold, edges: nil)
        XCTAssertEqual(trackpad.move(to: point(down: 48), at: 0).arrows, 3)

        // Coming back less than the turn-back distance keeps the run going the same way.
        XCTAssertEqual(trackpad.move(to: point(down: 41), at: 0).arrows, 0)
        XCTAssertEqual(trackpad.direction, .down)

        let turn = trackpad.move(to: point(down: 39), at: 0)
        XCTAssertEqual(turn.direction, .up)
        XCTAssertEqual(turn.arrows, 0)
        // Counted from the turning point, 48: one row back is one arrow up.
        XCTAssertEqual(trackpad.move(to: point(down: 32), at: 0), .init(direction: .up, arrows: 1))
    }

    func testAClearTurnOntoTheOtherAxisSwitchesIt() {
        var trackpad = Trackpad(at: hold, edges: nil)
        XCTAssertEqual(trackpad.move(to: point(down: 20), at: 0).arrows, 1)

        var arrows = 0
        for x in stride(from: 4, through: 40, by: 4) {
            arrows += trackpad.move(to: CGPoint(x: hold.x + CGFloat(x), y: hold.y + 20), at: 0).arrows
        }

        XCTAssertEqual(trackpad.direction, .right)
        XCTAssertGreaterThan(arrows, 0)
    }

    // MARK: Repeating past the reach

    func testPastTheReachTheRestOfTheRowsGoThenItRepeats() {
        var trackpad = Trackpad(at: hold, edges: nil)

        let step = trackpad.move(to: point(down: Metrics.preciseReach + 4), at: 10)

        XCTAssertEqual(step, .init(direction: .down, arrows: 6, startsRepeating: true))
        XCTAssertTrue(trackpad.isRepeating)
        XCTAssertEqual(trackpad.progress, 1)
        XCTAssertNil(trackpad.repeatArrow(at: 10 + Metrics.firstRepeatDelay - 0.01))
        XCTAssertEqual(trackpad.repeatArrow(at: 10 + Metrics.firstRepeatDelay), .down)
    }

    func testRepeatsGetFasterTheFurtherPastTheReach() {
        var shallow = Trackpad(at: hold, edges: nil)
        _ = shallow.move(to: point(down: Metrics.preciseReach + 0.5), at: 0)
        var deep = Trackpad(at: hold, edges: nil)
        _ = deep.move(to: point(down: Metrics.preciseReach + Metrics.repeatRange + 20), at: 0)

        XCTAssertEqual(interval(after: &shallow), 1 / Metrics.slowestRepeatRate, accuracy: 0.01)
        XCTAssertEqual(interval(after: &deep), 1 / Metrics.fastestRepeatRate, accuracy: 0.001)
    }

    func testEasingBackALittleKeepsRepeating() {
        var trackpad = Trackpad(at: hold, edges: nil)
        _ = trackpad.move(to: point(down: 120), at: 0)

        _ = trackpad.move(to: point(down: 113), at: 0)

        XCTAssertTrue(trackpad.isRepeating)
    }

    func testTurningBackWhileRepeatingStopsAtOnceAndStepsBackPrecisely() {
        var trackpad = Trackpad(at: hold, edges: nil)
        _ = trackpad.move(to: point(down: 120), at: 0)

        let turn = trackpad.move(to: point(down: 111), at: 1)

        XCTAssertFalse(trackpad.isRepeating)
        XCTAssertNil(trackpad.repeatArrow(at: 5))
        XCTAssertEqual(turn.direction, .up)
        XCTAssertEqual(turn.arrows, 0)
        XCTAssertEqual(trackpad.move(to: point(down: 120 - Metrics.rowTravel), at: 1).arrows, 1)
    }

    // MARK: Screen edges

    func testAnEdgeRepeatsOnlyWhileTheRunHeadsThatWay() {
        let edges = CGRect(x: 0, y: 50, width: 400, height: 800)
        let start = CGPoint(x: 200, y: 760)
        var trackpad = Trackpad(at: start, edges: edges)

        let into = trackpad.move(to: CGPoint(x: 200, y: 800), at: 0)
        XCTAssertTrue(into.startsRepeating)
        XCTAssertTrue(trackpad.isRepeating)
        XCTAssertEqual(trackpad.repeatArrow(at: Metrics.firstEdgeRepeatDelay), .down)

        _ = trackpad.move(to: CGPoint(x: 200, y: 791), at: 1)
        XCTAssertFalse(trackpad.isRepeating)
    }

    func testAnEdgeBandStartsNoCloserThanTheMinimumTravelFromTheHold() {
        let edges = CGRect(x: 0, y: 50, width: 400, height: 800)
        let start = CGPoint(x: 200, y: 830)
        var trackpad = Trackpad(at: start, edges: edges)

        XCTAssertFalse(trackpad.move(to: CGPoint(x: 200, y: 830 + Metrics.edgeMinimumTravel - 1), at: 0).startsRepeating)
        XCTAssertTrue(trackpad.move(to: CGPoint(x: 200, y: 830 + Metrics.edgeMinimumTravel + 1), at: 0).startsRepeating)
    }

    // MARK: Driver

    @MainActor
    func testTheDriverSendsByTravelAndShowsTheRun() {
        let recorder = Recorder()
        let driver = recorder.driver()
        let owner = NSObject()
        driver.begin(owner: owner, at: hold, edges: nil, source: .terminal, sendKeyEvent: recorder.send)

        driver.update(owner: owner, at: point(down: 32), now: 1)

        XCTAssertEqual(recorder.keys, [.arrowDown, .arrowDown])
        XCTAssertEqual(driver.feedback.state.anchor, .thumb(hold))
        XCTAssertEqual(driver.feedback.state.direction, .down)
        XCTAssertEqual(driver.feedback.state.arrowsSent, 2)
        XCTAssertEqual(recorder.haptics, [.holdStarted, .arrowSent])
    }

    @MainActor
    func testTheDriverRepeatsPastTheReachAndStopsOnTheTurn() {
        let recorder = Recorder()
        let driver = recorder.driver()
        let owner = NSObject()
        driver.begin(owner: owner, at: hold, edges: nil, source: .terminal, sendKeyEvent: recorder.send)
        driver.update(owner: owner, at: point(down: 100), now: 1)
        XCTAssertEqual(recorder.haptics.last, .repeatStarted)
        XCTAssertTrue(driver.feedback.state.isRepeating)

        driver.repeatTick(at: 1 + Metrics.firstRepeatDelay)
        XCTAssertEqual(recorder.keys.count, 7)

        driver.update(owner: owner, at: point(down: 90), now: 2)
        driver.repeatTick(at: 10)
        XCTAssertEqual(recorder.keys.count, 7)
        XCTAssertFalse(driver.feedback.state.isRepeating)
        XCTAssertEqual(driver.feedback.state.direction, .up)
    }

    @MainActor
    func testADragLetGoEndsSteered() {
        let recorder = Recorder()
        let driver = recorder.driver()
        let owner = NSObject()
        driver.begin(owner: owner, at: hold, edges: nil, source: .terminal, sendKeyEvent: recorder.send)
        driver.update(owner: owner, at: point(down: 20), now: 1)

        XCTAssertEqual(driver.end(owner: owner), .steered)
        XCTAssertEqual(driver.feedback.state, .hidden)
    }

    @MainActor
    func testAHoldLetGoInPlaceIsStationary() {
        let recorder = Recorder()
        let driver = recorder.driver()
        let owner = NSObject()
        driver.begin(owner: owner, at: hold, edges: nil, source: .terminal, sendKeyEvent: recorder.send)

        XCTAssertEqual(driver.end(owner: owner), .stationary)
        XCTAssertEqual(driver.feedback.state, .hidden)
    }

    @MainActor
    func testTheDriverIgnoresAnotherOwner() {
        let recorder = Recorder()
        let driver = recorder.driver()
        let owner = NSObject()
        let other = NSObject()
        driver.begin(owner: owner, at: hold, edges: nil, source: .terminal, sendKeyEvent: recorder.send)

        driver.update(owner: other, at: point(down: 40), now: 1)

        XCTAssertTrue(recorder.keys.isEmpty)
        XCTAssertNil(driver.end(owner: other))
        XCTAssertFalse(driver.cancel(owner: other))
        XCTAssertTrue(driver.feedback.state.isVisible)
    }

    @MainActor
    func testARejectedArrowEndsTheGesture() {
        let recorder = Recorder()
        recorder.accepts = false
        let driver = recorder.driver()
        let owner = NSObject()
        driver.begin(owner: owner, at: hold, edges: nil, source: .terminal, sendKeyEvent: recorder.send)

        driver.update(owner: owner, at: point(down: 40), now: 1)
        driver.update(owner: owner, at: point(down: 80), now: 1.1)

        XCTAssertEqual(recorder.keys.count, 1)
        XCTAssertEqual(driver.feedback.state, .hidden)
        XCTAssertNil(driver.end(owner: owner))
    }

    @MainActor
    func testArrowHapticsAreSpacedOut() {
        let recorder = Recorder()
        let driver = recorder.driver()
        let owner = NSObject()
        driver.begin(owner: owner, at: hold, edges: nil, source: .terminal, sendKeyEvent: recorder.send)

        driver.update(owner: owner, at: point(down: 64), now: 1)

        XCTAssertEqual(recorder.keys.count, 4)
        XCTAssertEqual(recorder.haptics, [.holdStarted, .arrowSent])
    }

    // MARK: Stick placement

    private typealias Stick = GhosttyKeyboardCursorTrackpadStick

    func testTheStickSitsAboveTheThumbTowardTheMiddle() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 700)

        XCTAssertEqual(Stick.center(for: .thumb(CGPoint(x: 300, y: 400)), windowOrigin: .zero, in: bounds), CGPoint(x: 240, y: 336))
        XCTAssertEqual(Stick.center(for: .thumb(CGPoint(x: 80, y: 400)), windowOrigin: .zero, in: bounds), CGPoint(x: 140, y: 336))
    }

    func testTheStickSitsBesideTheThumbWhereThereIsNoRoomAbove() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 700)

        XCTAssertEqual(Stick.center(for: .thumb(CGPoint(x: 300, y: 80)), windowOrigin: .zero, in: bounds), CGPoint(x: 216, y: 72))
    }

    func testTheStickUsesTheTerminalAreasOwnCoordinates() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 700)

        XCTAssertEqual(
            Stick.center(for: .thumb(CGPoint(x: 300, y: 459)), windowOrigin: CGPoint(x: 0, y: 59), in: bounds),
            CGPoint(x: 240, y: 336)
        )
    }

    func testASpaceBarHoldCentresTheStickAboveTheKeyboard() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 500)

        XCTAssertEqual(Stick.center(for: .keyboard, windowOrigin: .zero, in: bounds), CGPoint(x: 200, y: 456))
    }

    // MARK: Helpers

    private func point(down distance: CGFloat) -> CGPoint {
        CGPoint(x: hold.x, y: hold.y + distance)
    }

    private func point(right distance: CGFloat) -> CGPoint {
        CGPoint(x: hold.x + distance, y: hold.y)
    }

    /// The time between the first two repeats.
    private func interval(after trackpad: inout Trackpad) -> TimeInterval {
        var time: TimeInterval = 0
        var fired: [TimeInterval] = []
        while fired.count < 2, time < 5 {
            if trackpad.repeatArrow(at: time) != nil { fired.append(time) }
            time += 0.0005
        }
        return fired[1] - fired[0]
    }

    @MainActor
    private final class Recorder {
        var keys: [GhosttySurfaceKeyEvent.KeyCode] = []
        var haptics: [GhosttyKeyboardCursorTrackpadDriver.HapticCue] = []
        var accepts = true

        func driver() -> GhosttyKeyboardCursorTrackpadDriver {
            GhosttyKeyboardCursorTrackpadDriver(playHaptic: { [weak self] in self?.haptics.append($0) })
        }

        func send(_ event: GhosttySurfaceKeyEvent) -> Bool {
            keys.append(event.keyCode)
            return accepts
        }
    }
}
