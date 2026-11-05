import UIKit

// The terminal responder conforms to UITextInput for the spacebar long-press
// trackpad (beginFloatingCursor/updateFloatingCursor/endFloatingCursor), for
// input methods, which compose marked text before they commit it, and for
// dictation, which revises text it has already inserted. Its document is
// bounded to what the keyboard needs: a virtual placeholder that gives UIKit
// one character to delete, the text the keyboard typed since its context last
// ended, and the unfinished composition. The typed text is the keyboard's
// context, not a copy of the remote line, which may hold more. The stubs must
// not enable autocorrect or an edit menu.

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

/// The terminal keyboard's document, in UTF-16 offsets as UIKit addresses it:
/// the placeholder, then the text the keyboard typed since its context last
/// ended, then any marked text, with the caret normally at the end. While idle
/// it holds only the placeholder, with the caret after it, so UIKit sees one
/// deletable character and drives its native Backspace repeat.
///
/// Typed text goes to the terminal, whose caret stays after it, up to any line
/// break: one would run the line, so the text from it waits for the keyboard's
/// insert of its result. The keyboard still edits typed text, as dictation does
/// when it revises what it heard, so the document also records what the
/// terminal holds of it, and the terminal is owed the difference. An input
/// method's marked text stays local until it is committed, and typed text stays
/// as it is while a composition is open.
struct GhosttyTerminalCompositionDocument: Equatable {
    static let placeholder = " "
    /// Typed text longer than this ends the keyboard's context, so the document stays small.
    static let typedCapacity = 4096

    /// What the terminal is owed for it to hold the typed text: Backspaces from the end of what
    /// it holds back to where the two differ, then the typed text from there.
    struct TypedEdit: Equatable {
        let backspaces: Int
        let text: String
    }

    enum Deletion: Equatable {
        /// Nothing is typed or composing: the terminal deletes.
        case terminal
        /// Typed text was deleted.
        case typed
        /// The composition changed.
        case composition
        /// The caret is at the composition's start.
        case none
    }

    enum Replacement: Equatable {
        /// The edit stayed inside the composition.
        case composition
        /// Typed text changed.
        case typed
        /// A replacement beyond the composition commits as input, and the document is idle.
        case committed(String)
        /// The range isn't in the document.
        case none
    }

    private(set) var text = Self.placeholder
    private(set) var selection = Self.idleSelection
    private(set) var marked: NSRange?
    /// The keyboard deleted a selection that included the placeholder, which stayed, since it
    /// stands for nothing the terminal holds.
    private var keptPlaceholder = false
    /// The typed text the terminal holds: what it was last sent of it.
    private var held = ""

    private static let typedStart = (placeholder as NSString).length
    private static let idleSelection = NSRange(location: typedStart, length: 0)

    var length: Int { (text as NSString).length }

    /// Nothing is typed, composing or owed to the terminal.
    var isIdle: Bool { marked == nil && length == Self.typedStart && held.isEmpty }

    /// The UTF-16 length of the typed text, which runs from the placeholder to the composition.
    var typedLength: Int { (marked?.location ?? length) - Self.typedStart }

    var markedText: String? {
        marked.map { (text as NSString).substring(with: $0) }
    }

    /// Whether the terminal holds any of the typed text.
    var isHeld: Bool { !held.isEmpty }

    /// What the terminal is owed for it to hold the typed text; nil when it holds it already.
    var owedEdit: TypedEdit? {
        let target = terminalText
        let unchanged = zip(held, target).prefix { pair in pair.0 == pair.1 }.count
        let edit = TypedEdit(backspaces: held.count - unchanged, text: String(target.dropFirst(unchanged)))
        return edit.backspaces == 0 && edit.text.isEmpty ? nil : edit
    }

    /// The typed text from its first line break on, which the terminal receives only once the line
    /// runs.
    var textFromLineBreak: String {
        String(typedText.drop { !$0.isNewline })
    }

    /// Takes what the terminal is owed, which it then holds.
    mutating func takeOwedEdit() -> TypedEdit? {
        guard let edit = owedEdit else { return nil }
        held = String(terminalText)
        return edit
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
        keptPlaceholder = false
        var target = marked ?? selection
        // A composition starts in the typed text, never over the placeholder, which every other
        // edit relies on.
        if marked == nil, target.location < Self.typedStart {
            let end = max(NSMaxRange(target), Self.typedStart)
            target = NSRange(location: Self.typedStart, length: end - Self.typedStart)
        }
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
        if marked == nil { endEmptyComposition(at: target.location) }
    }

    /// The composition's text, removed with it; nil when nothing is composing. A commit ends the
    /// keyboard's context, so the document is idle.
    mutating func unmark() -> String? {
        guard let committed = markedText else { return nil }
        clear()
        return committed
    }

