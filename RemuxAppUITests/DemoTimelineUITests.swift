import Foundation
import UIKit
import XCTest

/// Plays a demo timeline on Remux as it is set up on this simulator, for `scripts/site_demo.py play`, which records
/// the screen around it: the app runs with its own servers and data (no fake transport, nothing seeded) and draws
/// every touch. The timeline format is described in scripts/site_demo.py. Skipped unless REMUX_DEMO_TIMELINE and
/// REMUX_DEMO_TAKE are set.
final class DemoTimelineUITests: XCTestCase {
    @MainActor
    func testPlayDemoTimeline() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let timelinePath = environment["REMUX_DEMO_TIMELINE"], let takePath = environment["REMUX_DEMO_TAKE"] else {
            throw XCTSkip("Plays a demo timeline only for scripts/site_demo.py play")
        }
        continueAfterFailure = false
        // Every step is checked before the app starts, so a typo fails at once rather than halfway through a take.
        let timeline = try DemoTimeline(contentsOf: URL(fileURLWithPath: timelinePath))
        let take = URL(fileURLWithPath: takePath, isDirectory: true)

        let app = XCUIApplication()
        app.launchEnvironment["REMUX_DEBUG_SHOW_TOUCHES"] = "1"
        app.launchEnvironment["REMUX_DEBUG_TOUCH_LOG"] = take.appendingPathComponent("touches.jsonl").path
        app.launch()

        let player = try DemoPlayer(app: app, take: take, pause: timeline.pause)
        for (index, step) in timeline.steps.enumerated() {
            try player.play(step, number: index + 1)
        }
    }
}

struct DemoTimelineError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Where a gesture lands: a point inside the first on-screen element whose accessibility identifier or label is
/// `element`, or, without an element, a point on the screen. Points are fractions of the element or screen, from
/// its top left.
struct DemoTarget {
    var element: String?
    var point: CGVector

    func moved(to point: CGVector) -> DemoTarget { DemoTarget(element: element, point: point) }
}

enum DemoSwipeDirection: String {
    case up, down, left, right

    var vector: CGVector {
        switch self {
        case .up: CGVector(dx: 0, dy: -1)
        case .down: CGVector(dx: 0, dy: 1)
        case .left: CGVector(dx: -1, dy: 0)
        case .right: CGVector(dx: 1, dy: 0)
        }
    }
}

enum DemoStep {
    case wait(TimeInterval)
    case waitFor(DemoTarget, timeout: TimeInterval)
    case tap(DemoTarget)
    case press(DemoTarget, duration: TimeInterval)
    case drag(DemoTarget, to: DemoTarget, hold: TimeInterval, speed: CGFloat, end: TimeInterval)
    case swipe(DemoSwipeDirection, from: DemoTarget, length: CGFloat, speed: CGFloat, count: Int, gap: TimeInterval)
    case type(String, clear: Bool, speed: Double)
    case shot(String)
    case mark(String)

    var action: String {
        switch self {
        case .wait: "wait"
        case .waitFor: "waitFor"
        case .tap: "tap"
        case .press: "press"
        case .drag: "drag"
        case .swipe: "swipe"
        case .type: "type"
        case .shot: "shot"
        case .mark: "mark"
        }
    }

    /// A gesture or typing, after which the timeline's pause lets the screen settle and the viewer take it in.
    var isAction: Bool {
        switch self {
        case .tap, .press, .drag, .swipe, .type: true
        case .wait, .waitFor, .shot, .mark: false
        }
    }
}

struct DemoTimeline {
    var pause: TimeInterval
    var steps: [DemoStep]

