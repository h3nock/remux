import GhosttyKit
import UIKit
import XCTest
@testable import Remux

/// Reads a renderer's terminal back as text through Ghostty's own selection, and Herdr's cells as the
/// same text.
@MainActor
enum RendererText {
    /// The first `rows` rows of `columns` cells, each as Ghostty selects it (a word in the row,
    /// stretched across the row), without surrounding blanks.
    static func rows(of renderer: TerminalPaneRenderer, columns: Int, rows: Int) -> [String] {
        guard let surface = renderer.rawSurface else {
            XCTFail("renderer has no surface")
            return []
        }
        var size = ghostty_surface_size_s()
        guard ghostty_terminal_surface_size(surface, &size) == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            XCTFail("renderer has no size")
            return []
        }
        let cellWidth = Double(size.cell_width_px)
        let cellHeight = Double(size.cell_height_px)
        var snapshot = ghostty_terminal_surface_selection_snapshot_s()
        defer { _ = ghostty_terminal_surface_clear_selection(surface, &snapshot) }
        return (0..<rows).map { row in
            let y = (Double(row) + 0.5) * cellHeight
            var anchored = false
            for column in 0..<columns where !anchored {
                _ = ghostty_terminal_surface_select_word(surface, (Double(column) + 0.5) * cellWidth, y, &snapshot)
                anchored = snapshot.active
            }
            guard anchored else { return "" }
            _ = ghostty_terminal_surface_set_selection_endpoint(
                surface, GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_START, 0.5 * cellWidth, y, &snapshot
            )
            _ = ghostty_terminal_surface_set_selection_endpoint(
                surface, GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_END, (Double(columns) - 0.5) * cellWidth, y, &snapshot
            )
            var text = ghostty_text_s()
            guard ghostty_terminal_surface_read_selection(surface, &text) == GHOSTTY_TERMINAL_SURFACE_INPUT_SENT else {
                return ""
            }
            defer { _ = ghostty_terminal_surface_free_text(surface, &text) }
            let bytes = UnsafeRawBufferPointer(start: text.text, count: Int(text.text_len))
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }

    /// The area's rows as Herdr sent them: each cell's symbol, a covered cell adding nothing, without
    /// surrounding blanks.
    static func rows(of frame: HerdrFrame, in area: HerdrSurfaceRect) -> [String] {
        (0..<Int(area.height)).map { y in
            let start = (Int(area.y) + y) * Int(frame.width) + Int(area.x)
            return frame.cells[start..<(start + Int(area.width))]
                .map(\.symbol)
                .joined()
                .trimmingCharacters(in: .whitespaces)
        }
    }
}

/// Server messages for a scripted Herdr session.
enum HerdrServerScript {
    struct Pane {
        let id: String
        let x: UInt16
        var y: UInt16 = 0
        let width: UInt16
        let height: UInt16
        var focused = false
        /// The viewport's lines from the bottom, the most it can be, and the program's rows.
        var scroll: (fromBottom: UInt64, max: UInt64, rows: UInt64)?
        var mouseReporting = false
        var alternateScreen = false
        /// Even, as Herdr's is between changes.
        var contentRevision: UInt64 = 2
        /// The pane with Herdr's borders around its text area, when it has any.
        var rect: (x: UInt16, y: UInt16, width: UInt16, height: UInt16)?
    }

    /// The scripted session's panes by tab: `t1` holds `w1:p1` and `w1:p2`, `t2` holds `w1:p3` and
    /// `w1:p4`, and `t3` holds `w1:p5`.
    static let sessionPanes: [String: [String]] = ["t1": ["w1:p1", "w1:p2"], "t2": ["w1:p3", "w1:p4"], "t3": ["w1:p5"]]

    /// A recorded v0.9.3 welcome.
    static func welcome() throws -> [UInt8] {
        HerdrWire.frame(try HerdrConnectionTests.frames(HerdrConnectionTests.recording("herdr-01-handshake-all-caps-A"))[0])
    }

