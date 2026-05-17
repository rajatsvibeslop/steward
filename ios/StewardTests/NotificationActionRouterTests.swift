//
//  NotificationActionRouterTests.swift
//  StewardTests
//
//  Covers nemesis caveat D end-to-end:
//   1. NotificationScheduler stamps the typed action context into userInfo
//      under the canonical key (round-trip survives serialization).
//   2. NotificationActionRouter.decodeContext recovers the typed struct
//      from a real-looking userInfo payload.
//   3. Malformed / missing payloads return .malformed(reason:) — never
//      silently route to chat root with no signal.
//   4. handleTap fires the .stewardNotificationTapped post AND buffers
//      the last event so a cold-launch ChatView can read it on first
//      appear.
//   5. ChatViewModel.acceptNotificationTap injects a coordinator bubble
//      for .routed and a systemNote for .malformed.
//

import XCTest
import UserNotifications
@testable import Steward

final class NotificationActionRouterTests: XCTestCase {

    // MARK: - End-to-end: scheduler stamps, router decodes

    func testSchedulerStampsTypedContextAndRouterDecodes() async throws {
        let center = FakeUNCenter()
        let provider = FakeSettingsProvider(snapshot: defaultRouterSettings())
        let tz = TimeZone(identifier: "America/New_York")!
        var noonComps = DateComponents()
        noonComps.year = 2026; noonComps.month = 5; noonComps.day = 17
        noonComps.hour = 12; noonComps.minute = 0
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let now = cal.date(from: noonComps)!
        let clock = FixedClock(now)

        let scheduler = NotificationScheduler(
            center: center,
            settings: provider,
            clock: clock,
            timeZone: { tz },
            ruleStore: { nil }
        )

        let req = NotificationRequest(
            kind: .windDown,
            domain: "health",
            instrumentID: "inst_sleep_123",
            fireAt: now.addingTimeInterval(60 * 90),
            templateContext: TemplateContext(
                domainDisplayName: "Health",
                instrumentName: "sleep"
            ),
            actionContextJSON: nil,
            priority: 10
        )

        let outcome = await scheduler.schedule(req, scope: .coordinator)
        guard case .scheduled = outcome else {
            return XCTFail("expected .scheduled, got \(outcome)")
        }

        let pending = await center.pendingNotificationRequests()
        XCTAssertEqual(pending.count, 1)
        let userInfo = pending[0].content.userInfo

        let event = NotificationActionRouter.decodeContext(from: userInfo)
        switch event {
        case .routed(let ctx):
            XCTAssertEqual(ctx.kind, .windDown)
            XCTAssertEqual(ctx.domain, "health")
            XCTAssertEqual(ctx.instrumentID?.rawValue, "inst_sleep_123")
            XCTAssertNil(ctx.commitmentID)
            XCTAssertEqual(
                ctx.suggestedPrompt,
                "Want me to log your wind-down? Sleep window starts soon."
            )
        case .malformed(let reason):
            XCTFail("expected .routed, got .malformed(\(reason))")
        }
    }

    func testRouterDoesNotClobberAgentSuppliedActionContextJSON() async throws {
        // The agent's freeform `actionContextJSON` and the typed
        // NotificationActionContext live in DIFFERENT userInfo keys.
        // Stamping the typed context must not erase the agent's dict
        // (which other surfaces — e.g. the followup scheduler's
        // open_tab/focus_input/prime_mic hints — read directly).
        let center = FakeUNCenter()
        let provider = FakeSettingsProvider(snapshot: defaultRouterSettings())
        let tz = TimeZone(identifier: "America/New_York")!
        let clock = FixedClock(Date(timeIntervalSince1970: 1_780_000_000))
        let scheduler = NotificationScheduler(
            center: center,
            settings: provider,
            clock: clock,
            timeZone: { tz },
            ruleStore: { nil }
        )
        let agentJSON = #"{"open_tab":"chat","focus_input":true}"#
        let req = NotificationRequest(
            kind: .instrumentNudge,
            domain: "health",
            instrumentID: nil,
            fireAt: clock.now().addingTimeInterval(60 * 90),
            templateContext: TemplateContext(
                domainDisplayName: "Health",
                instrumentName: "weight"
            ),
            actionContextJSON: agentJSON,
            priority: 10
        )
        _ = await scheduler.schedule(req, scope: .coordinator)
        let pending = await center.pendingNotificationRequests()
        guard let info = pending.first?.content.userInfo else {
            return XCTFail("no pending request")
        }
        XCTAssertEqual(info["open_tab"] as? String, "chat")
        XCTAssertEqual(info["focus_input"] as? Bool, true)

        // And the typed key is also there alongside.
        let event = NotificationActionRouter.decodeContext(from: info)
        if case .routed(let ctx) = event {
            XCTAssertEqual(ctx.kind, .instrumentNudge)
            XCTAssertEqual(ctx.suggestedPrompt, "Want to log weight?")
        } else {
            XCTFail("expected .routed, got \(event)")
        }
    }