    init(contentsOf url: URL) throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let root = object as? [String: Any], let steps = root["steps"] as? [[String: Any]] else {
            throw DemoTimelineError("\(url.lastPathComponent): expected {\"steps\": [ ... ]}")
        }
        let unknown = Set(root.keys).subtracting(["steps", "pause"])
        guard unknown.isEmpty else {
            throw DemoTimelineError("\(url.lastPathComponent): unknown keys \(unknown.sorted())")
        }
        pause = try Self.number(root["pause"], "pause") ?? 1.0
        self.steps = try steps.enumerated().map { index, json in
            do {
                return try Self.step(json)
            } catch let error as DemoTimelineError {
                throw DemoTimelineError("step \(index + 1) \(Self.describe(json)): \(error.description)")
            }
        }
    }

    private static let options: [String: Set<String>] = [
        "wait": [], "waitFor": ["at", "timeout"], "tap": ["at"], "press": ["at", "for"],
        "drag": ["at", "to", "hold", "speed", "end"], "swipe": ["on", "at", "length", "speed", "count", "gap"],
        "type": ["clear", "speed"], "shot": [], "mark": [],
    ]

    private static func step(_ json: [String: Any]) throws -> DemoStep {
        let actions = json.keys.filter { options[$0] != nil }
        guard actions.count == 1, let action = actions.first, let value = json[action] else {
            throw DemoTimelineError("needs exactly one of \(options.keys.sorted())")
        }
        let unknown = Set(json.keys).subtracting([action]).subtracting(options[action] ?? [])
        guard unknown.isEmpty else {
            throw DemoTimelineError("\(action) doesn't take \(unknown.sorted())")
        }
        switch action {
        case "wait":
            guard let seconds = try number(value, action) else { throw DemoTimelineError("wait takes seconds") }
            return .wait(seconds)
        case "waitFor":
            return .waitFor(try target(value, at: json["at"]), timeout: try number(json["timeout"], "timeout") ?? 30)
        case "tap":
            return .tap(try target(value, at: json["at"]))
        case "press":
            return .press(try target(value, at: json["at"]), duration: try number(json["for"], "for") ?? 1.0)
        case "drag":
            let from = try target(value, at: json["at"])
            guard let to = try point(json["to"], "to") else { throw DemoTimelineError("drag needs \"to\": [x, y]") }
            return .drag(
                from, to: from.moved(to: to),
                hold: try number(json["hold"], "hold") ?? 0.6,
                speed: CGFloat(try number(json["speed"], "speed") ?? 200),
                end: try number(json["end"], "end") ?? 0.3
            )
        case "swipe":
            guard let name = value as? String, let direction = DemoSwipeDirection(rawValue: name) else {
                throw DemoTimelineError("swipe takes up, down, left or right")
            }
            let on = try json["on"].map { try target($0, at: json["at"]) }
                ?? DemoTarget(element: nil, point: try point(json["at"], "at") ?? CGVector(dx: 0.5, dy: 0.5))
            let count = try number(json["count"], "count") ?? 1
            guard count >= 1, count == count.rounded() else { throw DemoTimelineError("count is a whole number, 1 or more") }
            return .swipe(
                direction, from: on,
                length: CGFloat(try number(json["length"], "length") ?? 0.4),
                // A steady scroll, slow enough that the touch's trail draws out behind it.
                speed: CGFloat(try number(json["speed"], "speed") ?? 450),
                count: Int(count),
                gap: try number(json["gap"], "gap") ?? 0.12
            )
        case "type":
            guard let text = value as? String else { throw DemoTimelineError("type takes a string") }
            let speed = try number(json["speed"], "speed") ?? 10
            guard speed > 0 else { throw DemoTimelineError("speed is characters a second, more than 0") }
            return .type(text, clear: try flag(json["clear"], "clear") ?? false, speed: speed)
        case "shot", "mark":
            guard let name = value as? String, !name.isEmpty, !name.contains("/") else {
                throw DemoTimelineError("\(action) takes a name")
            }
            return action == "shot" ? .shot(name) : .mark(name)
        default:
            throw DemoTimelineError("unknown step")
        }
    }

    /// An element's identifier or label, with an optional point in it, or a point on the screen.
    private static func target(_ value: Any, at: Any?) throws -> DemoTarget {
        if let element = value as? String {
            return DemoTarget(element: element, point: try point(at, "at") ?? CGVector(dx: 0.5, dy: 0.5))
        }
        if let point = try point(value, "target") {
            guard at == nil else { throw DemoTimelineError("\"at\" goes with an element; this target is already a point") }
            return DemoTarget(element: nil, point: point)
        }
        throw DemoTimelineError("target is an element's identifier or label, or a point [x, y] on the screen")
    }

    private static func point(_ value: Any?, _ key: String) throws -> CGVector? {
        guard let value else { return nil }
        guard let pair = value as? [NSNumber], pair.count == 2,
              pair.allSatisfy({ (0...1).contains($0.doubleValue) })
        else {
            throw DemoTimelineError("\(key) is [x, y], each from 0 to 1")
        }
        return CGVector(dx: pair[0].doubleValue, dy: pair[1].doubleValue)
    }

    private static func number(_ value: Any?, _ key: String) throws -> Double? {
        guard let value else { return nil }
        // JSON's true and false arrive as NSNumbers too; only their type tells them from 1 and 0.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0 else {
            throw DemoTimelineError("\(key) must be a number, 0 or more")
        }
        return number.doubleValue
    }

    private static func flag(_ value: Any?, _ key: String) throws -> Bool? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw DemoTimelineError("\(key) is true or false")
        }
        return number.boolValue
    }

    private static func describe(_ json: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}

