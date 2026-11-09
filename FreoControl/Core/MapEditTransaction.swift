import Foundation

/// Exactly one mutation attempt. Readback never retries a mutation and cannot
/// establish that the requested geometry was saved without caller comparison.
enum MapEditTransaction {
    static func validate(current: MapSnapshot, baseline: MapSnapshot) throws {
        guard current.productKey == baseline.productKey, current.deviceID == baseline.deviceID,
              current.mapID == baseline.mapID, current.mapVersion == baseline.mapVersion,
              current.editVersion == baseline.editVersion, current.staticMapPayload == baseline.staticMapPayload else {
            throw MapEditError.staleSnapshot
        }
    }

    static func commit(baseline: MapSnapshot, preservedSnapshotURL: URL,
                       send: () async throws -> Data,
                       readBack: () async throws -> MapSnapshot,
                       preserveReadback: (MapSnapshot) throws -> Void) async throws -> MapEditCommitResult {
        var acknowledgement: MapEditAcknowledgement?
        do {
            let raw = try await send()
            // An unreadable acknowledgement is an unknown outcome after send.
            acknowledgement = try? NarwalCodec.mapEditAcknowledgement(raw)
        } catch ConnectorError.outcomeUnknown {
            acknowledgement = nil
        }
        if let reply = acknowledgement, !reply.accepted {
            throw MapEditError.rejected(result: reply.resultCode, code: reply.errorCode, unifiedCode: reply.unifiedErrorCode)
        }
        if let revision = acknowledgement?.editVersion, revision <= baseline.editVersion {
            // A claimed success with an old revision cannot acknowledge this
            // edit. A fresh read may still establish an unconfirmed change.
            acknowledgement = nil
        }
        do {
            let current = try await readBack()
            // An unexpected identity/revision is still evidence of what came
            // back after the write. Preserve it before any check can reject it.
            try preserveReadback(current)
            guard current.productKey == baseline.productKey, current.deviceID == baseline.deviceID,
                  current.mapID == baseline.mapID, current.editVersion > baseline.editVersion,
                  current.mapVersion >= baseline.mapVersion else { throw MapEditError.outcomeUnknown }
            if let expected = acknowledgement?.editVersion, current.editVersion < expected { throw MapEditError.outcomeUnknown }
            return MapEditCommitResult(acknowledged: acknowledgement?.accepted == true,
                                       snapshot: current, preservedSnapshotURL: preservedSnapshotURL)
        } catch { throw MapEditError.outcomeUnknown }
    }
}