    /// `panes` and `agents` are the snapshot's JSON entries, made with `snapshotPane` and
    /// `snapshotAgent`. Without `panes` it lists the panes of its tabs in the scripted session
    /// (`sessionPanes`), as Herdr lists every pane, but those `closed` names.
    /// The focused tab is labelled `tabLabel`, a name of the user's unless `customTabLabel` is false, and is
    /// `zoomed` or not; `otherTabs` are further tabs of
    /// workspace `w1`, by id, each named after its id, and zoomed when in `zoomedOtherTabs`. Workspace `w1`
    /// is listed when it has a label.
    static func snapshot(
        revision: UInt64,
        boot: String = "boot",
        workspaceLabel: String? = nil,
        tabLabel: String = "main",
        customTabLabel: Bool = true,
        zoomed: Bool = false,
        focusedTab: String = "t1",
        otherTabs: [String] = [],
        zoomedOtherTabs: [String] = [],
        focusedPane: String? = "w1:p1",
        panes: [String]? = nil,
        closed: Set<String> = [],
        agents: [String] = []
    ) -> [UInt8] {
        let panes = panes ?? ([focusedTab] + otherTabs).flatMap { tab in
            (sessionPanes[tab] ?? []).filter { !closed.contains($0) }.map { snapshotPane($0, tab: tab) }
        }
        let tabs = ([(focusedTab, tabLabel, true)] + otherTabs.map { ($0, $0, false) }).enumerated().map { index, tab in
            """
            {"tab_id":"\(tab.0)","workspace_id":"w1","number":\(index + 1),"label":"\(tab.1)","custom_label":\(!tab.2 || customTabLabel),
             "zoomed":\(tab.2 ? zoomed : zoomedOtherTabs.contains(tab.0)),"focused":\(tab.2),"agent_status":"idle"}
            """
        }
        let workspaces = workspaceLabel.map { label in
            """
            {"workspace_id":"w1","active_tab_id":"\(focusedTab)","number":1,"label":"\(label)","custom_label":true,
             "focused":true,"agent_status":"idle"}
            """
        }
        let json = """
        {"boot_id":"\(boot)","revision":\(revision),"focused_workspace_id":"w1","focused_tab_id":"\(focusedTab)",
         "focused_pane_id":\(json(focusedPane)),"workspaces":[\(workspaces ?? "")],"tabs":[\(tabs.joined(separator: ","))],
         "panes":[\(panes.joined(separator: ","))],"agents":[\(agents.joined(separator: ","))]}
        """
        return control(HerdrControlKind.snapshot, json)
    }

    /// A workspace of a scripted session: its tabs in order, each with its panes, and the tab this phone
    /// has there, the first unless given.
    struct Workspace {
        let id: String
        var label: String
        let tabs: [(id: String, panes: [String])]
        var activeTab: String?
    }

    /// A snapshot of `workspaces` in order, with this phone at `focusedTab` and `focusedPane`, and `agents`;
    /// each tab is named after its id, and zoomed when in `zoomedTabs`.
    static func snapshot(
        revision: UInt64,
        boot: String = "boot",
        workspaces: [Workspace],
        focusedTab: String,
        focusedPane: String?,
        zoomedTabs: Set<String> = [],
        customTabLabels: Bool = true,
        agents: [String] = []
    ) -> [UInt8] {
        let focusedWorkspace = workspaces.first { $0.tabs.contains { $0.id == focusedTab } }?.id
        let workspaceEntries = workspaces.enumerated().map { index, workspace in
            let active = workspace.id == focusedWorkspace ? focusedTab : workspace.activeTab ?? workspace.tabs[0].id
            return """
            {"workspace_id":"\(workspace.id)","active_tab_id":"\(active)","number":\(index + 1),
             "label":"\(workspace.label)","custom_label":true,"focused":\(workspace.id == focusedWorkspace),
             "agent_status":"idle"}
            """
        }
        let tabEntries = workspaces.flatMap { workspace in
            workspace.tabs.enumerated().map { index, tab in
                """
                {"tab_id":"\(tab.id)","workspace_id":"\(workspace.id)","number":\(index + 1),"label":"\(tab.id)",
                 "custom_label":\(customTabLabels),"zoomed":\(zoomedTabs.contains(tab.id)),"focused":\(tab.id == focusedTab),
                 "agent_status":"idle"}
                """
            }
        }
        let paneEntries = workspaces.flatMap { workspace in
            workspace.tabs.flatMap { tab in
                tab.panes.map { pane in
                    """
                    {"pane_id":"\(pane)","workspace_id":"\(workspace.id)","tab_id":"\(tab.id)","label":null,
                     "cwd":null,"foreground_cwd":null,"focused":\(pane == focusedPane),"right_click_passthrough":false}
                    """
                }
            }
        }
        let json = """
        {"boot_id":"\(boot)","revision":\(revision),"focused_workspace_id":\(json(focusedWorkspace)),
         "focused_tab_id":"\(focusedTab)","focused_pane_id":\(json(focusedPane)),
         "workspaces":[\(workspaceEntries.joined(separator: ","))],"tabs":[\(tabEntries.joined(separator: ","))],
         "panes":[\(paneEntries.joined(separator: ","))],"agents":[\(agents.joined(separator: ","))]}
        """
        return control(HerdrControlKind.snapshot, json)
    }

