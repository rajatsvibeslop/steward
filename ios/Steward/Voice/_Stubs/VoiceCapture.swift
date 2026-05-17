//
//  VoiceCapture.swift
//  Steward — Track E
//
//  DELETE-AT-MERGE: surface placeholder. Pod F owns the canonical
//  WhisperKit-backed implementation per spec §14 + addendum §3 (WhisperKit
//  bullets). When Pod F's branch merges, replace the body of this file with
//  a one-line conformance: `extension VoiceCaptureService: VoiceCapture {}`
//  pointing at Pod F's actor. The UI binds against the `VoiceCapture`
//  protocol so Pod F can land without touching any Chat code.
//
//  Why a protocol here at all:
//   - The Chat input bar needs a stable symbol for compile-time. Without
//     this stub, Chat code references a Pod-F type that doesn't exist yet
//     in this worktree.
//   - The UI reads `availability` to render the mic in one of three states:
//     ready / disabled-with-tooltip / disabled-by-settings. The default
//     `MissingVoiceCapture` reports `.notLoaded` so the tooltip is
//     "Voice isn't ready right now. You can still type." per Designer §1.6.
//

import Foundation

/// Why the mic button is unavailable. Each case maps to a piece of UI copy
/// from `design/ui-specs.md` §1.6.
public enum VoiceAvailability: Sendable, Equatable {
    case ready
    case notLoaded          // Pod F not wired yet, or WhisperKit failed to load.
    case permissionDenied   // User declined microphone access.
    case disabledInSettings // `settings.voice_capture_enabled = false`.
}

/// Minimal voice-capture surface the UI binds against. Pod F's
/// `VoiceCaptureService` actor adds the real hold-to-talk implementation
/// later; the UI does not depend on its details, only on `availability` and
/// a single press-down / press-up / cancel sequence.
public protocol VoiceCapture: AnyObject, Sendable {
    var availability: VoiceAvailability { get async }

    /// Begin recording on press-down. Idempotent if called twice without an
    /// intervening stop — Pod F decides; UI just forwards the press-down.
    func beginRecording() async

    /// Stop and transcribe. Returns nil if cancelled or if no audio was
    /// captured. Throws on hard failure (mic in use, transcription error).
    func endRecordingAndTranscribe() async throws -> String?

    /// User dragged off the button; throw away the buffer.
    func cancelRecording() async
}

/// Process-wide handle. Default is `MissingVoiceCapture`; Pod F swaps in
/// its real implementation during bootstrap. Reads from main-thread UI code
/// go through `VoiceCaptureRegistry.current` which is `@MainActor`.
@MainActor
public enum VoiceCaptureRegistry {
    public static var current: any VoiceCapture = MissingVoiceCapture()
}

/// Reports `.notLoaded` and refuses to record. The UI renders the disabled
/// state + tooltip "Voice isn't ready right now. You can still type."
public final class MissingVoiceCapture: VoiceCapture {
    public init() {}
    public var availability: VoiceAvailability { get async { .notLoaded } }
    public func beginRecording() async {}
    public func endRecordingAndTranscribe() async throws -> String? { nil }
    public func cancelRecording() async {}
}