    /// Text the keyboard commits while nothing composes: it replaces the selection, normally the
    /// caret at the end, and becomes typed text. False while composing.
    @discardableResult
    mutating func type(_ inserted: String) -> Bool {
        guard marked == nil else { return false }
        var inserted = inserted
        // A keyboard that deleted the placeholder with typed text types it back first, as the
        // Korean keyboard does when it reassembles a syllable. The placeholder stayed, so that copy
        // isn't typed.
        if keptPlaceholder, inserted.hasPrefix(Self.placeholder) {
            inserted.removeFirst(Self.placeholder.count)
        }
        keptPlaceholder = false
        return editTyped(selection, with: inserted)
    }

    mutating func deleteBackward() -> Deletion {
        guard let marked else {
            var target = selection
            if target.length == 0, target.location > Self.typedStart {
                target = (text as NSString).rangeOfComposedCharacterSequence(at: target.location - 1)
            }
            // With no typed text to delete, the terminal deletes what came before it. The keyboard
            // also selects the placeholder alone before a Backspace on a fresh context, as when the
            // app comes back to the foreground.
            guard NSMaxRange(target) > Self.typedStart else {
                keptPlaceholder = false
                selection = Self.idleSelection
                return .terminal
            }
            let deletion: Deletion = editTyped(target, with: "") ? .typed : .terminal
            keptPlaceholder = target.location < Self.typedStart
            return deletion
        }
        var target = selection
        if target.length == 0 {
            guard target.location > marked.location else { return .none }
            target = (text as NSString).rangeOfComposedCharacterSequence(at: target.location - 1)
        }
        return delete(target, in: marked)
    }

    /// Edits the composition when `range` lies inside it, or the typed text while nothing composes.
    /// A replacement beyond the composition is committed input, and the document is idle.
    mutating func replace(_ range: NSRange, with replacement: String) -> Replacement {
        keptPlaceholder = false
        guard isValid(range) else { return .none }
        guard let marked else {
            return editTyped(range, with: replacement) ? .typed : .none
        }
        if range.location >= marked.location, NSMaxRange(range) <= NSMaxRange(marked) {
            text = (text as NSString).replacingCharacters(in: range, with: replacement)
            let count = (replacement as NSString).length
            let markedLength = marked.length - range.length + count
            self.marked = markedLength == 0 ? nil : NSRange(location: marked.location, length: markedLength)
            selection = NSRange(location: range.location + count, length: 0)
            if self.marked == nil { endEmptyComposition(at: marked.location) }
            return .composition
        }
        clear()
        return .committed(replacement)
    }

    /// Moves the selection inside the composition, or within the typed text while nothing
    /// composes. The caret never moves into the placeholder, so Backspace keeps a character to
    /// delete, but a selection can take it in, as the Korean keyboard's does before it reassembles
    /// a syllable.
    mutating func select(_ range: NSRange) {
        guard isValid(range) else { return }
        if let marked {
            guard range.location >= marked.location, NSMaxRange(range) <= NSMaxRange(marked) else { return }
        } else {
            guard range.location >= Self.typedStart || range.length > 0 else { return }
        }
        selection = range
    }

    /// Ends the keyboard's context: the document holds only the placeholder, and nothing is owed.
    mutating func clear() {
        text = Self.placeholder
        selection = Self.idleSelection
        marked = nil
        keptPlaceholder = false
        held = ""
    }

    private var typedText: String {
        (text as NSString).substring(with: NSRange(location: Self.typedStart, length: typedLength))
    }

    /// The part of the typed text the terminal is to hold. A line break would run the line while
    /// the keyboard can still revise it, as dictation does after "new line", so the text from the
    /// first one waits for the keyboard's insert of its result.
    private var terminalText: Substring {
        typedText.prefix { !$0.isNewline }
    }

    /// Replaces `range` of the typed text; the placeholder is never part of it. False while
    /// composing or for a range outside the document.
    private mutating func editTyped(_ range: NSRange, with replacement: String) -> Bool {
        guard marked == nil, isValid(range) else { return false }
        let current = text as NSString
        let start = max(range.location, Self.typedStart)
        let end = max(NSMaxRange(range), start)
        text = current.substring(to: start) + replacement + current.substring(from: end)
        selection = NSRange(location: start + (replacement as NSString).length, length: 0)
        return true
    }

    /// A composition emptied by an edit ends without committing anything; typed text before it
    /// stays.
    private mutating func endEmptyComposition(at location: Int) {
        marked = nil
        selection = NSRange(location: location, length: 0)
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
        if self.marked == nil { endEmptyComposition(at: marked.location) }
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

    // Dictation's placeholder for the result it is still recognizing. Without one, UIKit stands in
    // for the result with spaces it inserts at the caret and removes later, and the terminal
    // receives both. Nothing is inserted: the terminal's cursor marks where the result goes.
    @objc var insertDictationResultPlaceholder: Any { NSObject() }

    @objc(frameForDictationResultPlaceholder:)
    func frame(forDictationResultPlaceholder placeholder: Any) -> CGRect {
        _ = placeholder
        return compositionCaretRect() ?? .zero
    }

    @objc(removeDictationResultPlaceholder:willInsertResult:)
    func removeDictationResultPlaceholder(_ placeholder: Any, willInsertResult: Bool) {
        _ = (placeholder, willInsertResult)
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
