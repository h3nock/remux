import UIKit

// The terminal responder conforms to UITextInput for the spacebar long-press
// trackpad (beginFloatingCursor/updateFloatingCursor/endFloatingCursor) and for
// input methods, which compose marked text before they commit it. Its document
// is bounded to what the keyboard needs: a virtual placeholder that gives UIKit
// one character to delete, plus the unfinished composition. It is never a copy
// of the remote terminal's text. The stubs must not enable autocorrect or an
// edit menu.

/// UITextPosition backed by a UTF-16 offset in the responder's document.
final class GhosttyVirtualTextPosition: UITextPosition {
    let offset: Int
    init(offset: Int) {
        self.offset = offset
        super.init()
    }
}

final class GhosttyVirtualTextRange: UITextRange {
    let from: GhosttyVirtualTextPosition
    let to: GhosttyVirtualTextPosition

    init(from: GhosttyVirtualTextPosition, to: GhosttyVirtualTextPosition) {
        self.from = from
        self.to = to
        super.init()
    }

    convenience init(_ range: NSRange) {
        self.init(
            from: GhosttyVirtualTextPosition(offset: range.location),
            to: GhosttyVirtualTextPosition(offset: NSMaxRange(range))
        )
    }

    var nsRange: NSRange {
        NSRange(location: from.offset, length: to.offset - from.offset)
    }

    override var start: UITextPosition { from }
    override var end: UITextPosition { to }
    override var isEmpty: Bool { from.offset == to.offset }
}

/// The terminal keyboard's document, in UTF-16 offsets as UIKit addresses it.
/// While idle it holds only the placeholder, with the caret after it, so UIKit
/// sees one deletable character and drives its native Backspace repeat. An
/// input method's marked text follows the placeholder and stays local until it
/// is committed; committed and unmarked text goes straight to the terminal.
struct GhosttyTerminalCompositionDocument: Equatable {
    static let placeholder = " "

    enum Deletion: Equatable {
        /// Nothing is composing: the terminal deletes.
        case terminal
        /// The composition changed.
        case composition
        /// The caret is at the composition's start.
        case none
    }

    private(set) var text = Self.placeholder
    private(set) var selection = Self.idleSelection
    private(set) var marked: NSRange?

    private static let idleSelection = NSRange(
        location: (placeholder as NSString).length,
        length: 0
    )

    var length: Int { (text as NSString).length }

    var markedText: String? {
        marked.map { (text as NSString).substring(with: $0) }
    }

    func isValid(_ range: NSRange) -> Bool {
        range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }

    func text(in range: NSRange) -> String? {
        guard isValid(range) else { return nil }
        return (text as NSString).substring(with: range)
    }

    /// Replaces the composition, or starts one at the selection. `selectedRange`
    /// is relative to the new marked text.
    mutating func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        let target = marked ?? selection
        guard isValid(target) else { return }
        let value = markedText ?? ""
        text = (text as NSString).replacingCharacters(in: target, with: value)
        let count = (value as NSString).length
        marked = count == 0 ? nil : NSRange(location: target.location, length: count)
        let start = selectedRange.location == NSNotFound
            ? count
            : min(max(0, selectedRange.location), count)
        selection = NSRange(
            location: target.location + start,
            length: min(max(0, selectedRange.length), count - start)
        )
        if marked == nil { clear() }
    }

    /// The composition's text, removed with it; nil when nothing is composing.
    mutating func unmark() -> String? {
        guard let committed = markedText else { return nil }
        clear()
        return committed
    }

    mutating func deleteBackward() -> Deletion {
        guard let marked else { return .terminal }
        var target = selection
        if target.length == 0 {
            guard target.location > marked.location else { return .none }
            target = (text as NSString).rangeOfComposedCharacterSequence(at: target.location - 1)
        }
        return delete(target, in: marked)
    }

    /// Deletes forward within the composition. Without one, the terminal deletes.
    mutating func deleteForward() -> Deletion {
        guard let marked else { return .terminal }
        var target = selection
        if target.length == 0 {
            guard target.location < NSMaxRange(marked) else { return .none }
            target = (text as NSString).rangeOfComposedCharacterSequence(at: target.location)
        }
        return delete(target, in: marked)
    }

    /// Edits the composition when `range` lies inside it. Anything else is
    /// committed input: the text to send is returned and the document is idle.
    mutating func replace(_ range: NSRange, with replacement: String) -> String? {
        guard isValid(range) else { return nil }
        if let marked, range.location >= marked.location, NSMaxRange(range) <= NSMaxRange(marked) {
            text = (text as NSString).replacingCharacters(in: range, with: replacement)
            let count = (replacement as NSString).length
            let markedLength = marked.length - range.length + count
            self.marked = markedLength == 0 ? nil : NSRange(location: marked.location, length: markedLength)
            selection = NSRange(location: range.location + count, length: 0)
            if self.marked == nil { clear() }
            return nil
        }
        clear()
        return replacement
    }

    /// Moves the selection inside the composition. While idle the caret stays
    /// after the placeholder, so Backspace keeps a character to delete.
    mutating func select(_ range: NSRange) {
        guard let marked, isValid(range),
              range.location >= marked.location,
              NSMaxRange(range) <= NSMaxRange(marked)
        else { return }
        selection = range
    }

    mutating func clear() {
        text = Self.placeholder
        selection = Self.idleSelection
        marked = nil
    }

    private mutating func delete(_ target: NSRange, in marked: NSRange) -> Deletion {
        guard isValid(target),
              target.location >= marked.location,
              NSMaxRange(target) <= NSMaxRange(marked)
        else { return .none }
        text = (text as NSString).replacingCharacters(in: target, with: "")
        selection = NSRange(location: target.location, length: 0)
        let remaining = marked.length - target.length
        self.marked = remaining == 0 ? nil : NSRange(location: marked.location, length: remaining)
        if self.marked == nil { clear() }
        return .composition
    }
}

