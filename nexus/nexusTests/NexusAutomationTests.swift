import XCTest
@testable import nexus

final class NexusAutomationTests: XCTestCase {
    func testDailyScheduleAdvancesAfterTodayTime() throws {
        let timezone = TimeZone(identifier: "America/Los_Angeles")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let now = try XCTUnwrap(calendar.date(from: .init(timeZone: timezone, year: 2026, month: 8, day: 10, hour: 9, minute: 15)))
        let schedule = NexusSchedule(frequency: .daily, timeZoneIdentifier: timezone.identifier, hour: 7, minute: 0)
        let next = try XCTUnwrap(schedule.next(after: now))
        XCTAssertEqual(calendar.component(.day, from: next), 11)
        XCTAssertEqual(calendar.component(.hour, from: next), 7)
    }

    func testWeeklyScheduleRespectsSelectedWeekdays() throws {
        let timezone = TimeZone(identifier: "America/Los_Angeles")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let monday = try XCTUnwrap(calendar.date(from: .init(timeZone: timezone, year: 2026, month: 8, day: 10, hour: 8, minute: 0)))
        let schedule = NexusSchedule(frequency: .weekly, timeZoneIdentifier: timezone.identifier, hour: 7, minute: 0, weekdays: [3])
        let next = try XCTUnwrap(schedule.next(after: monday))
        XCTAssertEqual(calendar.component(.weekday, from: next), 3)
        XCTAssertEqual(calendar.component(.day, from: next), 11)
    }

    func testPromptScheduleResolutionKeepsTimezoneAndRecognizesWeekdays() {
        let fallback = NexusSchedule(frequency: .daily, timeZoneIdentifier: "America/Los_Angeles", hour: 7, minute: 0)
        let resolved = NexusAutomationScheduleParser.resolve(
            prompt: "Every Monday and Thursday at 7:30 pm, prepare my briefing",
            fallback: fallback
        )
        XCTAssertEqual(resolved.frequency, .weekly)
        XCTAssertEqual(resolved.weekdays, [2, 5])
        XCTAssertEqual(resolved.hour, 19)
        XCTAssertEqual(resolved.minute, 30)
        XCTAssertEqual(resolved.timeZoneIdentifier, "America/Los_Angeles")
    }

    func testEveryWeekdayResolvesToMondayThroughFriday() {
        let resolved = NexusAutomationScheduleParser.resolve(
            prompt: "Every weekday at 7 AM, make my morning briefing",
            fallback: .init(frequency: .daily, timeZoneIdentifier: "America/Los_Angeles")
        )
        XCTAssertEqual(resolved.frequency, .weekly)
        XCTAssertEqual(resolved.weekdays, [2, 3, 4, 5, 6])
        XCTAssertEqual(resolved.hour, 7)
    }

    func testMorningBriefingRecipeHasExactBrowserReadSchemas() {
        let blueprint = NexusMorningBriefingRecipe.blueprint(modelID: "ollama:qwen2.5:1.5b:default")
        XCTAssertEqual(blueprint.steps.map(\.tool), [
            "browser.run_task",
            "browser.run_task",
            "web_search",
            "browser.run_task",
            "web_search"
        ])
        XCTAssertEqual(blueprint.steps[0].arguments["steps"]?.array?.first?.object?["url"]?.string, "https://mail.google.com/mail/u/0/#search/is%3Aunread%20newer_than%3A2d")
        XCTAssertEqual(blueprint.steps[1].arguments["steps"]?.array?.first?.object?["url"]?.string, "https://calendar.google.com/calendar/u/0/r/agenda")
        XCTAssertTrue(blueprint.steps[3].requiresApproval)
        XCTAssertEqual(blueprint.steps[3].arguments["steps"]?.array?.count, 2)
    }

    func testMorningBriefingUsesNamedEvidenceSourcesAndStrictVoiceFormat() {
        let blueprint = NexusMorningBriefingRecipe.blueprint(modelID: "ollama:qwen")
        XCTAssertEqual(NexusMorningBriefingRecipe.sourceName(for: blueprint.steps[0]), "Gmail")
        XCTAssertEqual(NexusMorningBriefingRecipe.sourceName(for: blueprint.steps[1]), "Google Calendar")
        XCTAssertEqual(NexusMorningBriefingRecipe.sourceName(for: blueprint.steps[2]), "Weather")
        XCTAssertEqual(NexusMorningBriefingRecipe.sourceName(for: blueprint.steps[3]), "Fidelity portfolio")
        XCTAssertEqual(NexusMorningBriefingRecipe.sourceName(for: blueprint.steps[4]), "Market research")

        let valid = "Good morning, Vishay. It is Tuesday, August 12 at 7:00 AM PDT. Weather: It is 68 degrees and clear. Your inbox: You have two urgent requests. Your calendar: Your next meeting is at 10 AM. Your portfolio: Your portfolio is up 1.2%. Market context: Technology shares are higher after the earnings reports."
        XCTAssertTrue(NexusMorningBriefingRecipe.conformsToBriefingFormat(valid))
        XCTAssertFalse(NexusMorningBriefingRecipe.conformsToBriefingFormat("Good morning, Vishay. I found your weather."))
        XCTAssertTrue(NexusMorningBriefingRecipe.hasFirstPersonVoice("I found your calendar."))
    }

    func testStorePersistsAutomationAndRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexusAutomationTests-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("automations.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NexusAutomationStore(url: url)
        let blueprint = NexusAutomationBlueprint(
            modelID: "ollama:qwen",
            steps: [.init(tool: "gmail.triage", arguments: ["limit": .number(10)], purpose: "Read inbox", requiresApproval: false)]
        )
        let automation = NexusAutomation(title: "Briefing", prompt: "Summarize my day", schedule: .init(), blueprint: blueprint)
        try await store.save(automation)
        var run = NexusAutomationRun(automationID: automation.id, scheduledFor: .now, state: .completed)
        run.summary = "Good morning"
        try await store.saveRun(run)

        let restored = NexusAutomationStore(url: url)
        let automations = await restored.automations()
        let runs = await restored.runs(for: automation.id)
        XCTAssertEqual(automations.map(\.id), [automation.id])
        XCTAssertEqual(runs.first?.summary, "Good morning")
        XCTAssertEqual(automations.first?.blueprint?.steps.map(\.tool), ["gmail.triage"])
    }

    func testAutomationInvocationCarriesExactApproval() {
        let invocation = NexToolInvocation.automation(approvedActions: ["calendar.create_event"])
        XCTAssertEqual(invocation.source, .automation)
        XCTAssertTrue(invocation.automationApprovedActions.contains("calendar.create_event"))
        XCTAssertFalse(invocation.automationApprovedActions.contains("gmail.trash"))
    }

    func testStoreClaimsOneScheduledOccurrenceOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexusAutomationClaimTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NexusAutomationStore(url: root.appendingPathComponent("automations.json"))
        let automationID = UUID()
        let occurrence = Date(timeIntervalSince1970: 1_786_000_000)
        let first = try await store.claimRun(automationID: automationID, scheduledFor: occurrence)
        let duplicate = try await store.claimRun(automationID: automationID, scheduledFor: occurrence)
        XCTAssertNotNil(first)
        XCTAssertNil(duplicate)
    }
}
