import XCTest
import SwiftUI
import AppKit
@testable import Bowser

final class ModSmithTests: XCTestCase {
    private func snapshot(selected: String? = nil, accepted: String? = nil) -> [String: Any] {
        var data: [String: Any] = ["projects": [], "busy": false, "progress": [], "stage": "Inspecting page"]
        if let selected { data["selected"] = selected }
        if let accepted { data["accepted"] = accepted }
        return data
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
        XCTAssertEqual(model.project?.statusLabel, "Disabled")
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
        for action in ["reply", "resume"] {
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

    @MainActor func testRenderNativeWorkspace() throws {
        guard let directory = ProcessInfo.processInfo.environment["BOWSER_MODSMITH_RENDER"] else {
            throw XCTSkip("Set BOWSER_MODSMITH_RENDER for native visual verification")
        }
        _ = NSApplication.shared
        let model = ModSmithModel()
        model.targetURL = "https://example.com"
        model.scopeChoice.reset(url: model.targetURL)
        model.targetURL = "https://example.com/article"
        let project: [String: Any] = [
            "id": "reading", "name": "Comfortable reading", "scope": "site", "url": model.targetURL,
            "status": "partial", "summary": "Larger text and a calmer layout.", "files": ["sites/example.com/reading.css"],
            "enabled": true, "can_undo": true, "undo_label": "Make the text larger",
            "turns": [
                ["id": "u", "role": "user", "text": "Make this page easier to read. Hide distractions and make the text larger."],
                ["id": "a", "role": "assistant", "text": "Added a warm background, a narrower reading column, and larger text.",
                 "notes": "The sticky navigation still needs work.", "checks": ["Confirmed the paragraph font is 20px.", "Checked that the article stays scrollable."]]
            ]
        ]
        for (name, width, filled) in [("empty", 760, false), ("result", 760, true), ("compact", 620, true), ("success", 760, true), ("input", 760, true), ("prerequisite", 620, true), ("disabled", 760, true), ("running-other", 620, true)] {
            if filled {
                model.receive(["projects": [project], "selected": "reading", "busy": false, "progress": [], "stage": "Ready"])
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
            if ["input", "prerequisite", "disabled"].contains(name) {
                var blocked = project
                blocked["status"] = "needs_help"
                blocked["enabled"] = name != "disabled"
                blocked["turns"] = [["id": "activity", "role": "activity", "text": "Checking what’s needed next…"]]
                if name != "disabled" {
                    blocked["next_step"] = ["title": name == "input" ? "Choose a reading style" : "Open the document",
                        "detail": name == "input" ? "Would you prefer a warm background or the website’s original colors?" : "Open the document you want to format, then resume testing.",
                        "action": name == "input" ? "reply" : "resume"]
                    blocked["repair_notice"] = "A proposed change could not pass security review and was not installed. Any earlier saved changes remain."
                }
                model.receive(["projects": [blocked], "selected": "reading", "busy": false, "progress": [], "stage": "Ready"])
            }
            let view = NSHostingView(rootView: ModSmithRootView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 660),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: width, height: 660)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("modsmith-\(name).png"))
        }
    }

}