extension GhosttyTerminalResponderUIView: UITextInput {
    var selectedTextRange: UITextRange? {
        get { GhosttyVirtualTextRange(composition.selection) }
        set {
            guard let range = newValue as? GhosttyVirtualTextRange else { return }
            selectComposition(range.nsRange)
        }
    }

    var markedTextRange: UITextRange? {
        composition.marked.map(GhosttyVirtualTextRange.init)
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set { _ = newValue }
    }

    var beginningOfDocument: UITextPosition { GhosttyVirtualTextPosition(offset: 0) }
    var endOfDocument: UITextPosition { GhosttyVirtualTextPosition(offset: composition.length) }
    var tokenizer: UITextInputTokenizer { floatingCursorTokenizer }
    var selectionAffinity: UITextStorageDirection {
        get { .forward }
        set { _ = newValue }
    }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? GhosttyVirtualTextRange else { return nil }
        return composition.text(in: range.nsRange)
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard let range = range as? GhosttyVirtualTextRange else { return }
        replaceComposition(range.nsRange, with: text)
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard
            let from = fromPosition as? GhosttyVirtualTextPosition,
            let to = toPosition as? GhosttyVirtualTextPosition
        else {
            return nil
        }
        let lower = clampedOffset(min(from.offset, to.offset))
        let upper = clampedOffset(max(from.offset, to.offset))
        return GhosttyVirtualTextRange(NSRange(location: lower, length: upper - lower))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? GhosttyVirtualTextPosition else { return nil }
        return GhosttyVirtualTextPosition(offset: clampedOffset(position.offset + offset))
    }

    func position(
        from position: UITextPosition,
        in direction: UITextLayoutDirection,
        offset: Int
    ) -> UITextPosition? {
        // The document is one line; delegate to the linear offset variant so
        // UIKit's tokenizer keeps receiving non-nil positions.
        self.position(from: position, offset: offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard
            let lhs = position as? GhosttyVirtualTextPosition,
            let rhs = other as? GhosttyVirtualTextPosition
        else {
            return .orderedSame
        }
        if lhs.offset < rhs.offset { return .orderedAscending }
        if lhs.offset > rhs.offset { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard
            let lhs = from as? GhosttyVirtualTextPosition,
            let rhs = toPosition as? GhosttyVirtualTextPosition
        else {
            return 0
        }
        return rhs.offset - lhs.offset
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        _ = direction
        return range.end
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        _ = direction
        guard let position = position as? GhosttyVirtualTextPosition else { return nil }
        return GhosttyVirtualTextRange(from: position, to: position)
    }

    func baseWritingDirection(
        for position: UITextPosition,
        in direction: UITextStorageDirection
    ) -> NSWritingDirection {
        _ = (position, direction)
        return .natural
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
        _ = (writingDirection, range)
    }

    /// Where the input method shows its candidates: the terminal cursor's cell,
    /// where the composition is drawn.
    func firstRect(for range: UITextRange) -> CGRect {
        let rect = compositionCaretRect() ?? .zero
        GhosttyRuntimeTrace.diagnostics(
            "responder.firstRect range=\((range as? GhosttyVirtualTextRange).map { NSStringFromRange($0.nsRange) } ?? "nil") rect=\(NSCoder.string(for: rect)) window=\(NSCoder.string(for: convert(rect, to: nil)))"
        )
        return rect
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        _ = position
        guard let cell = compositionCaretRect() else { return .zero }
        let caret = CGRect(x: cell.minX, y: cell.minY, width: 2, height: cell.height)
        GhosttyRuntimeTrace.diagnostics("responder.caretRect rect=\(NSCoder.string(for: caret))")
        return caret
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        _ = range
        return []
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        _ = point
        return GhosttyVirtualTextPosition(offset: composition.selection.location)
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        _ = point
        return range.end
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        _ = point
        return GhosttyVirtualTextRange(composition.selection)
    }

    private func clampedOffset(_ offset: Int) -> Int {
        max(0, min(composition.length, offset))
    }
}
