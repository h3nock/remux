import Foundation
import ObjectiveC
import UIKit
import XCTest

/// One touch played on the event synthesizer's own clock: down at a point, then holds and moves, then up. XCUITest's
/// public gestures drag along one straight line and wait for the app to go idle between gestures, so a drag that turns
/// back, or a second touch a fraction of a second after the first, needs XCTest's event record, which those gestures
/// are built on (private; WebDriverAgent uses it the same way). Points are in screen coordinates.
enum TouchPath {
    enum Segment {
        case hold(TimeInterval)
        case move(to: CGPoint, over: TimeInterval)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

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

    /// Moves are played as points 1/60 s apart, as a finger reports them.
    private static let moveStep: TimeInterval = 1.0 / 60

    /// Plays the touch and returns once it has lifted.
    @MainActor
    static func play(from start: CGPoint, _ segments: [Segment]) throws {
        let path = try instance(of: "XCPointerEventPath", "initForTouchAtPoint:offset:", as: InitAtPoint.self) {
            $0($1, $2, start, 0)
        }
        let moveTo = try method(path, "moveToPoint:atOffset:", as: MoveTo.self)
        let liftUp = try method(path, "liftUpAtOffset:", as: AtOffset.self)
        var offset: TimeInterval = 0
        var point = start
        for segment in segments {
            switch segment {
            case .hold(let duration):
                // The synthesizer glides between the points it is given, so the touch is pinned at the end of the
                // hold; otherwise it creeps toward the next move while it should rest.
                offset += duration
                moveTo.call(path, moveTo.selector, point, offset)
            case .move(let end, let duration):
                let steps = max(1, Int((duration / moveStep).rounded()))
                for step in 1...steps {
                    let fraction = CGFloat(step) / CGFloat(steps)
                    let next = CGPoint(x: point.x + (end.x - point.x) * fraction, y: point.y + (end.y - point.y) * fraction)
                    moveTo.call(path, moveTo.selector, next, offset + duration * Double(fraction))
                }
                offset += duration
                point = end
            }
        }
        liftUp.call(path, liftUp.selector, offset)

        let record = try instance(
            of: "XCSynthesizedEventRecord", "initWithName:interfaceOrientation:", as: InitWithName.self
        ) { $0($1, $2, "touch path" as NSString, UIInterfaceOrientation.portrait.rawValue) }
        let addPath = try method(record, "addPointerEventPath:", as: AddPath.self)
        addPath.call(record, addPath.selector, path)

        let getSynthesizer = try method(XCUIDevice.shared, "eventSynthesizer", as: Getter.self)
        guard let synthesizerPointer = getSynthesizer.call(XCUIDevice.shared, getSynthesizer.selector) else {
            throw Failure(description: "XCUIDevice has no event synthesizer")
        }
        let synthesizer = Unmanaged<AnyObject>.fromOpaque(synthesizerPointer).takeUnretainedValue()
        let synthesize = try method(synthesizer, "synthesizeEvent:completion:", as: Synthesize.self)
        let outcome = Outcome()
        synthesize.call(synthesizer, synthesize.selector, record) { delivered, error in
            outcome.finish(delivered: delivered, error: error)
        }
        let deadline = Date().addingTimeInterval(offset + 15)
        while outcome.result == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        guard let (delivered, error) = outcome.result else {
            throw Failure(description: "the touch was still playing \(Int(offset + 15)) s after it began")
        }
        guard delivered else {
            throw Failure(description: "the touch was not delivered: \(error?.localizedDescription ?? "no reason given")")
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
            throw Failure(description: "this XCTest has no \(className) \(initializer)")
        }
        return Unmanaged<AnyObject>.fromOpaque(created).takeRetainedValue()
    }

    private static func method<T>(_ object: AnyObject, _ name: String, as type: T.Type) throws -> (selector: Selector, call: T) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(object_getClass(object), selector) else {
            throw Failure(description: "this XCTest has no \(name)")
        }
        return (selector, unsafeBitCast(method_getImplementation(method), to: type))
    }
}
