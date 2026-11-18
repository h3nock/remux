import Foundation
import UIKit
import Vision
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
        // The app's debug settings pass through, as for a rehearsal against a private test server
        // (TEST_RUNNER_REMUX_DEBUG_… in xcodebuild's environment arrives here without the prefix).
        for (name, value) in environment where name.hasPrefix("REMUX_DEBUG_") {
            app.launchEnvironment[name] = value
        }
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
    /// Text read off the screen: a terminal draws its text itself, so XCUITest can't see it.
    case waitForText(String, last: Bool, timeout: TimeInterval)
    case tapText(String, last: Bool, timeout: TimeInterval)
    case pressText(String, last: Bool, duration: TimeInterval, timeout: TimeInterval)
    /// One touch drawn through points in an element, as a finger draws on a picture.
    case stroke(DemoTarget, points: [CGVector], over: TimeInterval)
    case shot(String)
    case mark(String)
    /// Tells whatever runs beside the take that the timeline got here: a file, cues/<name>, in the take's folder.
    case cue(String)
    /// Waits for cues/<name>, which something beside the take writes, as when an agent it watches has finished.
    case waitCue(String, timeout: TimeInterval)

    var action: String {
        switch self {
        case .wait: "wait"
        case .waitFor: "waitFor"
        case .tap: "tap"
        case .press: "press"
        case .drag: "drag"
        case .swipe: "swipe"
        case .type: "type"
        case .waitForText: "waitForText"
        case .tapText: "tapText"
        case .pressText: "pressText"
        case .stroke: "stroke"
        case .shot: "shot"
        case .mark: "mark"
        case .cue: "cue"
        case .waitCue: "waitCue"
        }
    }

    /// A gesture or typing, after which the timeline's pause lets the screen settle and the viewer take it in.
    var isAction: Bool {
        switch self {
        case .tap, .press, .drag, .swipe, .type, .tapText, .pressText, .stroke: true
        case .wait, .waitFor, .waitForText, .shot, .mark, .cue, .waitCue: false
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
        "type": ["clear", "speed"], "waitForText": ["last", "timeout"], "tapText": ["last", "timeout"],
        "pressText": ["last", "for", "timeout"], "waitCue": ["timeout"], "stroke": ["at", "points", "over"], "shot": [], "mark": [], "cue": [],
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
        case "waitForText", "tapText", "pressText":
            guard let text = value as? String, !text.isEmpty else { throw DemoTimelineError("\(action) takes the text") }
            let timeout = try number(json["timeout"], "timeout") ?? 20
            // The newest of several, as a terminal's latest output is the lowest.
            let last = try flag(json["last"], "last") ?? false
            switch action {
            case "waitForText": return .waitForText(text, last: last, timeout: timeout)
            case "tapText": return .tapText(text, last: last, timeout: timeout)
            default: return .pressText(text, last: last, duration: try number(json["for"], "for") ?? 0.8, timeout: timeout)
            }
        case "waitCue":
            guard let name = value as? String, !name.isEmpty, !name.contains("/") else {
                throw DemoTimelineError("waitCue takes a name")
            }
            return .waitCue(name, timeout: try number(json["timeout"], "timeout") ?? 60)
        case "stroke":
            guard let pairs = json["points"] as? [Any], pairs.count >= 2 else {
                throw DemoTimelineError("stroke needs \"points\": [[x, y], ...], at least two")
            }
            return .stroke(
                try target(value, at: nil),
                points: try pairs.map { try point($0, "points") ?? CGVector() },
                over: try number(json["over"], "over") ?? 0.6
            )
        case "shot", "mark", "cue":
            guard let name = value as? String, !name.isEmpty, !name.contains("/") else {
                throw DemoTimelineError("\(action) takes a name")
            }
            return action == "shot" ? .shot(name) : action == "mark" ? .mark(name) : .cue(name)
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
            try DemoGesture.tap(at: coordinate(target).screenPoint)
        case .press(let target, let duration):
            try DemoGesture.press(at: coordinate(target).screenPoint, for: duration)
        case .drag(let from, let to, let hold, let speed, let end):
            let start = try coordinate(from).screenPoint
            let finish = try coordinate(to).screenPoint
            try DemoGesture.drag(
                from: start, to: finish, hold: hold,
                duration: TimeInterval(hypot(finish.x - start.x, finish.y - start.y) / max(speed, 1)), settle: end
            )
        case .swipe(let direction, let target, let length, let speed, let count, let gap):
            let half = CGVector(dx: direction.vector.dx * length / 2, dy: direction.vector.dy * length / 2)
            let start = try coordinate(target.moved(to: CGVector(dx: target.point.dx - half.dx, dy: target.point.dy - half.dy)))
                .screenPoint
            let end = try coordinate(target.moved(to: CGVector(dx: target.point.dx + half.dx, dy: target.point.dy + half.dy)))
                .screenPoint
            for flick in 0..<count {
                if flick > 0 { wait(gap) }
                try DemoGesture.flick(from: start, to: end, speed: speed)
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
        case .waitForText(let text, let last, let timeout):
            _ = try point(ofText: text, last: last, timeout: timeout)
        case .tapText(let text, let last, let timeout):
            try DemoGesture.tap(at: point(ofText: text, last: last, timeout: timeout))
        case .pressText(let text, let last, let duration, let timeout):
            try DemoGesture.press(at: point(ofText: text, last: last, timeout: timeout), for: duration)
        case .waitCue(let name, let timeout):
            let file = take.appendingPathComponent("cues", isDirectory: true).appendingPathComponent(name)
            let deadline = Date().addingTimeInterval(timeout)
            while !FileManager.default.fileExists(atPath: file.path) {
                guard Date() < deadline else { throw DemoTimelineError("no cue \"\(name)\" after \(Int(timeout)) s") }
                wait(0.2)
            }
        case .stroke(let target, let points, let over):
            let frame = try target.element.map { try element(named: $0, timeout: Self.elementTimeout).frame } ?? app.frame
            try DemoGesture.stroke(
                through: points.map { CGPoint(x: frame.minX + $0.dx * frame.width, y: frame.minY + $0.dy * frame.height) },
                over: over
            )
        case .shot(let name):
            let folder = take.appendingPathComponent("shots", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCUIScreen.main.screenshot().pngRepresentation
                .write(to: folder.appendingPathComponent("\(name).png"))
        case .mark:
            break
        case .cue(let name):
            let folder = take.appendingPathComponent("cues", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent(name))
        }
    }

    /// Where `text` is on screen, read with Vision's text recognition, checked every half second until `timeout`.
    /// The highest line holding it counts, or the lowest with `last`, case aside, and the point is the middle of the
    /// text itself.
    private func point(ofText text: String, last: Bool, timeout: TimeInterval) throws -> CGPoint {
        let deadline = Date().addingTimeInterval(timeout)
        var seen: [String] = []
        repeat {
            let screenshot = XCUIScreen.main.screenshot().image
            if let image = screenshot.cgImage {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: image).perform([request])
                seen = []
                var found: [CGRect] = []
                for observation in request.results ?? [] {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    seen.append(candidate.string)
                    guard let range = candidate.string.range(of: text, options: .caseInsensitive),
                          let box = try candidate.boundingBox(for: range)?.boundingBox
                    else { continue }
                    found.append(box)
                }
                // Vision's boxes are fractions of the image from its bottom left, so the highest has the largest y.
                if let box = last ? found.min(by: { $0.midY < $1.midY }) : found.max(by: { $0.midY < $1.midY }) {
                    let screen = app.frame
                    return CGPoint(x: screen.minX + box.midX * screen.width, y: screen.minY + (1 - box.midY) * screen.height)
                }
            }
            wait(0.5)
        } while Date() < deadline
        throw DemoTimelineError("no \"\(text)\" on screen after \(Int(timeout)) s; read: \(seen.suffix(30).map { "\"\($0)\"" }.joined(separator: ", "))")
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

/// Touches shaped like a person's, played point by point by `TouchPath` on the event synthesizer's clock. XCUITest's
/// own gestures move in a straight line at one speed and wait for the app to go idle between gestures, which reads as
/// a machine on camera: here a drag eases out of its hold along a thumb's slight arc and settles before it lifts, and a
/// flick speeds up and lifts while still moving, so a list coasts the way it does under a thumb.
enum DemoGesture {
    private static let frame: TimeInterval = 1.0 / 60
    /// A flick's position goes as t to this power, so it lifts at this many times its average speed.
    private static let flickExponent = 1.7

    @MainActor
    static func tap(at point: CGPoint) throws {
        try TouchPath.play(from: point, [.hold(0.09)])
    }

    @MainActor
    static func press(at point: CGPoint, for duration: TimeInterval) throws {
        try TouchPath.play(from: point, [.hold(duration)])
    }

    /// Down and held for `hold`, then to `end` over `duration` with minimum-jerk easing, held `settle`, and up.
    @MainActor
    static func drag(
        from start: CGPoint, to end: CGPoint, hold: TimeInterval, duration: TimeInterval, settle: TimeInterval
    ) throws {
        var segments: [TouchPath.Segment] = hold > 0 ? [.hold(hold)] : []
        segments += stroke(from: start, to: end, duration: duration, bow: 0.03) { t in t * t * t * (10 - 15 * t + 6 * t * t) }
        if settle > 0 { segments.append(.hold(settle)) }
        try TouchPath.play(from: start, segments)
    }

    /// A brief touch-down, then a stroke that speeds up and lifts at `speed` points a second.
    @MainActor
    static func flick(from start: CGPoint, to end: CGPoint, speed: CGFloat) throws {
        let distance = hypot(end.x - start.x, end.y - start.y)
        let duration = TimeInterval(CGFloat(flickExponent) * distance / max(speed, 1))
        try TouchPath.play(
            from: start,
            [.hold(0.03)] + stroke(from: start, to: end, duration: duration, bow: 0.02) { pow($0, flickExponent) }
        )
    }

    /// One touch along a smooth curve through `points` (Catmull-Rom), at an eased pace over `over` seconds, lifting at
    /// the last point: how a finger draws a circle or an arrow on a picture.
    @MainActor
    static func stroke(through points: [CGPoint], over duration: TimeInterval) throws {
        guard let first = points.first else { return }
        // The curve, finely sampled, then walked by distance so the pace doesn't depend on how the points are spaced.
        var curve: [CGPoint] = [first]
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)], p1 = points[index], p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            for step in 1...12 {
                let t = CGFloat(step) / 12, t2 = t * t, t3 = t2 * t
                curve.append(CGPoint(
                    x: 0.5 * (2 * p1.x + (p2.x - p0.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                        + (3 * p1.x - p0.x - 3 * p2.x + p3.x) * t3),
                    y: 0.5 * (2 * p1.y + (p2.y - p0.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
                        + (3 * p1.y - p0.y - 3 * p2.y + p3.y) * t3)
                ))
            }
        }
        var lengths: [CGFloat] = [0]
        for index in 1..<curve.count {
            lengths.append(lengths[index - 1] + hypot(curve[index].x - curve[index - 1].x, curve[index].y - curve[index - 1].y))
        }
        let total = max(lengths.last ?? 0, 1)
        let steps = max(1, Int((duration / frame).rounded()))
        var segments: [TouchPath.Segment] = [.hold(0.04)]
        var cursor = 0
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            // Gentler than a drag's easing at the ends, as a hand drawing keeps moving.
            let along = total * CGFloat(0.5 - 0.5 * cos(.pi * t))
            while cursor < lengths.count - 2, lengths[cursor + 1] < along { cursor += 1 }
            let span = max(lengths[cursor + 1] - lengths[cursor], 0.0001)
            let f = min(max((along - lengths[cursor]) / span, 0), 1)
            let a = curve[cursor], b = curve[cursor + 1]
            segments.append(.move(to: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), over: duration / Double(steps)))
        }
        try TouchPath.play(from: first, segments)
    }

    /// One point a frame along `ease`, bowed to one side by `bow` of the stroke's length at its middle.
    private static func stroke(
        from start: CGPoint, to end: CGPoint, duration: TimeInterval, bow: CGFloat, ease: (Double) -> Double
    ) -> [TouchPath.Segment] {
        let steps = max(1, Int((duration / frame).rounded()))
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        let normal = length > 0 ? CGVector(dx: -dy / length, dy: dx / length) : .zero
        return (1...steps).map { step in
            let t = Double(step) / Double(steps)
            let along = CGFloat(ease(t))
            let side = bow * length * CGFloat(sin(.pi * t))
            return .move(
                to: CGPoint(x: start.x + dx * along + normal.dx * side, y: start.y + dy * along + normal.dy * side),
                over: duration / Double(steps)
            )
        }
    }
}
