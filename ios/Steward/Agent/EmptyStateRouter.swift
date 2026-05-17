//
//  EmptyStateRouter.swift
//  Steward — Track B
//
//  Deterministic Branch A/B/C classifier from
//  design/coordinator-empty-state-v2.md §2.
//
//  Runs BEFORE any LLM call. Pure function of the user's first message
//  string; same input → same branch, every time. This is the kind of
//  routing decision the lit-review insists belongs out of the model.
//

import Foundation

public enum EmptyStateRouter {
    /// Phrases that indicate the user wants to be walked through setup.
    /// Match is exact (after lowercase+trim) per v2 §2.
    static let setupIntentPhrases: Set<String> = [
        "walk me through it",
        "walk me through this",
        "set me up",
        "help me start",
        "help me set up",
        "set up",
        "setup",
        "i don't know where to start",
        "where do i start",
        "how does this work",
        "what do i do",
    ]

    /// Pure greeting / monosyllabic acknowledgments.
    static let greetingOnly: Set<String> = [
        "hi", "hey", "hello", "yo", "sup",
        "morning", "ok", "okay", "k",
    ]

    /// Returns the branch deterministically. The string is normalized once
    /// (lowercase + trim of leading/trailing whitespace + collapse internal
    /// whitespace) and matched against the two sets in priority order.
    public static func route(_ rawMessage: String) -> EmptyStateBranch {
        let normalized = normalize(rawMessage)

        if setupIntentPhrases.contains(normalized) {
            return .branchBSetupFirst
        }

        // Word count = count of non-empty whitespace-separated tokens.
        let wordCount = normalized
            .split(whereSeparator: { $0.isWhitespace })
            .count

        if wordCount < 3 || greetingOnly.contains(normalized) {
            return .branchCUnclear
        }

        return .branchACaptureFirst
    }

    /// Lowercase, trim outer whitespace, collapse internal runs to single
    /// space. Idempotent. Stable for testing.
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse runs of whitespace to one space.
        let collapsed = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed
    }
}