    /// `endpoint.agent-completions.v1`, as Herdr sends it before the snapshot of the same revision.
    static func agentCompletions(revision: UInt64, boot: String = "boot", _ completions: [String: UInt64]) -> [UInt8] {
        let entries = completions.sorted { $0.key < $1.key }.map { #""\#($0.key)":\#($0.value)"# }
        return control(
            HerdrControlKind.agentCompletions,
            #"{"boot_id":"\#(boot)","revision":\#(revision),"completions":{\#(entries.joined(separator: ","))}}"#
        )
    }

    /// A `SemanticNotification`, laid out as Herdr's server sends an agent's.
    static func notification(
        _ kind: HerdrSemanticNotification.Kind,
        title: String,
        body: String? = nil,
        agent: String? = nil,
        workspace: String? = nil,
        tab: String? = nil,
        pane: String? = nil
    ) -> [UInt8] {
        var writer = HerdrWireWriter()
        writer.variant(14)
        switch kind {
        case .needsAttention: writer.variant(0)
        case .finished: writer.variant(1)
        case .updateInstalled: writer.variant(2)
        case .custom: writer.variant(3)
        }
        writer.string(title)
        writer.optional(body) { $0.string($1) }
        writer.optional(nil as UInt32?) { $0.variant($1) }
        for field in [agent, workspace, tab, pane] {
            writer.optional(field) { $0.string($1) }
        }
        writer.optional(nil as UInt32?) { $0.variant($1) }
        return HerdrWire.frame(writer.bytes)
    }

    /// A program's OSC 52 write, as Herdr sends its bytes in base64.
    static func clipboard(_ base64: String) -> [UInt8] {
        var writer = HerdrWireWriter()
        writer.variant(5)
        writer.string(base64)
        return HerdrWire.frame(writer.bytes)
    }

    static func bell(count: UInt16 = 1) -> [UInt8] {
        var writer = HerdrWireWriter()
        writer.variant(9)
        writer.u16(count)
        return HerdrWire.frame(writer.bytes)
    }

    private static func control(_ kind: String, _ data: String) -> [UInt8] {
        var writer = HerdrWireWriter()
        writer.variant(20)
        writer.string(kind)
        writer.string(data)
        return HerdrWire.frame(writer.bytes)
    }

    static func snapshotPane(
        _ id: String,
        workspace: String = "w1",
        tab: String = "t1",
        label: String? = nil,
        cwd: String? = nil,
        foregroundCWD: String? = nil,
        rightClickPassthrough: Bool = false
    ) -> String {
        """
        {"pane_id":"\(id)","workspace_id":"\(workspace)","tab_id":"\(tab)","label":\(json(label)),"cwd":\(json(cwd)),
         "foreground_cwd":\(json(foregroundCWD)),"focused":false,"right_click_passthrough":\(rightClickPassthrough)}
        """
    }

    static func snapshotAgent(
        _ paneID: String,
        name: String? = nil,
        title: String? = nil,
        terminalTitle: String? = nil,
        terminalTitleStripped: String? = nil,
        agent: String? = nil,
        displayAgent: String? = nil,
        workspace: String = "w1",
        tab: String = "t1",
        status: HerdrAgentStatus = .working,
        stateChange: UInt64 = 1,
        stateLabels: [(state: String, word: String)] = []
    ) -> String {
        let labels = stateLabels.map { "[\(json($0.state)),\(json($0.word))]" }.joined(separator: ",")
        return """
        {"pane_id":"\(paneID)","workspace_id":"\(workspace)","tab_id":"\(tab)","name":\(json(name)),
         "display_agent":\(json(displayAgent)),"agent":\(json(agent)),"title":\(json(title)),
         "terminal_title":\(json(terminalTitle)),"terminal_title_stripped":\(json(terminalTitleStripped)),
         "agent_status":"\(status.rawValue)","state_change_seq":\(stateChange),
         "state_labels":[\(labels)],"tokens":[],"focused":false}
        """
    }

    private static func json(_ value: String?) -> String {
        value.map { #""\#($0)""# } ?? "null"
    }

    /// A full surface of the given lines, all of one width, and a popup for the terminal `popup` names, if
    /// any: titled `popupTitle`, of `popupLines` (one cell unless given). A cell whose symbol `foreground`
    /// lists has that colour.
    static func surface(
        boot: String = "boot",
        projection: UInt64,
        revision: UInt64,
        lines: [String],
        panes: [Pane],
        popup: String? = nil,
        popupTitle: String = "popup",
        popupLines: [String] = ["p"],
        popupMouseReporting: Bool = false,
        foreground: [Character: UInt32] = [:]
    ) -> [UInt8] {
        var writer = HerdrWireWriter()
        writer.variant(13)
        writer.string(boot)
        writer.u64(projection)
        writer.u64(revision)
        frame(lines, foreground: foreground, to: &writer)
        writer.array(panes) { writer, pane in
            writer.string(pane.id)
            writer.u64(pane.contentRevision)
            let textArea = (x: pane.x, y: pane.y, width: pane.width, height: pane.height)
            for rect in [pane.rect ?? textArea, textArea] {
                writer.u16(rect.x)
                writer.u16(rect.y)
                writer.u16(rect.width)
                writer.u16(rect.height)
            }
            writer.optional(nil as UInt8?) { $0.u8($1) }
            if let scroll = pane.scroll {
                writer.u8(1)
                writer.u64(scroll.fromBottom)
                writer.u64(scroll.max)
                writer.u64(scroll.rows)
            } else {
                writer.u8(0)
            }
            writer.bool(pane.focused)
            writer.bool(pane.mouseReporting)
            writer.bool(false)
            writer.bool(pane.alternateScreen)
            writer.u32(0)
            writer.u32(0)
        }
        writer.array([UInt8]()) { $0.u8($1) }
        writer.optional(popup) { writer, terminalID in
            writer.string(terminalID)
            writer.string(popupTitle)
            writer.optional(nil as UInt8?) { $0.u8($1) }
            writer.optional(nil as UInt8?) { $0.u8($1) }
            frame(popupLines, to: &writer)
            writer.bool(popupMouseReporting)
            writer.bool(false)
            writer.u32(0)
            writer.u32(0)
        }
        for _ in 0..<3 {
            writer.array([UInt8]()) { $0.u8($1) }
        }
        return HerdrWire.frame(writer.bytes)
    }

    private static func frame(
        _ lines: [String],
        foreground: [Character: UInt32] = [:],
        to writer: inout HerdrWireWriter
    ) {
        let width = lines.first?.count ?? 0
        precondition(lines.allSatisfy { $0.count == width })
        writer.array(Array(lines.joined())) { writer, character in
            writer.string(String(character))
            writer.u32(foreground[character] ?? 0)
            writer.u32(0)
            writer.u16(0)
            writer.bool(false)
            writer.optional(nil as UInt32?) { $0.u32($1) }
        }
        writer.u16(UInt16(width))
        writer.u16(UInt16(lines.count))
        writer.optional(nil as UInt8?) { $0.u8($1) }
        writer.array([String]()) { $0.string($1) }
        writer.byteArray([])
    }

    static func keyboardReportAll(_ enabled: Bool) -> [UInt8] {
        var writer = HerdrWireWriter()
        writer.variant(17)
        writer.bool(enabled)
        return HerdrWire.frame(writer.bytes)
    }

    static func inputRefused(_ message: String) -> [UInt8] {
        var writer = HerdrWireWriter()
        writer.variant(15)
        writer.string(message)
        return HerdrWire.frame(writer.bytes)
    }

    /// Herdr's answer to a `pane.zoom` on tab `t1`, as v0.9.3 sends it: `changed` says whether the zoom
    /// changed, and `panes` where every pane of the tab sits, the first focused, also while it's zoomed.
    static func zoomReply(
        id: String,
        changed: Bool,
        zoomed: Bool,
        tab: String = "t1",
        panes: [(id: String, x: UInt16, y: UInt16, width: UInt16, height: UInt16)]
    ) -> [UInt8] {
        let focused = panes.first?.id ?? ""
        let rects = panes.map { pane in
            "{\"focused\":\(pane.id == focused),\"pane_id\":\"\(pane.id)\",\"rect\":{\"height\":\(pane.height),"
                + "\"width\":\(pane.width),\"x\":\(pane.x),\"y\":\(pane.y)}}"
        }
        let reason = changed ? "" : ",\"reason\":\"\(zoomed ? "already_zoomed" : "already_unzoomed")\""
        let zoom = "{\"changed\":\(changed),\"zoom_changed\":\(changed),\"focus_changed\":false\(reason),"
            + "\"pane_id\":\"\(focused)\",\"focused_pane_id\":\"\(focused)\",\"zoomed\":\(zoomed),"
            + "\"layout\":{\"workspace_id\":\"w1\",\"tab_id\":\"\(tab)\",\"zoomed\":\(zoomed),"
            + "\"area\":{\"x\":0,\"y\":0,\"width\":80,\"height\":24},\"focused_pane_id\":\"\(focused)\","
            + "\"panes\":[\(rects.joined(separator: ","))],\"splits\":[]}}"
        return HerdrConnectionTests.reply(id: id, json: "{\"type\":\"pane_zoom\",\"zoom\":\(zoom)}")
    }

    /// Herdr's answer to a show or hide; a show's `projection` is the floor its frame must reach.
    static func surfaceSetReply(id: String, active: Bool, projection: UInt64 = 1) -> [UInt8] {
        HerdrConnectionTests.reply(
            id: id,
            json: #"{"type":"client_shell_surface_set","active":\#(active),"projection_revision":\#(projection)}"#
        )
    }
}

/// What Remux wrote, decoded.
enum ClientWrite: Equatable {
    case hello(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int, surfaceActive: Bool)
    case resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32)
    case surfaceSet(id: String, active: Bool)
    case theme(HerdrHostThemeUpdate)
    case focus(Bool)
    /// A pane input message, as framed.
    case paneInput([UInt8])
    case paneFocus(id: String, paneID: String)
    /// A `pane.zoom`, with its mode: "on" or "off". `paneID` is nil for one that names no pane, which Herdr
    /// takes as the pane focused on the tab this client views.
    case paneZoom(id: String, paneID: String?, mode: String)
    /// Any other command, with its parameters as text.
    case command(id: String, method: String, params: [String: String])
    case ping(data: String)
    case other(tag: UInt32, kind: String)

    var isSurfaceSet: Bool {
        if case .surfaceSet = self { true } else { false }
    }

    static func decode(_ frame: [UInt8]) throws -> ClientWrite {
        var reader = HerdrWireReader(Array(frame.dropFirst(4)))
        let tag = try reader.variant()
        switch tag {
        case 20:
            let kind = try reader.string()
            let data = try reader.string()
            if kind == HerdrControlKind.healthPing { return .ping(data: data) }
            guard kind == HerdrControlKind.hello else { return .other(tag: tag, kind: kind) }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any])
            let size = try XCTUnwrap(json["surface_size"] as? [String: Int])
            return .hello(
                cols: try XCTUnwrap(size["cols"]),
                rows: try XCTUnwrap(size["rows"]),
                cellWidth: try XCTUnwrap(json["cell_width_px"] as? Int),
                cellHeight: try XCTUnwrap(json["cell_height_px"] as? Int),
                surfaceActive: try XCTUnwrap(json["surface_active"] as? Bool)
            )
        case 12:
            let cellWidth = try reader.u32()
            let cellHeight = try reader.u32()
            return .resize(cols: try reader.u16(), rows: try reader.u16(), cellWidth: cellWidth, cellHeight: cellHeight)
        case 13:
            return .paneInput(frame)
        case 15:
            let request = try HerdrConnectionTests.request(frame)
            if request.method == HerdrScreenModel.paneFocusMethod || request.method == "pane.zoom" {
                _ = try reader.string()
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(try reader.string().utf8)) as? [String: Any]
                )
                let params = try XCTUnwrap(json["params"] as? [String: String])
                guard request.method == "pane.zoom" else {
                    return .paneFocus(id: request.id, paneID: try XCTUnwrap(params["pane_id"]))
                }
                return .paneZoom(id: request.id, paneID: params["pane_id"], mode: try XCTUnwrap(params["mode"]))
            }
            guard request.method == HerdrConnection.surfaceSetMethod else {
                _ = try reader.string()
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(try reader.string().utf8)) as? [String: Any]
                )
                let params = (json["params"] as? [String: Any] ?? [:]).mapValues { value in
                    if let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() {
                        return flag.boolValue ? "true" : "false"
                    }
                    return "\(value)"
                }
                return .command(id: request.id, method: request.method, params: params)
            }
            return .surfaceSet(id: request.id, active: try XCTUnwrap(request.params?["active"]))
        case 17:
            func rgb() throws -> HerdrRGB {
                HerdrRGB(red: try reader.u8(), green: try reader.u8(), blue: try reader.u8())
            }
            switch try reader.variant() {
            case 0:
                let kind: HerdrHostThemeUpdate.DefaultColorKind = try reader.variant() == 0 ? .foreground : .background
                return .theme(.defaultColor(kind, try rgb()))
            case 1:
                var colors: [UInt8: HerdrRGB] = [:]
                for _ in 0..<(try reader.u64()) {
                    let index = try reader.u8()
                    colors[index] = try rgb()
                }
                return .theme(.paletteColors(colors))
            default:
                return .theme(.appearance(try reader.variant() == 0 ? .dark : .light))
            }
        case 18:
            return .focus(try reader.bool())
        default:
            return .other(tag: tag, kind: "")
        }
    }
}

