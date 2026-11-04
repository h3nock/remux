import Foundation

struct PreparedTmuxControlTransport {
    let target: SessionTarget
    let transport: any TmuxControlTransport
}

struct RemuxPreparedTransportCache {
    enum ClaimResult {
        case missing
        case claimed(PreparedTmuxControlTransport)
        case discardedStale(PreparedTmuxControlTransport)
    }

    private var preparedByWorkspace: [SavedWorkspace.ID: PreparedTmuxControlTransport] = [:]

    func containsReusableTransport(for target: SessionTarget) -> Bool {
        guard let prepared = preparedByWorkspace[target.workspace.id] else {
            return false
        }
        return prepared.target.canReusePreparedTransport(for: target)
    }

    mutating func store(_ prepared: PreparedTmuxControlTransport) -> PreparedTmuxControlTransport? {
        preparedByWorkspace.updateValue(prepared, forKey: prepared.target.workspace.id)
    }

    mutating func claim(for target: SessionTarget) -> ClaimResult {
        guard let prepared = preparedByWorkspace.removeValue(forKey: target.workspace.id) else {
            return .missing
        }
        guard prepared.target.canReusePreparedTransport(for: target) else {
            return .discardedStale(prepared)
        }
        return .claimed(prepared)
    }

    mutating func remove(workspaceID: SavedWorkspace.ID) -> PreparedTmuxControlTransport? {
        preparedByWorkspace.removeValue(forKey: workspaceID)
    }

    mutating func remove(
        serverID: SavedServer.ID,
        excludingWorkspaceID: SavedWorkspace.ID? = nil
    ) -> [PreparedTmuxControlTransport] {
        let removing = preparedByWorkspace.filter { _, prepared in
            guard prepared.target.server.id == serverID else { return false }
            if let excludingWorkspaceID,
               prepared.target.workspace.id == excludingWorkspaceID {
                return false
            }
            return true
        }
        for workspaceID in removing.keys {
            preparedByWorkspace.removeValue(forKey: workspaceID)
        }
        return Array(removing.values)
    }

    mutating func drain() -> [PreparedTmuxControlTransport] {
        let prepared = Array(preparedByWorkspace.values)
        preparedByWorkspace.removeAll()
        return prepared
    }
}

extension SessionTarget {
    func canReusePreparedTransport(for target: SessionTarget) -> Bool {
        server.id == target.server.id &&
            server.host == target.server.host &&
            server.port == target.server.port &&
            workspace.id == target.workspace.id &&
            workspace.serverID == target.workspace.serverID &&
            workspace.sessionName == target.workspace.sessionName &&
            sshAuth.username == target.sshAuth.username &&
            sshAuth.authFingerprint == target.sshAuth.authFingerprint &&
            terminalSettings == target.terminalSettings
    }
}
