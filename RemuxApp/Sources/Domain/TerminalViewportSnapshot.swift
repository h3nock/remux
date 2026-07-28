import Foundation

struct TerminalViewportSnapshot: Equatable, Sendable {
    let workspaceID: SavedWorkspace.ID
    let serverName: String
    let sessionName: String
    let windowID: UUID
    let windowName: String
    let paneID: UUID
    let paneIndex: Int
    let text: String
}