/// Holds the model's renderer registrations and closes back while asked to, and logs each close as its
/// surface is about to be freed, so a test can order closes against a stop.
@MainActor
final class RendererFenceGate {
    var holdsRegistrations = false
    /// Panes whose registrations are held even while others go.
    var holdsRegistrationsOf: Set<String> = []
    var holdsCloses = false
    private(set) var log: [String] = []
    private var heldRegistrations: [() -> Void] = []
    private var heldCloses: [(paneID: String, deliver: () -> Void)] = []

    var heldRegistrationCount: Int { heldRegistrations.count }
    var heldCloseCount: Int { heldCloses.count }

    var factory: HerdrScreenModel.RendererFenceFactory {
        { [self] engine, paneID, terminal in
            GatedRendererFence(
                base: HerdrPaneRendererFence(engine: engine, paneID: paneID, terminal: terminal),
                paneID: paneID,
                gate: self
            )
        }
    }

    func record(_ event: String) {
        log.append(event)
    }

    func releaseRegistrations() {
        holdsRegistrations = false
        holdsRegistrationsOf.removeAll()
        let held = heldRegistrations
        heldRegistrations.removeAll()
        held.forEach { $0() }
    }

    /// Lets the held closes of `paneID` complete, or, without one, every held close and those to come.
    func releaseCloses(of paneID: String? = nil) {
        if paneID == nil { holdsCloses = false }
        let released = heldCloses.filter { paneID == nil || $0.paneID == paneID }
        heldCloses.removeAll { paneID == nil || $0.paneID == paneID }
        released.forEach { $0.deliver() }
    }

