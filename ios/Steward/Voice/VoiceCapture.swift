//
//  VoiceCapture.swift
//  Steward — Voice subsystem
//
//  Surface the Chat UI binds against. The concrete WhisperKit-backed
//  implementation lives in `VoiceCaptureService` (an actor); the
//  `VoiceCaptureAdapter` final class bridges that actor to this protocol
//  so the registry can hand a single nominal type to SwiftUI views.
//
//  Why a protocol at all (not just the service):
//   - The UI reads `availability` to render the mic in one of four states:
//     ready / not-loaded / permission-denied / disabled-in-settings. The
//     service's `VoiceCaptureReadiness` carries extra detail (initFailed,
//     modelMissing, frameworkMissing) that the UI collapses to "not-loaded"
//     with a tooltip per design/ui-specs.md §1.6.
//   - Tests can substitute a fake conformer (e.g., `MissingVoiceCapture`)
//     into `VoiceCaptureRegistry.current` without spinning the real audio
//     engine + WhisperKit model.
//

import Foundation

/// Why the mic button is unavailable. Each case maps to a piece of UI copy
/// from `design/ui-specs.md` §1.6.
public enum VoiceAvailability: Sendable, Equatable {
    case ready
    case notLoaded          // WhisperKit failed to load, or still initializing.
    case permissionDenied   // User declined microphone access.
    case disabledInSettings // `settings.voice_capture_enabled = false`.
}

/// Minimal voice-capture surface the UI binds against. The
/// `VoiceCaptureAdapter` wraps `VoiceCaptureService.shared`; tests can
/// substitute `MissingVoiceCapture` for a deterministic disabled mic.
public protocol VoiceCapture: AnyObject, Sendable {
    var availability: VoiceAvailability { get async }

    /// Begin recording on press-down. Errors are surfaced via the next
    /// `endRecordingAndTranscribe` (which will throw `.notRecording` if
    /// `beginRecording` failed) or by `availability` flipping away from
    /// `.ready`. The press-down handler is fire-and-forget by design.
    func beginRecording() async

    /// Stop and transcribe. Returns nil if no audio was captured (empty
    /// transcript). Throws on hard failure (mic in use, transcription error,
    /// no active recording).
    func endRecordingAndTranscribe() async throws -> String?

    /// User dragged off the button; throw away the buffer.
    func cancelRecording() async
}

/// Process-wide handle. Default is `MissingVoiceCapture`; `StewardApp`'s
/// Track F bootstrap swaps in `VoiceCaptureAdapter()` once
/// `VoiceCaptureService.shared.initializeIfNeeded()` returns. Reads from
/// main-thread UI code go through this `@MainActor` enum.
@MainActor
public enum VoiceCaptureRegistry {
    public static var current: any VoiceCapture = MissingVoiceCapture()
}

/// Reports `.notLoaded` and refuses to record. Used as the registry's
/// startup-time default before the WhisperKit-backed adapter is installed,
/// and as a test stand-in for the disabled-mic state.
public final class MissingVoiceCapture: VoiceCapture {
    public init() {}
    public var availability: VoiceAvailability { get async { .notLoaded } }
    public func beginRecording() async {}
    public func endRecordingAndTranscribe() async throws -> String? { nil }
    public func cancelRecording() async {}
}

/// Posted when `VoiceCaptureRegistry.current` is reassigned (after
/// WhisperKit eager init completes) or when the service's readiness
/// changes in a way the UI should reflect. ChatView observes this to
/// flip the mic button from disabled-with-tooltip to active.
public extension Notification.Name {
    static let voiceCaptureReadinessChanged = Notification.Name(
        "Steward.voiceCaptureReadinessChanged"
    )
}
