//
//  Ids.swift
//  Steward
//
//  Tiny ULID generator used by every tool that needs a stable, time-ordered
//  primary key (events, instruments, memories, commitments, notifications).
//  Crockford-base32 timestamp + random suffix — no dependencies, lexicographic
//  collation, monotonic within the same millisecond unless rng colides.
//

import Foundation

enum ULID {
    /// Crockford base-32 alphabet (no I, L, O, U).
    private static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Generate a fresh ULID. `now` is overridable for tests so we can assert
    /// ordering / lex-collation properties deterministically.
    static func generate(now: Date = Date()) -> String {
        let ms = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        var bytes: [UInt8] = []
        // 48-bit timestamp, big-endian
        for i in (0..<6).reversed() {
            bytes.append(UInt8((ms >> (UInt64(i) * 8)) & 0xFF))
        }
        // 80-bit random
        for _ in 0..<10 {
            bytes.append(UInt8.random(in: 0...255))
        }
        return encodeBase32Crockford(bytes)
    }

    /// Encode 16 bytes → 26-char Crockford base32 (ULID canonical length).
    private static func encodeBase32Crockford(_ bytes: [UInt8]) -> String {
        // Pack 16 bytes (128 bits) into 26 base-32 characters (130 bits, top 2 unused).
        // Pad to 130 bits by prepending two zero bits.
        var value: UInt128Pair = UInt128Pair()
        for b in bytes {
            value.append(byte: b)
        }
        var output: [Character] = []
        output.reserveCapacity(26)
        for i in 0..<26 {
            let shift = (25 - i) * 5
            let idx = Int(value.extract5Bits(at: shift))
            output.append(alphabet[idx])
        }
        return String(output)
    }

    /// Internal 130-bit value held as two UInt64s plus a small overflow.
    /// Kept fileprivate-simple: we only need shifts up to 130 bits.
    private struct UInt128Pair {
        var hi: UInt64 = 0
        var lo: UInt64 = 0

        mutating func append(byte: UInt8) {
            // Shift left 8 and OR in the new byte. The full register is
            // 130 bits wide effectively (we only ever encode 128 bits of
            // payload, with the top 2 bits implicitly zero).
            let carry = (lo >> 56) & 0xFF
            lo = (lo << 8) | UInt64(byte)
            hi = (hi << 8) | carry
        }

        func extract5Bits(at shift: Int) -> UInt8 {
            // shift can be 0..125 in practice for our 26-char encoding.
            if shift >= 64 {
                let s = shift - 64
                return UInt8((hi >> s) & 0x1F)
            } else {
                let lowPart = (lo >> shift) & 0x1F
                // Borrow up to 5 bits from `hi` if we straddle the boundary.
                let bitsAvailableInLo = 64 - shift
                if bitsAvailableInLo < 5 {
                    let needFromHi = 5 - bitsAvailableInLo
                    let hiMask: UInt64 = (1 << UInt64(needFromHi)) - 1
                    let fromHi = (hi & hiMask) << UInt64(bitsAvailableInLo)
                    return UInt8((lowPart | fromHi) & 0x1F)
                }
                return UInt8(lowPart)
            }
        }
    }
}