/// Performs the steps at a person's pace and notes when each began in the take's steps.jsonl.
@MainActor
final class DemoPlayer {
    private let app: XCUIApplication
    private let take: URL
    private let pause: TimeInterval
    private let steps: FileHandle

    /// How long a gesture waits for its element to appear, as after opening a server whose sessions are loading.
    private static let elementTimeout: TimeInterval = 15

    init(app: XCUIApplication, take: URL, pause: TimeInterval) throws {
        self.app = app
        self.take = take
        self.pause = pause
        let log = take.appendingPathComponent("steps.jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        steps = try FileHandle(forWritingTo: log)
    }

    func play(_ step: DemoStep, number: Int) throws {
        note(step, number: number)
        do {
            try perform(step)
        } catch let error as DemoTimelineError {
            throw DemoTimelineError("step \(number) (\(step.action)): \(error.description)")
        }
        if step.isAction { wait(pause) }
    }

    private func perform(_ step: DemoStep) throws {
        switch step {
        case .wait(let seconds):
            wait(seconds)
        case .waitFor(let target, let timeout):
            _ = try coordinate(target, timeout: timeout)
        case .tap(let target):
            try coordinate(target).tap()
        case .press(let target, let duration):
            try coordinate(target).press(forDuration: duration)
        case .drag(let from, let to, let hold, let speed, let end):
            let start = try coordinate(from)
            try start.press(
                forDuration: hold, thenDragTo: coordinate(to), withVelocity: XCUIGestureVelocity(speed),
                thenHoldForDuration: end
            )
        case .swipe(let direction, let target, let length, let speed, let count, let gap):
            let half = CGVector(dx: direction.vector.dx * length / 2, dy: direction.vector.dy * length / 2)
            let start = target.moved(to: CGVector(dx: target.point.dx - half.dx, dy: target.point.dy - half.dy))
            let end = target.moved(to: CGVector(dx: target.point.dx + half.dx, dy: target.point.dy + half.dy))
            if count == 1 {
                // A brief touch-down, then a fling that lifts at speed, as a finger scrolls.
                try coordinate(start).press(
                    forDuration: 0.05, thenDragTo: coordinate(end), withVelocity: XCUIGestureVelocity(speed),
                    thenHoldForDuration: 0
                )
            } else {
                try DemoTouchPath.flicks(
                    from: coordinate(start).screenPoint, to: coordinate(end).screenPoint,
                    speed: speed, count: count, gap: gap
                )
            }
        case .type(let text, let clear, let speed):
            if clear {
                // An empty field reports its placeholder as its value, so this may delete a few characters too many,
                // which does nothing.
                let field = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
                let current = field.exists ? (field.value as? String ?? "") : ""
                app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
            // At a person's pace: XCUITest types a whole string in a burst, and each call takes about 0.35 s, so each
            // call types the characters that are due by then and the text keeps to `speed` on average.
            let characters = Array(text)
            let started = Date()
            var typed = 0
            while typed < characters.count {
                let due = Int(Date().timeIntervalSince(started) * speed) + 1
                let upTo = min(characters.count, max(typed + 1, due))
                app.typeText(String(characters[typed..<upTo]))
                typed = upTo
                let next = started.addingTimeInterval(Double(typed) / speed).timeIntervalSinceNow
                if next > 0 { wait(next) }
            }
        case .shot(let name):
            let folder = take.appendingPathComponent("shots", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCUIScreen.main.screenshot().pngRepresentation
                .write(to: folder.appendingPathComponent("\(name).png"))
        case .mark:
            break
        }
    }

    private func coordinate(_ target: DemoTarget, timeout: TimeInterval = DemoPlayer.elementTimeout) throws -> XCUICoordinate {
        guard let name = target.element else {
            return app.coordinate(withNormalizedOffset: target.point)
        }
        return try element(named: name, timeout: timeout).coordinate(withNormalizedOffset: target.point)
    }

    /// The first element with this identifier or label that a finger can reach. A row's label is its parts joined
    /// with ", " (a session row reads "web, tmux, …"), so a label that starts with the name and a comma counts too.
    /// The same control can exist more than once, as in each terminal the app keeps open, so only a hittable one
    /// counts.
    private func element(named name: String, timeout: TimeInterval) throws -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@", name, name, name + ", "
        ))
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let match = matches.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                return match
            }
            wait(0.25)
        } while Date() < deadline
        if matches.firstMatch.exists {
            throw DemoTimelineError(
                "\"\(name)\" is there but out of reach after \(Int(timeout)) s: covered (the keyboard hides the lower "
                    + "part of a form) or scrolled away"
            )
        }
        throw DemoTimelineError("nothing named \"\(name)\" on screen after \(Int(timeout)) s; on screen: \(onScreenNames())")
    }

    /// The identifiers and labels of what is on screen, to name a step's target by.
    private func onScreenNames() -> String {
        guard let root = try? app.snapshot() else { return "(unreadable)" }
        let screen = root.frame
        var names: [String] = []
        func visit(_ node: XCUIElementSnapshot) {
            if node.frame.intersects(screen), node.frame.width > 0 {
                for name in [node.identifier, node.label] where !name.isEmpty && !names.contains(name) {
                    // One line each, so the list reads in a log; a label such as a key's fingerprint has several.
                    names.append(name.split(whereSeparator: \.isNewline).joined(separator: " "))
                }
            }
            node.children.forEach(visit)
        }
        visit(root)
        return names.prefix(80).map { "\"\($0)\"" }.joined(separator: ", ")
    }

    private func note(_ step: DemoStep, number: Int) {
        var entry: [String: Any] = ["step": number, "action": step.action, "t": Date().timeIntervalSince1970]
        if case .mark(let name) = step { entry["mark"] = name }
        if case .shot(let name) = step { entry["shot"] = name }
        if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) {
            steps.write(data + Data("\n".utf8))
        }
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

