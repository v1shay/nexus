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

    func testStorePersistsAutomationAndRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexusAutomationTests-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("automations.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NexusAutomationStore(url: url)
        let automation = NexusAutomation(title: "Briefing", prompt: "Summarize my day", schedule: .init())
        try await store.save(automation)
        var run = NexusAutomationRun(automationID: automation.id, scheduledFor: .now, state: .completed)
        run.summary = "Good morning"
        try await store.saveRun(run)

        let restored = NexusAutomationStore(url: url)
        let automations = await restored.automations()
        let runs = await restored.runs(for: automation.id)
        XCTAssertEqual(automations.map(\.id), [automation.id])
        XCTAssertEqual(runs.first?.summary, "Good morning")
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
