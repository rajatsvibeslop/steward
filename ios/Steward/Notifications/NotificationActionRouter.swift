//
//  NotificationActionRouter.swift
//  Steward
//
//  Closes nemesis caveat D (spec §10 #4 "tap-to-act"). Without a registered
//  UNUserNotificationCenterDelegate every tap on a wind-down nudge / morning
//  brief / commitment reminder cold-launches the app to the chat root —
//  identical to opening Steward from Springboard. The notification's
//  payload (the `action_context` we stamp on schedule) is dropped on the
//  floor.
//
//  This router:
//   1. Conforms to `UNUserNotificationCenterDelegate` so iOS routes both
//      foreground presentations (`willPresent`) and user taps
//      (`didReceive`) through it.
//   2. Decodes the typed `NotificationActionContext` we stamped into
//      `userInfo[NotificationActionContext.userInfoKey]` at schedule time.
//   3. Posts a typed `TapEvent` via `NotificationCenter.default` AND
//      buffers the last event so a cold-launch ChatView can read it on
//      first appear (SwiftUI `.onReceive` would miss a post that lands
//      before the view subscribes).
//   4. On malformed / missing context: surfaces `.malformed(reason:)`
//      rather than swallowing the tap. Hard-reject "silent fallback that
//      opens to chat root without ANY indication that a notification
//      context was lost" — the UI converts this into a systemNote.
//

import Foundation
import UserNotifications

// MARK: - NotificationActionContext

/// Typed payload that round-trips through UNNotification.userInfo so the
/// tap handler can route the user to a tailored agent-turn context. The
/// JSON encoding lives behind the `userInfoKey` namespace so it cannot
/// collide with the agent's opaque `actionContextJSON` (which the
/// LLM-side schedule tool can populate freely).
struct NotificationActionContext: Codable, Equatable, Sendable {
    let kind: NotificationKind
    let domain: String?
    let instrumentID: InstrumentID?
    let commitmentID: CommitmentID?
    /// What Steward should say (as the coordinator) when the tap lands.
    /// Always non-nil after `from(request:)` — defaulted from the kind.
    let suggestedPrompt: String?

    init(
        kind: NotificationKind,
        domain: String? = nil,
        instrumentID: InstrumentID? = nil,
        commitmentID: CommitmentID? = nil,
        suggestedPrompt: String? = nil
    ) {
        self.kind = kind
        self.domain = domain
        self.instrumentID = instrumentID
        self.commitmentID = commitmentID
        self.suggestedPrompt = suggestedPrompt
    }

    /// Key under which the encoded JSON lives in `userInfo`. Distinct
    /// from the existing `steward_notification_kind` / `_id` keys and
    /// the agent's freeform actionContextJSON dict so we cannot collide.
    static let userInfoKey = "steward_action_context"

    /// Build the typed context from the request we're about to schedule.
    /// Pulls instrument/commitment names from the templateContext when
    /// present so the suggested prompt is specific (e.g. "Want to log
    /// sleep?" rather than "Want to log a quick check-in?").
    static func from(request: NotificationRequest) -> NotificationActionContext {
        let instrumentTyped: InstrumentID? = request.instrumentID.map { InstrumentID(rawValue: $0) }
        return NotificationActionContext(
            kind: request.kind,
            domain: request.domain,
            instrumentID: instrumentTyped,
            commitmentID: nil,
            suggestedPrompt: defaultSuggestedPrompt(for: request)
        )
    }

    /// Encode as JSON. Returns nil only if Foundation's encoder fails on
    /// our own struct, which is a programmer error — callers treat nil
    /// as "skip stamping" so a corrupted encode never blocks scheduling.
    func encodedJSONString() -> String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// Mirror of the NotificationTemplate registry, but for the *tap
    /// response* rather than the banner copy. Kept here (not on the
    /// template) because templates own user-visible body strings while
    /// these prompts are the coordinator's opening line on tap.
    static func defaultSuggestedPrompt(for request: NotificationRequest) -> String {
        let instrument = request.templateContext.instrumentName
        let domain = request.templateContext.domainDisplayName
        let commitment = request.templateContext.commitmentTitle
        switch request.kind {
        case .morningBrief:
            return "Want to walk through what's queued for today?"
        case .windDown:
            return "Want me to log your wind-down? Sleep window starts soon."
        case .instrumentNudge:
            if let instrument {
                return "Want to log \(instrument)?"
            }
            return "Want to log a quick check-in?"
        case .commitmentDue:
            if let commitment {
                return "Coming up: \(commitment). Want to mark progress?"
            }
            return "Want to mark progress on your commitment?"
        case .recoveryNudge:
            if let domain {
                return "Want to take a small step in \(domain)?"
            }
            return "Want to take a small step?"
        case .onboardingFollowup:
            return "Anything to log from today?"
        }
    }
}