    // MARK: - Malformed inputs

    func testMissingActionContextProducesMalformedReason() {
        let event = NotificationActionRouter.decodeContext(from: [:])
        guard case .malformed(let reason) = event else {
            return XCTFail("expected .malformed, got \(event)")
        }
        XCTAssertEqual(reason, "missing_action_context")
    }

    func testInvalidJSONProducesMalformedReason() {
        let userInfo: [AnyHashable: Any] = [
            NotificationActionContext.userInfoKey: "not-real-json"
        ]
        let event = NotificationActionRouter.decodeContext(from: userInfo)
        guard case .malformed(let reason) = event else {
            return XCTFail("expected .malformed, got \(event)")
        }
        XCTAssertEqual(reason, "decode_failed")
    }

    func testNonStringValueAtKeyIsTreatedAsMissing() {
        // If something stamps a non-String value (e.g. a dict directly,
        // which the agent JSON splattering used to do at the top level),
        // we report missing rather than crashing on the type cast.
        let userInfo: [AnyHashable: Any] = [
            NotificationActionContext.userInfoKey: ["kind": "windDown"]
        ]
        let event = NotificationActionRouter.decodeContext(from: userInfo)
        if case .malformed(let reason) = event {
            XCTAssertEqual(reason, "missing_action_context")
        } else {
            XCTFail("expected .malformed, got \(event)")
        }
    }

    // MARK: - handleTap publishes + buffers

    func testHandleTapBuffersRoutedEvent() {
        // Construct a fresh router, NOT the shared singleton. The host
        // app mounts ChatView which subscribes to the singleton's tap
        // notification and drains its buffer — testing the singleton's
        // buffer is unreliable from inside an app-hosted test target.
        let router = NotificationActionRouter()
        let ctx = NotificationActionContext(
            kind: .windDown,
            domain: "health",
            instrumentID: InstrumentID(rawValue: "inst_sleep_1"),
            commitmentID: nil,
            suggestedPrompt: "Want me to log your wind-down? Sleep window starts soon."
        )
        let json = ctx.encodedJSONString()
        XCTAssertNotNil(json)
        let userInfo: [AnyHashable: Any] = [
            NotificationActionContext.userInfoKey: json!
        ]

        router.handleTap(userInfo: userInfo)

        // Buffer is set synchronously inside handleTap, before any
        // dispatch — read it back immediately.
        XCTAssertEqual(router.lastTapEvent, .routed(ctx))
        XCTAssertEqual(router.takeLastTapEvent(), .routed(ctx))
        XCTAssertNil(
            router.takeLastTapEvent(),
            "second drain returns nil — buffer cleared"
        )
    }

    @MainActor
    func testHandleTapPublishesRoutedEventViaNotificationCenter() async {
        // Notifications fan out via the process-wide NotificationCenter,
        // so any router instance (singleton or fresh) reaches our
        // observer. Use a fresh instance so the singleton's lifecycle
        // doesn't matter to this test.
        let router = NotificationActionRouter()
        let ctx = NotificationActionContext(
            kind: .windDown,
            domain: "health",
            instrumentID: nil,
            commitmentID: nil,
            suggestedPrompt: "Want me to log your wind-down? Sleep window starts soon."
        )
        let json = ctx.encodedJSONString()!
        let userInfo: [AnyHashable: Any] = [
            NotificationActionContext.userInfoKey: json
        ]

        var receivedEvent: NotificationActionRouter.TapEvent?
        let observerToken = NotificationCenter.default.addObserver(
            forName: .stewardNotificationTapped,
            object: nil,
            queue: .main
        ) { note in
            receivedEvent = note.userInfo?[
                NotificationActionRouter.tapEventUserInfoKey
            ] as? NotificationActionRouter.TapEvent
        }
        defer { NotificationCenter.default.removeObserver(observerToken) }

        router.handleTap(userInfo: userInfo)
        // Give the main queue a turn so the .main-queue observer fires.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(receivedEvent, .routed(ctx))
    }

