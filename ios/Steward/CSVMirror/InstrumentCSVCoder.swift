//
//  InstrumentCSVCoder.swift
//  Steward — Track F
//
//  Adapter that lifts Pod C's `InstrumentKind` (addendum §1.2) into the
//  closure-based coder Track F's `CSVMirrorWatcher` actually dispatches on.
//
//  Two pieces:
//   1. `InstrumentCSVCoder` — Sendable value type holding closures the watcher
//      calls. Pre-merge this was a parallel adapter; post-merge it bridges
//      Pod C's protocol surface (`K.renderCSV`, `K.parseCSVOverride`) plus a
//      generic state.csv renderer that walks the state JSON.
//   2. `InstrumentCSVCoderRegistry` — actor map `kindID -> InstrumentCSVCoder`.
//      `TrackFBootstrap.registerKindCoders()` registers all 7 of Pod C's
//      kinds; `CSVMirrorWatcher` looks up by `instruments.kind`.
//
//  Hard reject #9 still holds: no `switch kindID { ... }` anywhere; every
//  dispatch goes through the registry.
//

import Foundation

/// Operations the CSV mirror needs per kind. Track C's `InstrumentKind`
/// static funcs map onto these closures via `InstrumentCSVCoder.init(kind:)`.
struct InstrumentCSVCoder: Sendable {
    /// Render the canonical editable table for an instrument. Mirrors
    /// `K.renderCSV(state:definition:recentEvents:)`.
    let renderData: @Sendable (
        _ stateJSON: String,
        _ definitionJSON: String,
        _ recentEventsJSON: [String]
    ) throws -> CSVTable

    /// Render the write-only `state.csv` snapshot. Pod C's `InstrumentKind`
    /// doesn't expose a per-kind state renderer in v1, so this defaults to a
    /// generic "field, value" walk over the state JSON's top-level keys —
    /// kind-agnostic and useful for "what does Steward think my state is".
    let renderState: @Sendable (
        _ stateJSON: String,
        _ definitionJSON: String
    ) throws -> CSVTable

    /// Compute corrections from a user-edited table. Mirrors
    /// `K.parseCSVOverride(_:current:definition:)`. Returns Pod C's typed
    /// `ManualCorrection`s; the watcher emits each as a `manual_correction`
    /// event and folds it back into state via `InstrumentRegistry.applyCorrection`.
    let parseOverride: @Sendable (
        _ table: CSVTable,
        _ currentStateJSON: String,
        _ definitionJSON: String
    ) throws -> [ManualCorrection]
}

// MARK: - Bridging init: InstrumentKind → InstrumentCSVCoder

extension InstrumentCSVCoder {
    /// Lift a concrete `InstrumentKind` conformance into the closure-based
    /// coder. Decodes/encodes the kind's typed `State`, `Definition`, and
    /// `EventPayload` at the JSON-string boundary so the watcher stays
    /// type-erased while internals are fully typed.
    init<K: InstrumentKind>(kind: K.Type) {
        self.init(
            renderData: { stateJSON, definitionJSON, recentEventsJSON in
                let state = try Self.decode(K.State.self, from: stateJSON)
                let def = try Self.decode(K.Definition.self, from: definitionJSON)
                let events = try recentEventsJSON.map {
                    try Self.decode(InstrumentEvent<K.EventPayload>.self, from: $0)
                }
                return K.renderCSV(state: state, definition: def, recentEvents: events)
            },
            renderState: { stateJSON, _ in
                // Generic state-blob walk — independent of kind. We try to
                // decode the JSON as a top-level dictionary and emit one
                // `(field, value)` row per key. If the state isn't a top-level
                // object we fall back to a single-row "state" cell containing
                // the raw JSON.
                let header = ["field", "value"]
                guard let data = stateJSON.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) else {
                    return CSVTable(header: header, rows: [["state", stateJSON]])
                }
                guard let dict = parsed as? [String: Any] else {
                    return CSVTable(header: header, rows: [["state", stateJSON]])
                }
                let rows = dict.keys.sorted().map { key -> [String] in
                    let value = dict[key]
                    return [key, Self.renderJSONValue(value)]
                }
                return CSVTable(header: header, rows: rows)
            },
            parseOverride: { table, stateJSON, definitionJSON in
                let state = try Self.decode(K.State.self, from: stateJSON)
                let def = try Self.decode(K.Definition.self, from: definitionJSON)
                return try K.parseCSVOverride(table, current: state, definition: def)
            }
        )
    }

    // MARK: - Helpers

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw CSVTableError.fileReadFailed(
                URL(fileURLWithPath: "/dev/null"),
                underlying: NSError(domain: "Steward.InstrumentCSVCoder", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "non-UTF8 JSON"])
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    /// Render a top-level JSON value for state.csv. Strings unwrap; numbers
    /// stringify; arrays/objects re-serialize compactly.
    private static func renderJSONValue(_ any: Any?) -> String {
        guard let any else { return "" }
        if let s = any as? String { return s }
        if let n = any as? NSNumber {
            // NSNumber may bridge to Bool — distinguish since CFNumberGetType
            // would let `true`/`false` print as `1`/`0` and lose intent.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        }
        if any is NSNull { return "" }
        if let data = try? JSONSerialization.data(withJSONObject: any, options: []),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: any)
    }
}

// MARK: - Registry

/// Process-wide registry mapping `instruments.kind` strings to a coder.
/// `TrackFBootstrap.registerKindCoders()` calls `register` for each of Pod C's
/// 7 built-in kinds at app boot; the watcher looks them up by the row's
/// `kind` column.
actor InstrumentCSVCoderRegistry {
    static let shared = InstrumentCSVCoderRegistry()

    private var coders: [String: InstrumentCSVCoder] = [:]

    func register(kindID: String, coder: InstrumentCSVCoder) {
        coders[kindID] = coder
    }

    func coder(for kindID: String) -> InstrumentCSVCoder? {
        coders[kindID]
    }

    /// Test seam — wipes registrations between unit tests.
    func reset() {
        coders.removeAll()
    }
}
