//
//  WhisperKitModelLocator.swift
//  Steward
//
//  Hard reject #15: WhisperKit models MUST be bundled — lazy-download on first
//  use is forbidden (the user expects voice capture to work on the subway).
//  This locator's contract is:
//
//   1. Look for the model bundle directory under the app's `Resources/`.
//   2. If present, return the absolute URL.
//   3. If absent, throw `WhisperKitModelLocatorError.modelNotBundled` with a
//      diagnostic that includes the expected path so the install script (see
//      `scripts/fetch-whisperkit-model.sh`) can be re-run.
//
//  There is no network code in this file. Grep for `URLSession` / `Data(contentsOf:`
//  in the Voice/ directory and you should find none — that's the hard-reject
//  invariant.
//

import Foundation

enum WhisperKitModelLocatorError: Error, CustomStringConvertible {
    case modelNotBundled(expectedPath: String)
    case bundleResourceURLUnavailable

    var description: String {
        switch self {
        case .modelNotBundled(let path):
            return """
            WhisperKit model not bundled at \(path).
            Run `scripts/fetch-whisperkit-model.sh` before building to populate the bundle.
            Lazy download is forbidden (addendum §4 hard reject #15).
            """
        case .bundleResourceURLUnavailable:
            return "Bundle.main.resourceURL is nil — cannot resolve bundled model path"
        }
    }
}

/// Resolves the on-disk path of the bundled WhisperKit model. Stateless;
/// every call re-checks disk so an integration build that copies the model
/// post-launch (rare; only matters in test scaffolding) still resolves.
struct WhisperKitModelLocator: Sendable {
    /// Default model name. v1 uses whisper-large-v3-turbo for the speed/quality
    /// trade Apple Silicon devices handle comfortably (per addendum §3
    /// WhisperKit landmine — bundle the 1.6GB model).
    static let defaultModelName = "openai_whisper-large-v3-turbo"

    /// Subfolder inside the app bundle's `Resources` that holds the model.
    /// `scripts/fetch-whisperkit-model.sh` writes here.
    static let bundleSubfolder = "WhisperKitModels"

    let modelName: String
    let bundle: Bundle

    init(modelName: String = WhisperKitModelLocator.defaultModelName, bundle: Bundle = .main) {
        self.modelName = modelName
        self.bundle = bundle
    }

    /// Returns the URL of the model directory inside the bundle's resources.
    /// Throws if missing.
    func resolveModelFolderURL(fileManager: FileManager = .default) throws -> URL {
        guard let resourceURL = bundle.resourceURL else {
            throw WhisperKitModelLocatorError.bundleResourceURLUnavailable
        }
        let folder = resourceURL
            .appendingPathComponent(Self.bundleSubfolder, isDirectory: true)
            .appendingPathComponent(modelName, isDirectory: true)
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: folder.path, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            throw WhisperKitModelLocatorError.modelNotBundled(expectedPath: folder.path)
        }
        return folder
    }
}