    func testHandleTapBuffersMalformedForUnknownPayload() {
        let router = NotificationActionRouter()
        router.handleTap(userInfo: ["unrelated": "value"])
        XCTAssertEqual(
            router.lastTapEvent,
            .malformed(reason: "missing_action_context")
        )
        XCTAssertEqual(
            router.takeLastTapEvent(),
            .malformed(reason: "missing_action_context")
        )
    }

    // MARK: - NotificationActionContext.from(request:)

    func testFromRequestPicksDefaultPromptByKind() {
        let req = NotificationRequest(
            kind: .commitmentDue,
            domain: "career",
            instrumentID: nil,
            fireAt: Date(),
            templateContext: TemplateContext(commitmentTitle: "send PR review"),
            actionContextJSON: nil,
            priority: 10
        )
        let ctx = NotificationActionContext.from(request: req)
        XCTAssertEqual(ctx.kind, .commitmentDue)
        XCTAssertEqual(ctx.domain, "career")
        XCTAssertEqual(
            ctx.suggestedPrompt,
            "Coming up: send PR review. Want to mark progress?"
        )
    }

    func testFromRequestFallsBackWhenContextIsEmpty() {
        let req = NotificationRequest(
            kind: .recoveryNudge,
            domain: nil,
            instrumentID: nil,
            fireAt: Date(),
            templateContext: TemplateContext(),
            actionContextJSON: nil,
            priority: 10
        )
        let ctx = NotificationActionContext.from(request: req)
        XCTAssertEqual(ctx.suggestedPrompt, "Want to take a small step?")
    }

    // MARK: - ChatViewModel integration

    @MainActor
    func testChatViewModelAcceptsRoutedTapAsCoordinatorBubble() {
        let viewModel = ChatViewModel()
        XCTAssertTrue(viewModel.messages.isEmpty)

        let ctx = NotificationActionContext(
            kind: .windDown,
            domain: "health",
            instrumentID: nil,
            commitmentID: nil,
            suggestedPrompt: "Want me to log your wind-down? Sleep window starts soon."
        )
        viewModel.acceptNotificationTap(.routed(ctx))

        XCTAssertEqual(viewModel.messages.count, 1)
        guard case .coordinator(let text, let isStub) = viewModel.messages[0].body else {
            return XCTFail("expected .coordinator bubble, got \(viewModel.messages[0].body)")
        }
        XCTAssertFalse(isStub)
        XCTAssertEqual(
            text,
            "Want me to log your wind-down? Sleep window starts soon."
        )
        XCTAssertTrue(
            viewModel.hasAnyHistory,
            "tap-injected coordinator turn counts as history — greeting must hide"
        )
    }

    @MainActor
    func testChatViewModelSurfaceMalformedTapAsSystemNote() {
        let viewModel = ChatViewModel()
        viewModel.acceptNotificationTap(.malformed(reason: "decode_failed"))
        XCTAssertEqual(viewModel.messages.count, 1)
        guard case .systemNote(let text) = viewModel.messages[0].body else {
            return XCTFail("expected .systemNote, got \(viewModel.messages[0].body)")
        }
        XCTAssertTrue(
            text.contains("decode_failed"),
            "user-facing note must name the reason so the failure isn't silent"
        )
    }
}

// MARK: - Local helpers (independent of NotificationSchedulerTests.swift)

private func defaultRouterSettings() -> Settings {
    Settings(
        quietHours: Settings.QuietHours(start: "22:00", end: "05:00"),
        morningBriefTime: "07:00",
        maxProactiveNotificationsPerDay: 3,
        minNotificationGapMinutes: 90,
        mercyModeUntil: nil,
        pauseUntil: nil,
        csvMirrorEnabled: true,
        icloudDriveFolder: "Steward",
        voiceCaptureEnabled: true,
        defaultAgentTemperature: 0.7
    )
}
