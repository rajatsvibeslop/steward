//
//  Embedding.swift
//  Steward
//
//  NLEmbedding wrapper. Returns `[Float]` L2-normalized vectors so that
//  cosine similarity = vDSP.dotProduct of two normalized vectors (researcher
//  landmine: NLEmbedding ships `[Double]`; cast immediately, normalize, store
//  as Float32 BLOB).
//

import Foundation
import NaturalLanguage
import Accelerate

/// Errors surfaced by embedding work. Typed — no `fatalError` in prod paths.
enum EmbeddingError: Error, CustomStringConvertible, Equatable {
    case embedderUnavailable(language: String)
    case emptyText
    case dimensionMismatch(expected: Int, got: Int)

    var description: String {
        switch self {
        case .embedderUnavailable(let l):
            return "NLEmbedding unavailable for language '\(l)'"
        case .emptyText:
            return "embedding text is empty after trimming"
        case .dimensionMismatch(let e, let g):
            return "embedding dimension mismatch: expected \(e), got \(g)"
        }
    }
}

/// Stable identifier for the on-device embedding model. Persisted to
/// `memory_items.embedding_revision`; mismatch on launch triggers re-index
/// (addendum §2.3).
struct EmbeddingRevision: Equatable, Codable, Sendable {
    let language: String
    let revision: Int
    let appBuild: String

    var stringValue: String {
        "NLEmbedding.\(language).rev\(revision).build\(appBuild)"
    }

    enum CodingKeys: String, CodingKey {
        case language
        case revision
        case appBuild = "app_build"
    }
}

/// Process-wide embedding gateway. Lazy-initializes the NLEmbedding on first
/// use; if Apple's model isn't available we surface `embedderUnavailable`
/// rather than crashing.
actor Embedder {
    static let shared = Embedder()

    private var embedding: NLEmbedding?
    private let language: NLLanguage
    private let appBuild: String

    init(language: NLLanguage = .english,
         appBuild: String? = nil) {
        self.language = language
        if let b = appBuild {
            self.appBuild = b
        } else {
            self.appBuild = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "dev"
        }
    }

    /// Lazy: load NLEmbedding on first use. NLEmbedding can return nil if
    /// the on-device model isn't installed yet.
    private func ensureEmbedding() throws -> NLEmbedding {
        if let e = embedding { return e }
        guard let e = NLEmbedding.wordEmbedding(for: language) else {
            throw EmbeddingError.embedderUnavailable(language: language.rawValue)
        }
        embedding = e
        return e
    }

    /// Current embedding revision string. Persisted to every new memory row.
    func currentRevision() throws -> EmbeddingRevision {
        let e = try ensureEmbedding()
        // NLEmbedding.language is Optional<NLLanguage> — fall back to the
        // requested language if Apple hasn't reported one for this model.
        let langRaw = e.language?.rawValue ?? language.rawValue
        return EmbeddingRevision(
            language: langRaw,
            revision: e.revision,
            appBuild: appBuild
        )
    }

    /// Dimension of vectors this revision produces. Useful for the BLOB size
    /// sanity check and FTS callers.
    func dimension() throws -> Int {
        let e = try ensureEmbedding()
        return e.dimension
    }

    /// Embed `text` as an L2-normalized `[Float]`. Sentence-level embeddings
    /// are computed by averaging word vectors (NLEmbedding doesn't directly
    /// expose a sentence embedder for v1; the document distance is OK for
    /// short memory items). Empty / all-stopword text throws
    /// `EmbeddingError.emptyText`.
    func embed(_ text: String) throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw EmbeddingError.emptyText }
        let e = try ensureEmbedding()
        let dim = e.dimension

        var sum = [Float](repeating: 0, count: dim)
        var count: Float = 0
        let tokens = trimmed
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })

        for token in tokens {
            let word = String(token)
            guard let v = e.vector(for: word) else { continue }
            // NLEmbedding returns [Double]; cast immediately.
            let f = v.map { Float($0) }
            if f.count != dim {
                throw EmbeddingError.dimensionMismatch(expected: dim, got: f.count)
            }
            // sum += f
            f.withUnsafeBufferPointer { fbp in
                sum.withUnsafeMutableBufferPointer { sbp in
                    vDSP.add(sbp, fbp, result: &sbp)
                }
            }
            count += 1
        }

        if count == 0 {
            // No in-vocabulary tokens. Surface as emptyText so the caller
            // can decline to save the memory rather than store a zero vector
            // that would dot-product to 0 with everything.
            throw EmbeddingError.emptyText
        }

        // Average → mean vector.
        var mean = sum
        let divisor = count
        vDSP.divide(mean, divisor, result: &mean)

        // L2 normalize: ‖v‖ = sqrt(sum(v_i²))
        let normSquared = vDSP.sum(vDSP.multiply(mean, mean))
        let norm = Float(sqrt(Double(normSquared)))
        if norm > 0 {
            mean = vDSP.divide(mean, norm)
        }
        return mean
    }

    /// Cosine similarity for two ALREADY-NORMALIZED Float vectors. Uses
    /// Accelerate `vDSP.dotProduct` per researcher landmine (Swift for-loops
    /// were called out as a hot-path foot-gun in NLEmbedding land).
    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        if n == 0 { return 0 }
        let slicedA = Array(a.prefix(n))
        let slicedB = Array(b.prefix(n))
        return vDSP.dot(slicedA, slicedB)
    }

    /// Encode a `[Float]` as a `Float32` little-endian BLOB suitable for SQLite.
    /// Reverse: `decodeBlob`.
    nonisolated static func encodeBlob(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Decode a Float32 BLOB back to `[Float]`. Returns nil if byte count
    /// isn't a multiple of 4 (corrupt row — caller logs + skips).
    nonisolated static func decodeBlob(_ data: Data) -> [Float]? {
        guard data.count % MemoryLayout<Float>.size == 0 else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw -> [Float] in
            let buf = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: buf.baseAddress, count: count))
        }
    }
}
