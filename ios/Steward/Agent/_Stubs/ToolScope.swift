//
//  ToolScope.swift  (Track C stub — Agent/_Stubs/)
//
//  DELETE AT MERGE — Pod B owns canonical per addendum §1.8.
//  Surface (ToolScope + ArgConstraints + AnyCodable) must match Pod B's
//  `Agent/ToolScope.swift` exactly. At merge: Pod B's file wins; this
//  stub is deleted.
//
//  Addendum §1.8: typed tool-scope. The coordinator gets every tool with no
//  constraints; a domain agent gets a subset with `fixedArgs` forcing
//  `domain=<self>` so it can't file work for another team.
//

import Foundation

/// Small AnyCodable shim for fixed-arg values. Limited to the scalar JSON
/// types tool args actually use (string, int, double, bool, null) so we
/// don't drag a generic JSON tree into the codebase.
enum AnyCodable: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i):    try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b):   try c.encode(b)
        case .null:          try c.encodeNil()
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self)    { self = .bool(b); return }
        if let i = try? c.decode(Int.self)     { self = .int(i); return }
        if let d = try? c.decode(Double.self)  { self = .double(d); return }
        if let s = try? c.decode(String.self)  { self = .string(s); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "AnyCodable: unsupported scalar"
        )
    }
}

struct ArgConstraints: Codable, Equatable, Sendable {
    /// e.g. `["domain": .string("money")]` forces the value regardless of
    /// what the LLM emits.
    var fixedArgs: [String: AnyCodable]
    /// Whitelist of permitted values per arg name. nil = no whitelist.
    var allowedValues: [String: [AnyCodable]]

    static let none = ArgConstraints(fixedArgs: [:], allowedValues: [:])
}

struct ToolScope: Codable, Equatable, Sendable {
    var allowedTools: Set<ToolId>
    var argConstraints: [ToolId: ArgConstraints]

    /// Convenience: full surface, no constraints. Coordinator scope.
    static let coordinator: ToolScope = ToolScope(
        allowedTools: Set(ToolId.allCases),
        argConstraints: [:]
    )

    /// Build a domain-scoped scope: pin `domain` to the named team for every
    /// tool that takes a `domain` argument. Subset chosen per spec §7
    /// (domain agents own their instruments + commitments + memory).
    static func domain(_ domain: String) -> ToolScope {
        let allowed: Set<ToolId> = [
            .eventCapture, .eventList, .eventRecentSummary,
            .instrumentCreate, .instrumentList, .instrumentRead,
            .instrumentApplyEvent, .instrumentUpdateDefinition, .instrumentArchive,
            .commitmentCreate, .commitmentList, .commitmentComplete,
            .commitmentAbandon, .commitmentSnooze,
            .memorySave, .memorySearch, .memoryForget,
            .memoryStrengthen, .memoryListRecent
        ]
        let pinDomain = ArgConstraints(
            fixedArgs: ["domain": .string(domain)],
            allowedValues: [:]
        )
        var constraints: [ToolId: ArgConstraints] = [:]
        for t in allowed where toolTakesDomainArg(t) {
            constraints[t] = pinDomain
        }
        return ToolScope(allowedTools: allowed, argConstraints: constraints)
    }

    /// Per-tool flag: does the args object have a `domain` field? Exhaustive
    /// switch — adding a new ToolId case = compile error here until the
    /// flag is filled in. (Arch's strict-switch rule, broadening §4 #4.)
    private static func toolTakesDomainArg(_ id: ToolId) -> Bool {
        switch id {
        case .eventCapture, .eventList, .eventRecentSummary,
             .instrumentCreate, .instrumentList,
             .commitmentCreate, .commitmentList,
             .memorySave, .memorySearch, .memoryListRecent:
            return true
        case .instrumentRead, .instrumentApplyEvent, .instrumentUpdateDefinition, .instrumentArchive,
             .commitmentComplete, .commitmentAbandon, .commitmentSnooze,
             .memoryForget, .memoryStrengthen,
             .domainCreate, .domainList, .domainUpdatePrompt, .domainArchive,
             .agentHandoff, .agentCrossConsult,
             .mercyModeEngage, .pauseEngage, .quietHoursSet:
            return false
        }
    }
}
