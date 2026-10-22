import XCTest
import SwiftUI
import AppKit
import BowserSurfaceKit
@testable import Bowser

final class ModSmithTests: XCTestCase {
    func testPauseReasonsDistinguishRequestLimitFromTimeoutAndOldTurns() throws {
        func turn(_ reason: String?) throws -> ModSmithTurn {
            var value: [String: Any] = ["id": "paused", "role": "assistant", "status": "partial", "text": "One check remains."]
            value["pause_reason"] = reason
            return try JSONDecoder().decode(ModSmithTurn.self, from: JSONSerialization.data(withJSONObject: value))
        }
        XCTAssertNotNil(try turn("request_limit").pauseExplanation)
        XCTAssertNotEqual(try turn("request_limit").pauseExplanation, try turn("time_limit").pauseExplanation)
        XCTAssertNotNil(try turn("no_progress").pauseExplanation)
        XCTAssertNil(try turn(nil).pauseExplanation)
        XCTAssertNil(try turn("unknown").pauseExplanation)
    }
    @MainActor func testCopyTargetsDestinationWithoutSwitchingSourceProfile() {
        let model = ModSmithModel()
        model.connected = { true }
        var sent: [String: Any] = [:]
        model.send = { sent = $0 }
        model.action("copy", project: "source", path: "work")
        XCTAssertEqual(sent["project"] as? String, "source")
        XCTAssertEqual(sent["destination"] as? String, "work")
        model.action("copy_existing", project: "mods/reader.ex", path: "work")
        XCTAssertNil(sent["project"])
        XCTAssertEqual(sent["path"] as? String, "mods/reader.ex")
        XCTAssertEqual(sent["destination"] as? String, "work")
    }

    private var taskFixture: [String: Any] {
        ["id": "task", "kind": "task", "name": "Table export", "scope": "site", "url": "https://example.com/report",
         "status": "active", "summary": "Saved all 24 rows as CSV.", "files": [], "enabled": false, "can_undo": false,
         "artifacts": [["name": "report.csv", "path": "/tmp/bowser-task-fixture/report.csv", "bytes": 1240]],
         "turns": [["id": "request", "role": "user", "text": "Export this table as CSV"],
                   ["id": "result", "role": "assistant", "status": "active", "text": "Saved all 24 rows as CSV.", "checks": ["Compared all 24 source rows with the exported file."]]]]
    }

    @MainActor func testOneOffSubmissionAndReusablePromotionKeepSeparateHistories() {
        let model = ModSmithModel()
        model.connected = { true }
        model.targetURL = "https://example.com/report"
        model.targetWebview = 7
        model.scopeChoice.reset(url: model.targetURL)
        var events: [[String: Any]] = []
        model.send = { events.append($0) }
        model.draft = "Export this table as CSV"
        model.submit()
        XCTAssertEqual(events.last?["kind"] as? String, "task")
        XCTAssertEqual(events.last?["webview"] as? UInt64, 7)
        let accepted = events.last?["request_id"] as? String
        model.receive(["projects": [taskFixture], "selected": "task", "busy": false, "progress": [], "stage": "Ready", "accepted": accepted ?? ""])
        XCTAssertEqual(model.project?.statusLabel, "Completed")
        XCTAssertEqual(model.project?.artifacts?.first?.name, "report.csv")
        events = []
        model.action("make_reusable")
        XCTAssertNil(model.snapshot.selected)
        XCTAssertEqual(model.requestKind, "mod")
        XCTAssertFalse(events.contains { $0["action"] as? String == "submit" })
        XCTAssertTrue(model.draft.contains("Export this table as CSV"))
        XCTAssertEqual(model.snapshot.projects.count, 1)
        model.submit()
        XCTAssertEqual(events.last?["kind"] as? String, "mod")
        XCTAssertNil(events.last?["project"])
    }

