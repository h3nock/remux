import UIKit

// The terminal responder conforms to `UITextInput` so iOS will deliver the
// spacebar long-press floating-cursor gesture AND support CJK input methods
// (Pinyin, Wubi, etc.) that require a marked-text (composing) region.
//
// The terminal has no editable document, so this file maintains a lightweight
// virtual document: empty when idle, containing the composing string while an
// IME is active. Committed text flows through `insertText` / `replace` into
// the terminal.

/// Stub UITextPosition backed by an integer offset in the virtual document.
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

    override var start: UITextPosition { from }
    override var end: UITextPosition { to }
    override var isEmpty: Bool { from.offset == to.offset }
}

extension GhosttyTerminalResponderUIView: UITextInput {

    // MARK: - Virtual document length

    private var documentLength: Int {
        storedMarkedText?.count ?? 0
    }

    // MARK: - Selected / marked text

    var selectedTextRange: UITextRange? {
        get {
            if let marked = storedMarkedText {
                let loc = storedMarkedSelectedRange.location == NSNotFound
                    ? marked.count
                    : min(storedMarkedSelectedRange.location, marked.count)
                let pos = GhosttyVirtualTextPosition(offset: loc)
                return GhosttyVirtualTextRange(from: pos, to: pos)
            }
            let zero = GhosttyVirtualTextPosition(offset: 0)
            return GhosttyVirtualTextRange(from: zero, to: zero)
        }
        set { _ = newValue }
    }

    var markedTextRange: UITextRange? {
        guard let marked = storedMarkedText, !marked.isEmpty else { return nil }
        return GhosttyVirtualTextRange(
            from: GhosttyVirtualTextPosition(offset: 0),
            to: GhosttyVirtualTextPosition(offset: marked.count)
        )
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set { _ = newValue }
    }

    var beginningOfDocument: UITextPosition { GhosttyVirtualTextPosition(offset: 0) }
    var endOfDocument: UITextPosition { GhosttyVirtualTextPosition(offset: documentLength) }
    var tokenizer: UITextInputTokenizer { floatingCursorTokenizer }
    var selectionAffinity: UITextStorageDirection {
        get { .forward }
        set { _ = newValue }
    }

    // MARK: - Reading text

    func text(in range: UITextRange) -> String? {
        guard let marked = storedMarkedText,
              let vRange = range as? GhosttyVirtualTextRange else {
            return ""
        }
        let lower = max(0, vRange.from.offset)
        let upper = min(marked.count, vRange.to.offset)
        guard lower < upper else { return "" }
        let start = marked.index(marked.startIndex, offsetBy: lower)
        let end = marked.index(marked.startIndex, offsetBy: upper)
        return String(marked[start..<end])
    }

    func replace(_ range: UITextRange, withText text: String) {
        _ = range
        if storedMarkedText != nil {
            inputDelegate?.textWillChange(self)
            storedMarkedText = nil
            storedMarkedSelectedRange = NSRange(location: NSNotFound, length: 0)
            inputDelegate?.textDidChange(self)
        }
        submitTextInput(text, source: "replaceText")
    }

    // MARK: - Marked text (IME composing)

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        inputDelegate?.textWillChange(self)
        if let text = markedText, !text.isEmpty {
            storedMarkedText = text
            storedMarkedSelectedRange = selectedRange
        } else {
            storedMarkedText = nil
            storedMarkedSelectedRange = NSRange(location: NSNotFound, length: 0)
        }
        inputDelegate?.textDidChange(self)
    }

    func unmarkText() {
        guard let text = storedMarkedText, !text.isEmpty else {
            storedMarkedText = nil
            storedMarkedSelectedRange = NSRange(location: NSNotFound, length: 0)
            return
        }
        inputDelegate?.textWillChange(self)
        storedMarkedText = nil
        storedMarkedSelectedRange = NSRange(location: NSNotFound, length: 0)
        inputDelegate?.textDidChange(self)
        submitTextInput(text, source: "unmarkText")
    }

    // MARK: - Position / range geometry

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard
            let from = fromPosition as? GhosttyVirtualTextPosition,
            let to = toPosition as? GhosttyVirtualTextPosition
        else {
            return nil
        }
        return GhosttyVirtualTextRange(from: from, to: to)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? GhosttyVirtualTextPosition else { return nil }
        let next = max(0, min(documentLength, position.offset + offset))
        return GhosttyVirtualTextPosition(offset: next)
    }

    func position(
        from position: UITextPosition,
        in direction: UITextLayoutDirection,
        offset: Int
    ) -> UITextPosition? {
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

    // MARK: - Hit-testing / rects

    func firstRect(for range: UITextRange) -> CGRect {
        _ = range
        return CGRect(x: 0, y: bounds.maxY - 2, width: 1, height: 2)
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        _ = position
        return CGRect(x: 0, y: bounds.maxY - 2, width: 1, height: 2)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        _ = range
        return []
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        _ = point
        return GhosttyVirtualTextPosition(offset: 0)
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        _ = (point, range)
        return GhosttyVirtualTextPosition(offset: 0)
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        _ = point
        let zero = GhosttyVirtualTextPosition(offset: 0)
        return GhosttyVirtualTextRange(from: zero, to: zero)
    }
}