    fileprivate func passRegistration(of paneID: String, _ deliver: @escaping () -> Void) {
        if holdsRegistrations || holdsRegistrationsOf.contains(paneID) { heldRegistrations.append(deliver) } else { deliver() }
    }

    fileprivate func passClose(of paneID: String, _ deliver: @escaping () -> Void) {
        if holdsCloses { heldCloses.append((paneID, deliver)) } else { deliver() }
    }
}

/// Herdr's own fence, with its answers passed through a `RendererFenceGate`.
@MainActor
private final class GatedRendererFence: TerminalPaneRendererFence {
    private let base: HerdrPaneRendererFence
    private let paneID: String
    private let gate: RendererFenceGate

    init(base: HerdrPaneRendererFence, paneID: String, gate: RendererFenceGate) {
        self.base = base
        self.paneID = paneID
        self.gate = gate
    }

    func registerRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
    ) {
        base.registerRenderer(surface) { [gate, paneID] result in
            gate.passRegistration(of: paneID) { completion(result) }
        }
    }

    func unregisterRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        base.unregisterRenderer(surface) { [gate, paneID] in
            gate.passClose(of: paneID) {
                gate.record("closed \(paneID)")
                completion()
            }
        }
    }
}

/// A `HerdrScreenModel` over scripted bridges: each bridge the model opens is a new
/// `FakeBridgeTransport`, and every state the model reports is kept.
@MainActor
final class HerdrModelHarness {
    actor Bridges {
        private(set) var opened: [FakeBridgeTransport] = []
        /// What each opened bridge is for.
        private(set) var kinds: [HerdrBridgeKind] = []
        /// When each opening started.
        private(set) var openingsStartedAt: [ContinuousClock.Instant] = []
        private let openingTakes: Duration
        private var failure: Error?

        init(openingTakes: Duration) {
            self.openingTakes = openingTakes
        }

        func failNextOpen(with error: Error) {
            failure = error
        }

        func open(_ kind: HerdrBridgeKind) async throws -> FakeBridgeTransport {
            openingsStartedAt.append(.now)
            if let failure {
                self.failure = nil
                throw failure
            }
            if openingTakes > .zero { try await Task.sleep(for: openingTakes) }
            let transport = FakeBridgeTransport()
            opened.append(transport)
            kinds.append(kind)
            return transport
        }
    }