// MARK: - Notification.Name

extension Notification.Name {
    /// Posted by `NotificationActionRouter` when iOS delivers a tap.
    /// `userInfo[NotificationActionRouter.tapEventUserInfoKey]` carries
    /// a `NotificationActionRouter.TapEvent`. Subscribers are
    /// `RootTabView` (to switch tabs) and `ChatView` (to inject the
    /// coordinator-initiated turn).
    static let stewardNotificationTapped = Notification.Name(
        "Steward.notificationTapped"
    )
}

// MARK: - Router

/// Singleton — installed as `UNUserNotificationCenter.current().delegate`
/// from `StewardApp.init`. Not an actor: UN delegate methods are not
/// async-safe to await on, and we need a stable Objective-C-visible
/// class identity. Internal state is guarded by an `NSLock` so off-main
/// delivery from iOS is safe; the SwiftUI publisher post is hopped to
/// the main thread before fanning out.
final class NotificationActionRouter:
    NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable
{
    static let shared = NotificationActionRouter()

    enum TapEvent: Equatable, Sendable {
        /// Decoded successfully; UI should route to the suggested prompt.
        case routed(NotificationActionContext)
        /// Either `userInfo` had no typed context key or the JSON
        /// failed to decode. UI must surface this — the user tapped
        /// a notification for a reason and getting nothing back would
        /// look broken.
        case malformed(reason: String)
    }

    static let tapEventUserInfoKey = "steward.notification.tap.event"

    private let lock = NSLock()
    private var _lastTapEvent: TapEvent?

    /// Last delivered tap event. ChatView reads-and-clears this on
    /// first appear so a cold-launch tap (where the SwiftUI tree
    /// hadn't subscribed when the post fired) still routes correctly.
    var lastTapEvent: TapEvent? {
        lock.lock(); defer { lock.unlock() }
        return _lastTapEvent
    }

    /// Atomically read + clear the buffered event. Returns the value
    /// that was present before the clear; nil if nothing was buffered.
    @discardableResult
    func takeLastTapEvent() -> TapEvent? {
        lock.lock(); defer { lock.unlock() }
        let event = _lastTapEvent
        _lastTapEvent = nil
        return event
    }

    /// `internal` (not private) so tests can construct a fresh router
    /// independent of the process-wide singleton — important because
    /// the host app mounts `ChatView`, which subscribes to
    /// `.stewardNotificationTapped` and clears `shared`'s buffer.
    /// Production code MUST go through `NotificationActionRouter.shared`
    /// (it's what UNUserNotificationCenter holds as `delegate`).
    override init() { super.init() }

    // MARK: - UNUserNotificationCenterDelegate

    /// iOS delivers a tap (or other action) on a notification. We pull
    /// the userInfo, decode, post, and complete immediately — iOS
    /// requires the completion handler within ~30s or the app is
    /// killed, so we do not await anything inside this method.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        handleTap(userInfo: userInfo)
        completionHandler()
    }

    /// Foreground presentation: show banners / sounds / list-entry
    /// even when the app is in the foreground. Without this iOS
    /// suppresses notifications while the user is in-app, which makes
    /// foreground wind-down nudges invisible.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    // MARK: - Testable seam

    /// Decode + post + buffer. Public so unit tests can exercise the
    /// routing path without standing up a real UNNotificationResponse
    /// (which has no public initializer).
    func handleTap(userInfo: [AnyHashable: Any]) {
        let event = Self.decodeContext(from: userInfo)
        lock.lock()
        _lastTapEvent = event
        lock.unlock()
        let post: @Sendable () -> Void = {
            NotificationCenter.default.post(
                name: .stewardNotificationTapped,
                object: nil,
                userInfo: [Self.tapEventUserInfoKey: event]
            )
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async { post() }
        }
    }

    /// Pure decoder. Tests cover both arms.
    static func decodeContext(
        from userInfo: [AnyHashable: Any]
    ) -> TapEvent {
        guard let raw = userInfo[NotificationActionContext.userInfoKey] as? String else {
            return .malformed(reason: "missing_action_context")
        }
        guard let data = raw.data(using: .utf8) else {
            return .malformed(reason: "not_utf8")
        }
        do {
            let ctx = try JSONDecoder().decode(
                NotificationActionContext.self, from: data
            )
            return .routed(ctx)
        } catch {
            return .malformed(reason: "decode_failed")
        }
    }

    // MARK: - DEBUG hooks

    #if DEBUG
    /// Reset the buffered event between tests on the shared singleton.
    /// New tests should prefer constructing a fresh
    /// `NotificationActionRouter()` instance instead — the host app's
    /// ChatView subscribes to `.stewardNotificationTapped` on the
    /// singleton and races any buffer-state assertion.
    func _resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        _lastTapEvent = nil
    }
    #endif
}