/// Several flicks in a row, as a person scrolls a long page: each lifts at speed and the next comes down `gap` seconds
/// later. Every XCUITest gesture waits for the app to go idle before it returns, and a fling keeps the terminal
/// coasting for about two seconds, so separate swipes land two seconds apart. XCTest's event record, which XCUITest
/// gestures are built on (private; WebDriverAgent uses it the same way), plays a whole touch path on its own clock.
enum DemoTouchPath {
    private typealias Alloc = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
    private typealias InitAtPoint = @convention(c) (UnsafeMutableRawPointer, Selector, CGPoint, Double)
        -> UnsafeMutableRawPointer?
    private typealias InitWithName = @convention(c) (UnsafeMutableRawPointer, Selector, NSString, Int)
        -> UnsafeMutableRawPointer?
    private typealias Getter = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
    private typealias MoveTo = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
    private typealias AtOffset = @convention(c) (AnyObject, Selector, Double) -> Void
    private typealias AddPath = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    /// The synthesizer keeps the completion block and calls it when the path has played, so it escapes.
    private typealias Synthesize = @convention(c) (
        AnyObject, Selector, AnyObject, @escaping @convention(block) (Bool, NSError?) -> Void
    ) -> Void

    @MainActor
    static func flicks(from start: CGPoint, to end: CGPoint, speed: CGFloat, count: Int, gap: TimeInterval) throws {
        let duration = TimeInterval(hypot(end.x - start.x, end.y - start.y) / max(speed, 1))
        let getSynthesizer = try method(XCUIDevice.shared, "eventSynthesizer", as: Getter.self)
        guard let synthesizerPointer = getSynthesizer.call(XCUIDevice.shared, getSynthesizer.selector) else {
            throw DemoTimelineError("XCUIDevice has no event synthesizer, so swipes can't repeat (count above 1)")
        }
        let synthesizer = Unmanaged<AnyObject>.fromOpaque(synthesizerPointer).takeUnretainedValue()
        let synthesize = try method(synthesizer, "synthesizeEvent:completion:", as: Synthesize.self)
        // One record per flick, each sent when the last has been delivered: within one record, a path that lifts and
        // presses again plays as one unbroken touch, and separate paths play back to back with no time between them.
        for flick in 0..<count {
            if flick > 0 { RunLoop.current.run(until: Date().addingTimeInterval(gap)) }
            let path = try instance(of: "XCPointerEventPath", "initForTouchAtPoint:offset:", as: InitAtPoint.self) {
                $0($1, $2, start, 0)
            }
            let moveTo = try method(path, "moveToPoint:atOffset:", as: MoveTo.self)
            let liftUp = try method(path, "liftUpAtOffset:", as: AtOffset.self)
            moveTo.call(path, moveTo.selector, end, duration)
            liftUp.call(path, liftUp.selector, duration)
            let record = try instance(
                of: "XCSynthesizedEventRecord", "initWithName:interfaceOrientation:", as: InitWithName.self
            ) { $0($1, $2, "demo flick" as NSString, UIInterfaceOrientation.portrait.rawValue) }
            let addPath = try method(record, "addPointerEventPath:", as: AddPath.self)
            addPath.call(record, addPath.selector, path)

            let outcome = Outcome()
            synthesize.call(synthesizer, synthesize.selector, record) { delivered, error in
                outcome.finish(delivered: delivered, error: error)
            }
            let deadline = Date().addingTimeInterval(duration + 15)
            while outcome.result == nil, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            guard let (delivered, error) = outcome.result else {
                throw DemoTimelineError("flick \(flick + 1) was still playing \(Int(duration + 15)) s after it began")
            }
            guard delivered else {
                throw DemoTimelineError("flick \(flick + 1) was not delivered: \(error?.localizedDescription ?? "no reason given")")
            }
        }
    }

