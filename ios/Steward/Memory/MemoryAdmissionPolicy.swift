//
//  MemoryAdmissionPolicy.swift
//  Steward
//
//  Addendum §1.5: gating on what becomes a memory. Dedup at cosine ≥ 0.95
//  (same type, same domain). Contradiction at cosine ≥ 0.85 (admit with
//  flag). Per-turn admission cap = 3.
//

import Foundation
import GRDB

/// A proposed `memory.save` payload. Built by the `memory.save` tool from
/// the agent's args; passed to the policy to determine admission.
struct MemorySaveProposal: Equatable, Sendable {
    let type: MemoryType
    let text: String
    let domain: String?
    let strength: Double
    let expiresAt: Date?
    let provenanceEventIDs: [EventID]
}

enum AdmissionResult: Equatable, Sendable {
    case admit
    case rejectEphemeral(reason: String)
    case rejectDuplicate(existing: MemoryID, cosine: Double)
    case admitWithContradiction(conflicting: [MemoryID])
    case rejectAdmissionCap
}

enum MemoryAdmissionPolicy {

    /// Per-turn cap on admits. Addendum §1.5: max 3 saves per turn.
    static let perTurnAdmissionCap: Int = 3

    /// Cosine threshold above which a candidate is treated as a duplicate
    /// of an existing memory.
    static let dedupCosine: Float = 0.95

    /// Cosine threshold above which a candidate may contradict an existing
    /// memory of the same type+domain. Admit-with-flag so the next turn can
    /// reconcile.
    static let contradictionCosine: Float = 0.85

    /// Evaluate a save proposal against the live DB. Caller supplies the
    /// already-computed embedding so we don't re-embed inside the policy.
    static func evaluate(
        _ proposal: MemorySaveProposal,
        embedding: [Float],
        turnSaveCount: Int,
        now: Date,
        in db: Database
    ) throws -> AdmissionResult {

        // Cheap reject: cap check first.
        if turnSaveCount >= perTurnAdmissionCap {
            return .rejectAdmissionCap
        }

        // Surface ephemeral-flavored text as a rejection. The coordinator's
        // own heuristics should prevent these from arriving, but defense in
        // depth keeps the memory pool clean.
        if let reason = ephemeralRejection(for: proposal.text) {
            return .rejectEphemeral(reason: reason)
        }

        // Pull candidate rows: same type, same domain (NULL-safe). The dedup
        // / contradiction checks only care about same-type / same-domain
        // peers — a constraint and a preference saying similar things are
        // intentionally allowed to co-exist.
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT memory_id, embedding
                FROM memory_items
                WHERE type = ?
                  AND (domain IS ? OR (domain IS NULL AND ? IS NULL))
                  AND strength_at_last_update > 0
                  AND archived_at IS NULL
            """,
            arguments: [proposal.type.rawValue, proposal.domain, proposal.domain]
        )

        var conflicts: [MemoryID] = []
        for row in rows {
            let blob: Data = row["embedding"]
            guard let other = Embedder.decodeBlob(blob) else { continue }
            let cos = Embedder.cosine(embedding, other)
            if cos >= dedupCosine {
                return .rejectDuplicate(existing: row["memory_id"], cosine: Double(cos))
            }
            if cos >= contradictionCosine {
                conflicts.append(row["memory_id"])
            }
        }

        if !conflicts.isEmpty {
            return .admitWithContradiction(conflicting: conflicts)
        }
        return .admit
    }

    // MARK: - Ephemeral filter

    /// Tiny conservative heuristic. The real anti-ephemeral filter lives in
    /// the coordinator system prompt; this is a safety net that catches the
    /// most obvious slips ("I'm hungry", "feeling tired right now"). We
    /// intentionally do NOT regex-parse user intent broadly — addendum §4
    /// hard reject #2 (text-parsing dispatch) is about tool routing, not
    /// content filtering, but the spirit is "use typed signals first".
    /// This is intentionally narrow.
    private static func ephemeralRejection(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return "empty memory text"
        }
        if trimmed.count < 3 {
            return "memory text too short (\(trimmed.count) chars)"
        }
        let ephemeralPhrases = [
            "right now i'm",
            "i'm hungry",
            "feeling tired",
            "i'm bored",
        ]
        for p in ephemeralPhrases where trimmed.contains(p) {
            return "looks ephemeral (matched phrase '\(p)') — log as event instead"
        }
        return nil
    }
}