    @MainActor func testRunAgainUsesFreshConversationAndCurrentTarget() {
        let model = ModSmithModel()
        model.connected = { true }
        model.receive(["projects": [taskFixture], "selected": "task", "busy": false, "progress": [], "stage": "Ready"])
        model.targetURL = "https://example.org/other"
        model.targetWebview = 22
        var events: [[String: Any]] = []
        model.send = { events.append($0) }
        model.action("run_again")
        XCTAssertEqual(events.last?["kind"] as? String, "task")
        XCTAssertEqual(events.last?["text"] as? String, "Export this table as CSV")
        XCTAssertEqual(events.last?["url"] as? String, "https://example.org/other")
        XCTAssertNil(events.last?["project"])
        XCTAssertEqual(model.snapshot.projects.first?.id, "task")
    }

    @MainActor func testRenderOneOffTaskWorkspace() async throws {
        guard let directory = ProcessInfo.processInfo.environment["BOWSER_TASK_RENDER"] else { throw XCTSkip("Set BOWSER_TASK_RENDER for task UI previews") }
        _ = NSApplication.shared
        for state in ["new", "result", "history"] {
            let model = ModSmithModel()
            model.targetURL = "https://example.com/report"
            model.scopeChoice.reset(url: model.targetURL)
            if state != "new" {
                model.receive(["projects": [taskFixture], "selected": "task", "busy": false, "progress": [], "stage": "Ready"])
            }
            model.workspacePage = state == "history" ? "overview" : state == "new" ? "new" : "history"
            let view = NSHostingView(rootView: ModSmithRootView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 1060, height: 760)
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(180))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("task-\(state).png"))
            window.close()
        }
    }

    private func resultTurn(status: String?, checks: [String]? = nil, role: String = "assistant") throws -> ModSmithTurn {
        var json: [String: Any] = ["id": "result", "role": role,
            "text": "The sidebar layout is updated. Scrolling still needs a fix.",
            "notes": "Long lists cannot yet be reached with the trackpad."]
        if let status { json["status"] = status }
        if let checks { json["checks"] = checks }
        return try JSONDecoder().decode(ModSmithTurn.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testResultPresentationKeepsOutcomeSeparateFromReportedEvidence() throws {
        let incomplete = try resultTurn(status: "partial", checks: [" ", "  Opened the sidebar and inspected the layout.  "])
        XCTAssertEqual(incomplete.outcomeLabel, "Not finished")
        XCTAssertEqual(incomplete.reportedChecks, ["Opened the sidebar and inspected the layout."])
        let question = try resultTurn(status: "needs_help", checks: [])
        XCTAssertEqual(question.outcomeLabel, "Action needed")
        XCTAssertTrue(question.reportedChecks.isEmpty)
        XCTAssertNil(try resultTurn(status: nil).outcomeLabel)
        XCTAssertNil(try resultTurn(status: "active", role: "user").outcomeLabel)
        XCTAssertEqual(try resultTurn(status: "active").outcomeLabel, "Completed and checked")
        XCTAssertEqual(try resultTurn(status: "failed", checks: ["The sidebar opened before the action failed."]).reportedChecks.count, 1)
    }

    @MainActor func testResultCardsRenderWithReadableExpandedEvidence() async throws {
        _ = NSApplication.shared
        var partial = try resultTurn(status: "partial", checks: ["Opened the sidebar and confirmed the new layout.",
            "The toolbar button opens and closes the sidebar. Trackpad scrolling is still not working."])
        partial.pauseReason = "request_limit"
        let question = try JSONDecoder().decode(ModSmithTurn.self, from: JSONSerialization.data(withJSONObject: [
            "id": "question", "role": "assistant", "status": "needs_help", "checks": [],
            "text": "Should the sidebar appear on every website or only on this site?"
        ]))
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 20) {
                ModSmithTurnCard(turn: partial, detailsExpanded: true)
                ModSmithTurnCard(turn: question)
            }.padding(20).frame(width: 620).preferredColorScheme(scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame.size = NSSize(width: 620, height: 500)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 200)
            if let directory = ProcessInfo.processInfo.environment["BOWSER_MODSMITH_PREVIEW"] {
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(150))
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("modsmith-\(name).png"))
            }
            window.close()
        }
    }

    private func snapshot(selected: String? = nil, accepted: String? = nil) -> [String: Any] {
        var data: [String: Any] = ["projects": [], "busy": false, "progress": [], "stage": "Inspecting page"]
        if let selected { data["selected"] = selected }
        if let accepted { data["accepted"] = accepted }
        return data
    }

    @MainActor func testOverviewAndGuidePreserveDraftWithoutStartingWork() {
        let model = ModSmithModel()
        model.connected = { true }
        var events: [[String: Any]] = []
        model.send = { events.append($0) }
        model.receive(snapshot(selected: "existing"))
        model.workspacePage = "history"
        model.draft = "Keep my changes"
        model.instructionsOpen = true
        model.action("overview")
        XCTAssertEqual(model.workspacePage, "overview")
        XCTAssertEqual(model.draft, "Keep my changes")
        XCTAssertTrue(events.isEmpty)
        model.action("select", project: "existing")
        XCTAssertEqual(model.workspacePage, "history")
        XCTAssertEqual(model.draft, "Keep my changes")
        XCTAssertEqual(events.last?["action"] as? String, "select")
        XCTAssertFalse(events.contains { ["document", "submit"].contains($0["action"] as? String ?? "") })
    }

    @MainActor func testCatalogDeduplicatesDisabledFilesAndKeepsModsWithoutHistory() throws {
        let raw: [String: Any] = ["busy": false, "progress": [], "stage": "Ready", "projects": [["id": "p", "name": "Reader", "scope": "site", "url": "https://example.com", "status": "active", "summary": "Ready", "turns": [], "files": ["sites/example.com/reader.css.off"], "enabled": false, "can_undo": false]], "available_mods": [
            ["path": "sites/example.com/reader.css", "name": "Reader", "scope": "example.com", "enabled": false],
            ["path": "mods/new.ex", "name": "New", "scope": "Across Bowser", "enabled": true]]]
        let data = try JSONDecoder().decode(ModSmithSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(data.unrepresentedMods.map(\.path), ["mods/new.ex"])
        XCTAssertEqual(data.projects.first?.statusLabel, "Ready")
        XCTAssertFalse(try XCTUnwrap(data.projects.first).enabled)
    }

    @MainActor func testStopTargetsActiveRunWhenItsConversationIsFilteredOut() {
        let model = ModSmithModel()
        model.connected = { true }
        var sent: [String: Any] = [:]
        model.send = { sent = $0 }
        var data = snapshot(selected: "another-chat")
        data["busy"] = true
        data["running_run"] = "run-token"
        data["running_project"] = "running-chat"
        model.receive(data)
        XCTAssertTrue(model.snapshot.projects.isEmpty)
        XCTAssertTrue(model.snapshot.canStop)
        model.action("cancel")
        XCTAssertEqual(sent["run"] as? String, "run-token")
        XCTAssertEqual(sent["project"] as? String, "running-chat")
    }

    @MainActor func testDraftsSurviveSwitchingConversations() {
        let model = ModSmithModel()
        model.targetURL = "https://example.com"
        model.scopeChoice.reset(url: model.targetURL)
        model.draft = "New mod idea"
        model.receive(snapshot(selected: "existing"))
        XCTAssertEqual(model.draft, "")
        model.draft = "Refinement idea"
        model.receive(snapshot())
        XCTAssertEqual(model.draft, "New mod idea")
        model.receive(snapshot(selected: "existing"))
        XCTAssertEqual(model.draft, "Refinement idea")
    }

    @MainActor func testDeletingConversationClearsItsDraftAfterAcknowledgement() {
        let model = ModSmithModel()
        model.connected = { true }
        var sent: [String: Any] = [:]
        model.send = { sent = $0 }
        model.draft = "Keep new idea"
        model.receive(snapshot(selected: "deleted"))
        model.draft = "Private refinement"
        model.action("delete")
        XCTAssertEqual(sent["project"] as? String, "deleted")
        XCTAssertEqual(sent["action"] as? String, "delete")
        model.receive(snapshot())
        XCTAssertEqual(model.draft, "Keep new idea")
        model.receive(snapshot(selected: "deleted"))
        XCTAssertEqual(model.draft, "")
    }

    @MainActor func testOnlyAcceptedSubmissionClearsDraft() {
        let model = ModSmithModel()
        model.targetURL = "https://example.com"
        model.scopeChoice.reset(url: model.targetURL)
        model.connected = { true }
        var sent: [String: Any] = [:]
        model.send = { sent = $0 }
        model.draft = "Make it larger"
        model.submit()
        XCTAssertEqual(model.draft, "Make it larger")
        model.receive(snapshot(selected: "new-project", accepted: sent["request_id"] as? String))
        model.receive(snapshot())
        XCTAssertEqual(model.draft, "")
    }

    @MainActor func testNewTypingIsNotLostBySubmissionAcknowledgement() {
        let model = ModSmithModel()
        model.targetURL = "https://example.com"
        model.scopeChoice.reset(url: model.targetURL)
        model.connected = { true }
        var sent: [String: Any] = [:]
        model.send = { sent = $0 }
        model.draft = "First request"
        model.submit()
        model.draft = "Next idea"
        model.receive(snapshot(accepted: sent["request_id"] as? String))
        XCTAssertEqual(model.draft, "Next idea")
    }

    @MainActor func testDisconnectedSubmissionKeepsDraftAndDoesNotSend() {
        let model = ModSmithModel()
        model.targetURL = "https://example.com"
        model.scopeChoice.reset(url: model.targetURL)
        model.connected = { false }
        model.send = { _ in XCTFail("Must not send while disconnected") }
        model.draft = "Keep this"
        model.submit()
        XCTAssertEqual(model.draft, "Keep this")
        XCTAssertNotNil(model.connectionError)
    }
    @MainActor func testExistingPickerUsesExplicitPathAndKeepsNewDraft() {
        let model = ModSmithModel()
        model.targetURL = "https://example.com"
        model.scopeChoice.reset(url: model.targetURL)
        model.connected = { true }
        var sent: [String: Any] = [:]
        model.send = { sent = $0 }
        model.draft = "Keep my new idea"
        model.receive(["projects": [], "busy": false, "progress": [], "stage": "Ready",
                       "available_mods": [["path": "mods/reader.ex.off", "name": "Reader", "scope": "Across Bowser", "enabled": false]]])
        XCTAssertEqual(model.snapshot.available_mods?.first?.path, "mods/reader.ex.off")
        model.action("edit_existing", path: "mods/reader.ex.off")
        XCTAssertEqual(sent["action"] as? String, "edit_existing")
        XCTAssertEqual(sent["path"] as? String, "mods/reader.ex.off")
        XCTAssertEqual(model.draft, "Keep my new idea")
    }

    @MainActor func testStopRunningProjectWhileDraftingAnotherConversation() {
        let model = ModSmithModel()
        model.targetURL = "https://example.com"
        model.scopeChoice.reset(url: model.targetURL)
        model.connected = { true }
        model.receive(snapshot(selected: "other"))
        model.draft = "Keep this next idea"
        var sent: [String: Any] = [:]
        model.send = { sent = $0 }
        model.action("cancel", project: "running")
        XCTAssertEqual(sent["project"] as? String, "running")
        XCTAssertEqual(sent["action"] as? String, "cancel")
        XCTAssertEqual(model.draft, "Keep this next idea")
        XCTAssertEqual(model.snapshot.selected, "other")
    }

    @MainActor func testDisabledResultOffersEnableAndTestWithoutLosingDraft() {
        let model = ModSmithModel()
        model.connected = { true }
        var sent: [String: Any] = [:]
        model.send = { sent = $0 }
        var project: [String: Any] = [
            "id": "downloader", "name": "Downloader", "scope": "site", "url": "https://youtube.com",
            "status": "needs_help", "summary": "", "files": ["mods/downloader.ex.off"],
            "turns": [["id": "reply", "role": "assistant", "text": "NEEDS THE RESIDENT AGENT: Mod is disabled."]],
            "enabled": false, "can_undo": true
        ]
        func receive() { model.receive(["projects": [project], "selected": "downloader", "busy": false, "progress": [], "stage": "Ready"]) }
        receive()
        XCTAssertEqual(model.project?.statusLabel, "Needs your input")
        XCTAssertEqual(model.project?.canEnableAndTest, true)
        XCTAssertEqual(model.project?.turns.first?.displayText, "Mod is disabled.")
        model.draft = "Keep my request"
        model.action("enable_and_test")
        XCTAssertEqual(sent["action"] as? String, "enable_and_test")
        XCTAssertEqual(sent["project"] as? String, "downloader")
        XCTAssertEqual(model.draft, "Keep my request")
        project["status"] = "working"; receive()
        XCTAssertEqual(model.project?.canEnableAndTest, false)
        project["status"] = "needs_help"; project["enabled"] = true; receive()
        XCTAssertEqual(model.project?.canEnableAndTest, false)
        project["enabled"] = false; project["files"] = [String](); receive()
        XCTAssertEqual(model.project?.canEnableAndTest, false)
    }

    @MainActor func testGenericNextStepsAndRepairNoticesAreIndependent() {
        let model = ModSmithModel()
        for action in ["reply", "resume", "repair"] {
            let project: [String: Any] = [
                "id": "organizer", "name": "Organizer", "scope": "browser", "url": "",
                "status": "needs_help", "summary": "Choose where to apply this change.",
                "files": ["mods/organizer.ex"], "enabled": true, "can_undo": true, "turns": [],
                "next_step": ["title": "Choose a workspace", "detail": "Select the workspace to use.", "action": action],
                "repair_notice": "A proposed change was not installed."
            ]
            model.receive(["projects": [project], "selected": "organizer", "busy": false, "progress": [], "stage": "Ready"])
            XCTAssertEqual(model.project?.needsNextStep, true)
            XCTAssertEqual(model.project?.nextStep?.action, action)
            XCTAssertEqual(model.project?.nextStep?.detail, "Select the workspace to use.")
            XCTAssertNotNil(model.project?.repairNotice)
        }
    }

    @MainActor func testContinueEligibilityAndActionPreserveDraft() {
        let model = ModSmithModel()
        model.targetURL = "https://example.com"
        model.scopeChoice.reset(url: model.targetURL)
        model.connected = { true }
        var sent: [String: Any] = [:]
        model.send = { sent = $0 }
        for status in ["partial", "needs_help", "failed", "interrupted", "active", "working", "ready"] {
            let project: [String: Any] = [
                "id": "filter", "name": "Filter", "scope": "site", "url": "https://x.com",
                "status": status, "summary": "", "files": [], "turns": [],
                "enabled": true, "can_undo": false
            ]
            model.receive(["projects": [project], "selected": "filter", "busy": false, "progress": [], "stage": "Ready"])
            XCTAssertEqual(model.project?.canContinue, ["partial", "needs_help", "failed", "interrupted"].contains(status))
            if status == "partial" { XCTAssertEqual(model.project?.statusLabel, "Unfinished") }
        }
        model.draft = "Keep this next idea"
        model.action("continue", project: "filter")
        XCTAssertEqual(sent["action"] as? String, "continue")
        XCTAssertEqual(sent["project"] as? String, "filter")
        XCTAssertEqual(model.draft, "Keep this next idea")
    }

    @MainActor func testFailedFirstBuildRetriesSavedRequestAndKeepsUnsentDraft() {
        let model = ModSmithModel()
        model.connected = { true }
        var sent: [String: Any] = [:]
        model.send = { sent = $0 }
        var project: [String: Any] = [
            "id": "video", "name": "Video controls", "scope": "browser", "url": "",
            "status": "failed", "summary": "Service unavailable", "files": [], "turns": [],
            "enabled": false, "can_undo": false
        ]
        func receive() { model.receive(["projects": [project], "selected": "video", "busy": false, "progress": [], "stage": "Ready"]) }
        receive()
        XCTAssertEqual(model.project?.statusLabel, "Needs attention")
        XCTAssertEqual(model.project?.canRetry, true)
        XCTAssertEqual(model.project?.canEnableAndTest, false)
        model.draft = "An unsent refinement"
        model.action(model.project!.recoveryAction, project: model.project!.id)
        XCTAssertEqual(sent["action"] as? String, "retry")
        XCTAssertEqual(sent["project"] as? String, "video")
        XCTAssertEqual(model.draft, "An unsent refinement")
        project["files"] = ["mods/video.ex"]; receive()
        XCTAssertEqual(model.project?.canRetry, false)
        XCTAssertEqual(model.project?.recoveryAction, "continue")
        project["files"] = [String]()
        project["next_step"] = ["title": "Choose a target", "detail": "Which page?", "action": "reply"]
        receive()
        XCTAssertEqual(model.project?.canRetry, false)
        XCTAssertEqual(model.project?.needsNextStep, true)
    }

    @MainActor func testOmnibarStartsNewProjectOnceAndPreservesCapturedTarget() {
        let model = ModSmithModel()
        model.connected = { true }
        model.targetURL = "https://example.com/article"
        model.targetWebview = 42
        model.receive(snapshot(selected: "existing"))
        var messages: [[String: Any]] = []
        model.send = { messages.append($0) }
        model.prepareNewDraft("Hide distractions", scope: "site", start: true)
        model.submit()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["action"] as? String, "submit")
        XCTAssertNil(messages.first?["project"])
        XCTAssertEqual(messages.first?["url"] as? String, "https://example.com/article")
        XCTAssertEqual(messages.first?["webview"] as? UInt64, 42)
        XCTAssertEqual(model.draft, "Hide distractions")
    }

    @MainActor func testBusyOmnibarKeepsRequestWithoutStartingAnotherBuild() {
        let model = ModSmithModel()
        model.connected = { true }
        model.receive(["projects": [], "busy": true, "progress": [], "stage": "Building"])
        model.send = { _ in XCTFail("Busy must not submit") }
        model.prepareNewDraft("Organize tabs", scope: "browser", start: true)
        XCTAssertEqual(model.draft, "Organize tabs")
        XCTAssertNotNil(model.connectionError)
    }

    @MainActor func testRenderNativeWorkspace() async throws {
        guard let directory = ProcessInfo.processInfo.environment["BOWSER_MODSMITH_RENDER"] else {
            throw XCTSkip("Set BOWSER_MODSMITH_RENDER for native visual verification")
        }
        _ = NSApplication.shared
        let model = ModSmithModel()
        model.targetURL = "https://example.com"
        model.scopeChoice.reset(url: model.targetURL)
        model.targetURL = "https://example.com/article"
        let icon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            return true
        }
        let iconPath = URL(fileURLWithPath: directory).appendingPathComponent("fixture-favicon.png")
        let iconData = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(icon.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try iconData.write(to: iconPath)
        model.scopeChoice.reset(url: model.targetURL, faviconPath: iconPath.path)
        let project: [String: Any] = [
            "id": "reading", "name": "Comfortable reading", "scope": "site", "url": model.targetURL, "favicon": iconPath.path,
            "status": "partial", "summary": "Larger text and a calmer layout.", "files": ["sites/example.com/reading.css"],
            "enabled": true, "can_undo": true, "undo_label": "Make the text larger",
            "usage": ["entry_point": "Reading mode runs automatically on this website.",
                      "steps": ["Open an article on example.com.", "Read with larger text and a narrower column."], "tips": "Reload an already-open article if needed."],
            "turns": [
                ["id": "u", "role": "user", "text": "Make this page easier to read. Hide distractions and make the text larger."],
                ["id": "a", "role": "assistant", "text": "Added a warm background, a narrower reading column, and larger text.",
                 "notes": "The sticky navigation still needs work.", "checks": ["Confirmed the paragraph font is 20px.", "Checked that the article stays scrollable."]]
            ]
        ]
        for (name, width, filled) in [("overview-empty", 1060, false), ("overview", 1060, true), ("guide", 1200, true), ("compact-guide", 880, true), ("failed", 1060, true), ("empty", 1060, false), ("result", 1060, true), ("compact", 880, true), ("success", 1060, true), ("input", 1060, true), ("prerequisite", 880, true), ("disabled", 1060, true), ("running-other", 880, true), ("running-filtered", 880, true)] {
            if filled {
                model.receive(["projects": [project], "selected": "reading", "busy": false, "progress": [], "stage": "Ready"])
            }
            model.workspacePage = name.hasPrefix("overview") ? "overview" : filled ? "history" : "new"
            model.instructionsOpen = name == "guide"
            if name == "failed" {
                var failed = project
                failed["status"] = "failed"
                failed["files"] = [String]()
                failed["enabled"] = false
                failed["can_undo"] = false
                failed["repair_notice"] = "Security review couldn’t run. The proposed code was not installed. Try again."
                failed["turns"] = [
                    ["id": "u", "role": "user", "text": "Make this page easier to read."],
                    ["id": "a", "role": "assistant", "status": "failed", "text": "The AI service is unavailable. Please try again shortly."]
                ]
                model.receive(["projects": [failed], "selected": "reading", "busy": false, "progress": [], "stage": "Ready"])
            }
            if name == "success" {
                var success = project
                success["status"] = "active"
                model.receive(["projects": [success], "selected": "reading", "busy": false, "progress": [], "stage": "Ready"])
            }
            if name == "running-other" {
                var running = project
                running["status"] = "working"
                model.receive(["projects": [running], "busy": true, "progress": [], "stage": "Checking your mod"])
            }
            if name == "running-filtered" {
                model.receive(["projects": [], "busy": true, "running_run": "fixture-run", "running_project": "hidden-chat", "progress": [], "stage": "Verifying the outcome"])
            }
            if ["input", "prerequisite", "disabled"].contains(name) {
                var blocked = project
                blocked["status"] = "needs_help"
                blocked["enabled"] = name != "disabled"
                blocked["turns"] = [["id": "activity", "role": "activity", "text": "Checking what’s needed next…"]]
                if name != "disabled" {
                    var nextStep: [String: Any] = ["title": name == "input" ? "Choose a reading style" : "Open the document",
                        "detail": name == "input" ? "Would you prefer a warm background or the website’s original colors?" : "Open the document you want to format, then resume testing.",
                        "action": name == "input" ? "reply" : "resume"]
                    if name == "input" {
                        nextStep["options"] = [
                            ["id": "q|0", "label": "Warm background", "description": "Use soft colors for longer reading sessions."],
                            ["id": "q|1", "label": "Original colors", "description": "Keep the website’s appearance and adjust the layout."]]
                    }
                    blocked["next_step"] = nextStep
                    blocked["repair_notice"] = "A proposed change could not pass security review and was not installed. Any earlier saved changes remain."
                }
                model.receive(["projects": [blocked], "selected": "reading", "busy": false, "progress": [], "stage": "Ready"])
            }
            if filled {
                var older = project
                older["id"] = "older-mod"
                older["name"] = "Focus mode"
                older["scope"] = "browser"
                older["status"] = "active"
                older["favicon"] = nil
                older["files"] = ["mods/focus.ex"]
                model.snapshot.projects.append(try JSONDecoder().decode(ModSmithProject.self,
                    from: JSONSerialization.data(withJSONObject: older)))
            }
            model.snapshot.workspace_profile = try JSONDecoder().decode(ModSmithProfile.self,
                from: Data(#"{"id":"work","name":"Work","icon":"💼"}"#.utf8))
            model.snapshot.running_profile = model.snapshot.busy ? try JSONDecoder().decode(ModSmithProfile.self,
                from: Data(#"{"id":"personal","name":"Personal","icon":"🏠"}"#.utf8)) : nil
            let view = NSHostingView(rootView: ModSmithRootView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 660),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: width, height: 660)
            view.layoutSubtreeIfNeeded()
            if name == "compact-guide" {
                window.makeKeyAndOrderFront(nil)
                model.draft = "Keep this refinement"
                model.instructionsOpen = true
                for _ in 0..<30 where window.sheets.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
                let sheet = try XCTUnwrap(window.sheets.first)
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertGreaterThan(sheet.frame.width, 400)
                model.instructionsOpen = false
                for _ in 0..<30 where !window.sheets.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertTrue(window.sheets.isEmpty)
                XCTAssertEqual(model.draft, "Keep this refinement")
                window.orderOut(nil)
            }
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("modsmith-\(name).png"))
        }
    }

}