    /// The event synthesizer may finish on another thread.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (Bool, NSError?)?

        var result: (Bool, NSError?)? { lock.withLock { stored } }
        func finish(delivered: Bool, error: NSError?) { lock.withLock { stored = (delivered, error) } }
    }

    /// A new object of a private class. `alloc` hands over a reference that `init` takes and replaces with its own,
    /// so both pass as raw pointers and ARC only ever sees the finished object.
    private static func instance<T>(
        of className: String, _ initializer: String, as type: T.Type,
        _ call: (T, UnsafeMutableRawPointer, Selector) -> UnsafeMutableRawPointer?
    ) throws -> AnyObject {
        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString(initializer)
        guard let objectClass = NSClassFromString(className),
              let allocMethod = class_getClassMethod(objectClass, allocSelector),
              let initMethod = class_getInstanceMethod(objectClass, initSelector),
              let allocated = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)(
                objectClass, allocSelector
              ),
              let created = call(unsafeBitCast(method_getImplementation(initMethod), to: type), allocated, initSelector)
        else {
            throw DemoTimelineError("this XCTest has no \(className) \(initializer), so swipes can't repeat (count above 1)")
        }
        return Unmanaged<AnyObject>.fromOpaque(created).takeRetainedValue()
    }

    private static func method<T>(_ object: AnyObject, _ name: String, as type: T.Type) throws -> (selector: Selector, call: T) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(object_getClass(object), selector) else {
            throw DemoTimelineError("this XCTest has no \(name), so swipes can't repeat (count above 1)")
        }
        return (selector, unsafeBitCast(method_getImplementation(method), to: type))
    }
}
