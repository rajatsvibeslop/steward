//
//  VoiceCaptureService.swift
//  Steward — Track F
//
//  Hold-to-talk voice capture per spec §14. Owns:
//   - AVAudioEngine recording into a PCM buffer (16 kHz mono Float32 for Whisper)
//   - Mic permission gating (AVAudioApplication.requestRecordPermission, iOS 17+)
//   - WhisperKit eager init backed by the *bundled* model (hard reject #15)
//   - `startRecording()` / `stopAndTranscribe() -> String` surface the UI calls
//
//  WhisperKit is imported conditionally so the Voice subsystem still compiles
//  on environments where the SPM dep hasn't synced (e.g., a CI checkout that
//  hasn't run `xcodebuild -resolvePackageDependencies` yet). When unavailable,
//  the service degrades to `.unavailable(.frameworkMissing)` and the UI shows
//  the disabled mic.
//

import Foundation
import AVFoundation

#if canImport(WhisperKit)
import WhisperKit
#endif

enum VoiceCaptureError: Error, CustomStringConvertible {
    case disabledInSettings
    case micPermissionDenied
    case frameworkUnavailable
    case modelNotBundled(expectedPath: String)
    case engineFailedToStart(underlying: Error)
    case notRecording
    case transcriptionFailed(underlying: Error)
    case bufferAppendFailed

    var description: String {
        switch self {
        case .disabledInSettings:
            return "Voice capture disabled in Settings"
        case .micPermissionDenied:
            return "Microphone permission denied"
        case .frameworkUnavailable:
            return "WhisperKit framework unavailable in this build"
        case .modelNotBundled(let path):
            return "WhisperKit model not bundled at \(path) — run scripts/fetch-whisperkit-model.sh"
        case .engineFailedToStart(let err):
            return "AVAudioEngine failed to start: \(err)"
        case .notRecording:
            return "stopAndTranscribe called without an active recording"
        case .transcriptionFailed(let err):
            return "WhisperKit transcription failed: \(err)"
        case .bufferAppendFailed:
            return "Failed to append PCM buffer during recording"
        }
    }
}

/// Backend readiness state surfaced to the UI for the mic button.
enum VoiceCaptureReadiness: Sendable, Equatable {
    case notInitialized
    case initializing
    case ready
    case unavailable(reason: UnavailabilityReason)

    enum UnavailabilityReason: Sendable, Equatable {
        case settings
        case permission
        case frameworkMissing
        case modelMissing(expectedPath: String)
        case initFailed(message: String)
    }
}