    final class StateLog {
        var updates: [TerminalRuntimeStateUpdate] = []
        var notifications: [HerdrScreenModel.NotificationEvent] = []
    }

    let bridges: Bridges
    let stateLog: StateLog
    /// The clipboard programs in the session write, so no test writes the simulator's.
    let pasteboard: FakePasteboard
    let model: HerdrScreenModel

    init(
        settings: TerminalSettings = .default,
        timing: HerdrConnection.Timing = HerdrConnection.Timing(),
        recovery: HerdrScreenModel.RecoveryTiming = HerdrScreenModel.RecoveryTiming(),
        failingOpenWith openError: Error? = nil,
        bridgeOpeningTakes: Duration = .zero,
        producerFailure: ProducerFailure? = nil,
        rendererFenceGate: RendererFenceGate? = nil,
        switchingCueDelay: Duration = HerdrScreenModel.switchingCueDelay,
        zoomKeepers: HerdrZoomKeepers = HerdrZoomKeepers(store: InMemoryHerdrOwnedZoomStore()),
        server: SavedServer = SavedServer(displayName: "Herdr Host", host: "herdr.example.test", username: "builder")
    ) async {
        let bridges = Bridges(openingTakes: bridgeOpeningTakes)
        let stateLog = StateLog()
        if let openError { await bridges.failNextOpen(with: openError) }
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "main")
        let target = SessionTarget(
            server: server,
            workspace: workspace,
            sshAuth: .password(
                username: server.username,
                password: "secret",
                identityID: server.identityID,
                displayLabel: server.displayName
            ),
            terminalSettings: settings
        )
        let pasteboard = FakePasteboard()
        self.bridges = bridges
        self.stateLog = stateLog
        self.pasteboard = pasteboard
        model = HerdrScreenModel(
            target: target,
            sessionInstanceID: UUID(),
            openBridge: { kind in try await bridges.open(kind) },
            onRuntimeStateChange: { stateLog.updates.append($0) },
            onNotification: { stateLog.notifications.append($0) },
            connectionTiming: timing,
            recoveryTiming: recovery,
            switchingCueDelay: switchingCueDelay,
            engine: producerFailure.map {
                HerdrTerminalEngine(cellWidthPx: 1, cellHeightPx: 1, makeProducer: SwitchableProducer.factory($0))
            } ?? HerdrTerminalEngine(cellWidthPx: 1, cellHeightPx: 1),
            zoomKeepers: zoomKeepers,
            makeRendererFence: rendererFenceGate?.factory ?? Self.herdrRendererFence,
            clipboard: TerminalClipboard(pasteboard: pasteboard)
        )
    }

    private static let herdrRendererFence: HerdrScreenModel.RendererFenceFactory = {
        HerdrPaneRendererFence(engine: $0, paneID: $1, terminal: $2)
    }

    var states: [TerminalRuntimeState] { stateLog.updates.map(\.state) }

    /// The bridge the model opened `index`th, waiting up to `timeout` for it.
    func bridge(_ index: Int = 0, timeout: Duration = .seconds(3)) async throws -> FakeBridgeTransport {
        try await waitUntil("bridge \(index) wasn't opened", timeout: timeout) {
            await self.bridges.opened.count > index
        }
        return await bridges.opened[index]
    }

    func setScreenSize(_ size: CGSize = CGSize(width: 390, height: 844)) {
        model.terminalScreenAdapter.prepareInitialViewport(size: size, scale: 3)
    }

    private static var screenSizes: [[UInt16]: CGSize] = [:]

    /// The screen that gives `columns` x `rows` cells, as a recording made at that size needs: Herdr draws
    /// at the size the show asks for, and only such a frame completes the show. Measured once per size, and
    /// by a test before its model opens a bridge: the search holds the main actor, and on a slow machine
    /// long enough to pass the model's hello deadline, after which the model opens another bridge.
    static func screenSize(columns: UInt16, rows: UInt16) throws -> CGSize {
        if let size = screenSizes[[columns, rows]] { return size }
        let runtime = try GhosttyKitRuntime(terminalSettings: .default)
        let lengths = stride(from: CGFloat(40), through: 4000, by: 1)
        let width = try lengths.first {
            try runtime.measureTmuxViewportLayout(size: CGSize(width: $0, height: 844), scale: 3)?.controlViewport.columns == columns
        }
        let height = try lengths.first {
            try runtime.measureTmuxViewportLayout(size: CGSize(width: 390, height: $0), scale: 3)?.controlViewport.rows == rows
        }
        let size = CGSize(
            width: try XCTUnwrap(width, "no screen width gives \(columns) columns"),
            height: try XCTUnwrap(height, "no screen height gives \(rows) rows")
        )
        screenSizes[[columns, rows]] = size
        return size
    }

    /// A frame of `lines` at the size a show asks for, padded with blanks: Herdr answers a show with a
    /// frame at the client's size, and only such a frame completes the show.
    func shownSurface(
        boot: String = "boot",
        projection: UInt64,
        revision: UInt64,
        lines: [String],
        panes: [HerdrServerScript.Pane],
        popup: String? = nil
    ) throws -> [UInt8] {
        let viewport = try XCTUnwrap(model.measurement).controlViewport
        let columns = Int(viewport.columns)
        let padded = lines.map { $0.padding(toLength: columns, withPad: " ", startingAt: 0) }
            + Array(repeating: String(repeating: " ", count: columns), count: max(Int(viewport.rows) - lines.count, 0))
        return HerdrServerScript.surface(boot: boot, projection: projection, revision: revision, lines: padded, panes: panes, popup: popup)
    }

    /// The bridge's writes from `index` on, decoded, once there are `count` of them.
    func writes(
        _ bridge: FakeBridgeTransport,
        from index: Int = 0,
        count: Int
    ) async throws -> [ClientWrite] {
        var writes: [ClientWrite] = []
        for position in index..<(index + count) {
            writes.append(try ClientWrite.decode(try await bridge.written(position)))
        }
        return writes
    }

    /// The next `surface.set` from `index` on, waiting for it; `index` moves past it.
    func nextSurfaceSet(_ bridge: FakeBridgeTransport, from index: inout Int) async throws -> (id: String, active: Bool) {
        while true {
            let write = try ClientWrite.decode(try await bridge.written(index))
            index += 1
            if case .surfaceSet(let id, let active) = write { return (id, active) }
        }
    }

    func waitUntil(
        _ failure: String,
        timeout: Duration = .seconds(3),
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(failure)
        throw HarnessTimeout()
    }

    struct HarnessTimeout: Error {}

    /// Each shown pane's rows, as its renderer shows them, by pane id.
    func shownRows() -> [String: [String]] {
        var shown: [String: [String]] = [:]
        for pane in model.layout?.panes ?? [] where pane.hasTextArea {
            guard let surface = model.paneSurface(pane.paneID), let area = pane.innerRect else { continue }
            shown[pane.paneID] = RendererText.rows(
                of: surface.renderer,
                columns: Int(area.width),
                rows: Int(area.height)
            )
        }
        return shown
    }
}

