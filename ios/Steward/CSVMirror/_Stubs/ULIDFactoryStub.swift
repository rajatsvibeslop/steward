//
//  ULIDFactoryStub.swift
//  Steward — Track F
//
//  REMOVE AT MERGE — canonical owner TBD (likely Pod A or a shared util module)
//  -------------------------------------------------------------------------
//  This is a tiny hex-of-timestamp+random ID generator that the CSV mirror
//  uses for new `__row_id` values and `event_id` / `queue_id` strings. Not
//  cryptographic, not strict ULID format, but unique-enough for single-user
//  v0.9. When the canonical generator lands (Pod A's shared util or
//  swift-clocks-based variant), delete this file and update imports.
//
//  Keeping it under `_Stubs/` makes the merge-time deletion mechanical.
//

import Foundation

enum ULIDFactory {
    static func make(now: Date = Date()) -> String {
        let ms = UInt64(now.timeIntervalSince1970 * 1000)
        let randHi = UInt32.random(in: .min ... .max)
        let randLo = UInt32.random(in: .min ... .max)
        return String(format: "%012llX%08X%08X", ms, randHi, randLo)
    }
}