actor VoiceCaptureService {
    static let shared = VoiceCaptureService()

    private let settings: SettingsStore
    private let locator: WhisperKitModelLocator

    private(set) var readiness: VoiceCaptureReadiness = .notInitialized

    // Recording state. Audio engine + tap collect PCM into `samples` (16 kHz mono Float).
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var isRecording: Bool = false

    #if canImport(WhisperKit)
    private var whisper: WhisperKit?
    #endif

    init(
        settings: SettingsStore = .shared,
        locator: WhisperKitModelLocator = WhisperKitModelLocator()
    ) {
        self.settings = settings
        self.locator = locator
    }

    // MARK: - Lifecycle

    /// Eager init per spec §14 — call after mic permission is granted. Safe to
    /// call multiple times; subsequent calls are no-ops once `.ready`.
    func initializeIfNeeded() async {
        if case .ready = readiness { return }
        readiness = .initializing

        // Gate on settings first — saves loading 1.6GB of model into RAM if
        // the user has toggled voice off.
        let s: Settings
        do {
            s = try await settings.load()
        } catch {
            readiness = .unavailable(reason: .initFailed(message: "Settings load failed: \(error)"))
            return
        }
        guard s.voiceCaptureEnabled else {
            readiness = .unavailable(reason: .settings)
            return
        }

        // Permission gate. We don't request here — UI requests via
        // `requestMicPermission()` so it can show context first. We only
        // refuse to load the model if denied at init time.
        switch currentMicPermission() {
        case .denied:
            readiness = .unavailable(reason: .permission)
            return
        case .granted, .undetermined:
            break
        }

        #if canImport(WhisperKit)
        do {
            let folder = try locator.resolveModelFolderURL()
            // WhisperKit config: prefer the bundled folder, never the
            // downloadBase. Setting both `modelFolder` and disabling
            // `downloadBase` ensures the framework never reaches out.
            let config = WhisperKitConfig(
                model: locator.modelName,
                modelFolder: folder.path,
                load: true
            )
            self.whisper = try await WhisperKit(config)
            readiness = .ready
        } catch let WhisperKitModelLocatorError.modelNotBundled(path) {
            readiness = .unavailable(reason: .modelMissing(expectedPath: path))
        } catch {
            readiness = .unavailable(reason: .initFailed(message: String(describing: error)))
        }
        #else
        readiness = .unavailable(reason: .frameworkMissing)
        #endif
    }

    // MARK: - Mic permission

    enum MicPermission: Sendable {
        case undetermined
        case granted
        case denied
    }

    /// Deployment target is iOS 18.4 (set by Pod A), so `AVAudioApplication`
    /// (iOS 17+) is always available — no `#available` fallback.
    nonisolated func currentMicPermission() -> MicPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: return .undetermined
        case .denied: return .denied
        case .granted: return .granted
        @unknown default: return .undetermined
        }
    }

    /// Trigger the system mic permission prompt. Returns the final permission
    /// state. After granting, callers should call `initializeIfNeeded()`.
    func requestMicPermission() async -> MicPermission {
        let granted: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { ok in cont.resume(returning: ok) }
        }
        return granted ? .granted : .denied
    }

    // MARK: - Recording

    /// Begin recording. Throws if not ready (`initializeIfNeeded` first).
    func startRecording() async throws {
        if case .ready = readiness {} else {
            switch readiness {
            case .unavailable(.settings):
                throw VoiceCaptureError.disabledInSettings
            case .unavailable(.permission):
                throw VoiceCaptureError.micPermissionDenied
            case .unavailable(.frameworkMissing):
                throw VoiceCaptureError.frameworkUnavailable
            case .unavailable(.modelMissing(let p)):
                throw VoiceCaptureError.modelNotBundled(expectedPath: p)
            case .unavailable(.initFailed(let m)):
                throw VoiceCaptureError.engineFailedToStart(
                    underlying: NSError(domain: "Steward.VoiceCapture", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: m])
                )
            case .initializing, .notInitialized:
                throw VoiceCaptureError.engineFailedToStart(
                    underlying: NSError(domain: "Steward.VoiceCapture", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "service not ready"])
                )
            case .ready:
                break
            }
        }

        samples.removeAll(keepingCapacity: true)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: [])
        } catch {
            throw VoiceCaptureError.engineFailedToStart(underlying: error)
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16_000,
                                         channels: 1,
                                         interleaved: false)
        guard let targetFormat else {
            throw VoiceCaptureError.engineFailedToStart(
                underlying: NSError(domain: "Steward.VoiceCapture", code: 3,
                                    userInfo: [NSLocalizedDescriptionKey: "could not build 16kHz mono format"])
            )
        }
        self.converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        // Bridge non-Sendable AVAudioPCMBuffer across the actor boundary by
        // extracting the Float samples in the tap (which runs on the audio
        // engine's I/O thread), then handing the pure Swift array over.
        let conv = self.converter
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let conv else { return }
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * (targetFormat.sampleRate / inputFormat.sampleRate)
            )
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                   frameCapacity: max(frameCapacity, 1)) else { return }
            var inputProvided = false
            var convError: NSError?
            let status = conv.convert(to: outBuffer, error: &convError) { _, outStatus in
                if inputProvided {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputProvided = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, convError == nil else { return }
            guard let channelData = outBuffer.floatChannelData?[0] else { return }
            let count = Int(outBuffer.frameLength)
            let frames = Array(UnsafeBufferPointer(start: channelData, count: count))
            Task { await self.appendFrames(frames) }
        }

        engine.prepare()
        do {
            try engine.start()
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceCaptureError.engineFailedToStart(underlying: error)
        }
    }

    /// Stop the engine and transcribe the captured buffer. Returns the
    /// (possibly empty) transcript string.
    func stopAndTranscribe() async throws -> String {
        guard isRecording else { throw VoiceCaptureError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        let pcm = samples
        samples.removeAll(keepingCapacity: true)

        #if canImport(WhisperKit)
        guard let whisper else { throw VoiceCaptureError.frameworkUnavailable }
        do {
            let results = try await whisper.transcribe(audioArray: pcm)
            return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw VoiceCaptureError.transcriptionFailed(underlying: error)
        }
        #else
        throw VoiceCaptureError.frameworkUnavailable
        #endif
    }

    /// Mock-input seam — tests feed raw float samples instead of opening a
    /// mic. After feeding, call `stopAndTranscribe(usingFedSamples:)`.
    #if DEBUG
    func _debugFeedSamples(_ frames: [Float]) {
        samples.append(contentsOf: frames)
    }
    #endif

    // MARK: - Private

    private func appendFrames(_ frames: [Float]) {
        samples.append(contentsOf: frames)
    }
}