/// Turns producer failures on and off for every pane producer an engine makes with
/// `SwitchableProducer.factory`.
final class ProducerFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

/// GhosttyKit's pane producer, whose feeds and resizes fail while its `ProducerFailure` is on, as they
/// do after an allocation failure.
final class SwitchableProducer: HerdrPaneProducing {
    private let base: HerdrPaneProducer
    private let failure: ProducerFailure

    init(columns: UInt16, rows: UInt16, failure: ProducerFailure) throws {
        base = try HerdrPaneProducer(columns: columns, rows: rows)
        self.failure = failure
    }

    static func factory(_ failure: ProducerFailure) -> HerdrTerminalEngine.ProducerFactory {
        { try SwitchableProducer(columns: $0, rows: $1, failure: failure) }
    }

    private var failing: Bool { failure.isOn }

    func retainTerminal() throws -> HerdrRetainedTerminal {
        try base.retainTerminal()
    }

    func feed(_ bytes: [UInt8]) -> ghostty_terminal_producer_result_e {
        failing ? GHOSTTY_TERMINAL_PRODUCER_RESULT_SEMANTIC_FAILURE : base.feed(bytes)
    }

    func resizeAndFeed(
        columns: UInt16,
        rows: UInt16,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32,
        bytes: [UInt8]
    ) -> ghostty_terminal_producer_result_e {
        failing
            ? GHOSTTY_TERMINAL_PRODUCER_RESULT_SEMANTIC_FAILURE
            : base.resizeAndFeed(columns: columns, rows: rows, cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx, bytes: bytes)
    }

    func resize(
        columns: UInt16,
        rows: UInt16,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32
    ) -> ghostty_terminal_producer_result_e {
        failing
            ? GHOSTTY_TERMINAL_PRODUCER_RESULT_SEMANTIC_FAILURE
            : base.resize(columns: columns, rows: rows, cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx)
    }
}
