//
//  VoiceCaptureAdapter.swift
//  Steward — Voice subsystem
//
//  Bridges the `VoiceCaptureService` actor (WhisperKit-backed hold-to-talk)
//  to the `VoiceCapture` protocol that the Chat UI binds against. The
//  protocol's method names + return types intentionally differ from the
//  service's (e.g. `beginRecording` vs `startRecording`, optional vs
//  required transcript) so the UI surface stays simple; this adapter does
//  the translation in one place.
//
//  Lifecycle: `StewardApp` installs an instance into
//  `VoiceCaptureRegistry.current` after `VoiceCaptureService.shared
//  .initializeIfNeeded()` returns. Before that, the registry's default
//  `MissingVoiceCapture` reports `.notLoaded` and the mic shows disabled.
//

import Foundation

public final class VoiceCaptureAdapter: VoiceCapture {
    public init() {}

    public var availability: VoiceAvailability {
        get async {
            let readiness = await VoiceCaptureService.shared.readiness
            return Self.availability(for: readiness)
        }
    }

    public func beginRecording() async {
        // Press-down is fire-and-forget per the protocol contract. A failure
        // here (e.g. mic permission flipped, engine refused to start) leaves
        // `isRecording == false` in the service, so the subsequent
        // `endRecordingAndTranscribe` call will throw `.notRecording` and
        // the UI will surface that via its catch arm. No silent loss.
        do {
            try await VoiceCaptureService.shared.startRecording()
        } catch {
            // Intentional: errors propagate through the next call. The press-up
            // handler in ChatView catches them and falls back to the tooltip on
            // the next mic tap, matching design/ui-specs.md §1.6.
            _ = error
        }
    }

    public func endRecordingAndTranscribe() async throws -> String? {
        let text = try await VoiceCaptureService.shared.stopAndTranscribe()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func cancelRecording() async {
        await VoiceCaptureService.shared.cancelRecording()
    }

    // MARK: - Readiness mapping (pure, testable)

    /// Project the service's detailed readiness onto the four-state surface
    /// the UI renders. `frameworkMissing` / `modelMissing` / `initFailed`
    /// all collapse to `.notLoaded` because the tooltip copy is the same
    /// (per design/ui-specs.md §1.6); the underlying detail is captured in
    /// the service's logs and the readiness enum for diagnostics.
    static func availability(for readiness: VoiceCaptureReadiness) -> VoiceAvailability {
        switch readiness {
        case .ready:
            return .ready
        case .notInitialized, .initializing:
            return .notLoaded
        case .unavailable(.settings):
            return .disabledInSettings
        case .unavailable(.permission):
            return .permissionDenied
        case .unavailable(.frameworkMissing),
             .unavailable(.modelMissing),
             .unavailable(.initFailed):
            return .notLoaded
        }
    }
}
