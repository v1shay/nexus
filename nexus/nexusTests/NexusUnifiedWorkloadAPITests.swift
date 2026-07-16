import CryptoKit
import Foundation
import XCTest
@testable import nexus

extension NexusGeometryTests {
    func testUnifiedAPIResumesUploadAndVerifiesRoundTripDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let client = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: client, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: client)
        }
        let policy = NexusExecutionPolicy(
            allowedCapabilities: Set(NexusCapability.allCases),
            roots: ["workspace": root],
            executables: [:]
        )
        let services = NexusHostServiceExecutor(nodeID: UUID(), policy: policy)
        let executor = NexusLocalWorkloadExecutor(services: services)
        let api = NexusUnifiedWorkloadAPI(executor: executor)
        let source = client.appendingPathComponent("source.bin")
        let downloaded = client.appendingPathComponent("downloaded.bin")
        let content = Data((0..<(900 * 1_024)).map { UInt8($0 % 251) })
        try content.write(to: source)
        let destination = NexusFileReference(rootID: "workspace", relativePath: "artifacts/model.bin")
        let transferID = UUID()

        // Simulate a prior connection that safely committed the first chunk but
        // disconnected before the Air saw the response.
        let first = content.prefix(97_321)
        let seed = NexusFileWritePayload(
            file: destination,
            transferID: transferID,
            offset: 0,
            data: Data(first),
            chunkSHA256: Data(SHA256.hash(data: first)),
            finalSize: Int64(content.count),
            finalSHA256: Data(SHA256.hash(data: content))
        )
        await services.execute(try NexusWorkloadRequest(
            kind: .fileWrite,
            priority: .background,
            retrySafety: .resumable,
            payload: seed
        )) { _ in }

        let progress = NexusTransferProgressCollector()
        try await api.uploadFile(from: source, to: destination, transferID: transferID) {
            await progress.append($0)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("artifacts/model.bin")), content)
        let finalProgress = await progress.last()
        XCTAssertEqual(finalProgress?.completedBytes, Int64(content.count))

        try await api.downloadFile(from: destination, to: downloaded, transferID: transferID)
        XCTAssertEqual(try Data(contentsOf: downloaded), content)
    }

    func testHostSchedulerReservesInteractiveCapacityWhileBulkWorkWaits() async throws {
        let scheduler = NexusHostWorkloadScheduler(maximumActive: 2, maximumBulk: 1)
        let firstBulk = try await scheduler.acquire(kind: .modelPull, priority: .background)
        let waitingBulk = Task {
            try await scheduler.acquire(kind: .download, priority: .background)
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        let interactive = try await scheduler.acquire(kind: .health, priority: .interactive)
        let occupied = await scheduler.snapshot()
        XCTAssertEqual(occupied.active, 2)
        XCTAssertEqual(occupied.queued, 1)

        await scheduler.release(interactive)
        await scheduler.release(firstBulk)
        let secondBulk = try await waitingBulk.value
        await scheduler.release(secondBulk)
        let empty = await scheduler.snapshot()
        XCTAssertEqual(empty.active, 0)
        XCTAssertEqual(empty.queued, 0)
    }

    func testResumableTransferRejectsSymlinkedInternalFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("artifacts"), withIntermediateDirectories: true)
        try Data("unchanged".utf8).write(to: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let transferID = UUID()
        let destination = NexusFileReference(rootID: "workspace", relativePath: "artifacts/model.bin")
        let partial = root.appendingPathComponent(
            "artifacts/.model.bin.\(transferID.uuidString.lowercased()).nexus-part"
        )
        try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: outside)
        let policy = NexusExecutionPolicy(
            allowedCapabilities: [.fileWrite],
            roots: ["workspace": root],
            executables: [:]
        )
        let services = NexusHostServiceExecutor(nodeID: UUID(), policy: policy)
        let events = NexusUnifiedEventCollector()
        let data = Data("malicious overwrite".utf8)
        let payload = NexusFileWritePayload(
            file: destination,
            transferID: transferID,
            offset: 0,
            data: data,
            chunkSHA256: Data(SHA256.hash(data: data)),
            finalSize: Int64(data.count),
            finalSHA256: Data(SHA256.hash(data: data))
        )

        await services.execute(try NexusWorkloadRequest(
            kind: .fileWrite,
            retrySafety: .resumable,
            payload: payload
        )) { await events.append($0) }

        let failure = await events.first(kind: .failed)
        XCTAssertNotNil(failure)
        XCTAssertEqual(try Data(contentsOf: outside), Data("unchanged".utf8))
    }

    func testUnifiedProcessApprovalIsShortLivedSingleUseAndNeverAllowsAShell() async throws {
        let policy = NexusExecutionPolicy(
            allowedCapabilities: [.process],
            roots: [:],
            executables: [
                "true": .init(executableURL: URL(fileURLWithPath: "/usr/bin/true")),
                "zsh": .init(executableURL: URL(fileURLWithPath: "/bin/zsh"), requiresApproval: false)
            ]
        )
        let services = NexusHostServiceExecutor(nodeID: UUID(), policy: policy)
        let api = NexusUnifiedWorkloadAPI(executor: NexusLocalWorkloadExecutor(services: services))
        let approval = try await api.requestProcessApproval(executableID: "true", validFor: 30)
        let payload = NexusProcessPayload(
            executableID: "true",
            arguments: [],
            environment: [:],
            workingDirectory: nil,
            timeoutSeconds: 5,
            maximumOutputBytes: 1_024,
            approvalToken: approval.token
        )

        let result = try await api.runApprovedProcess(payload)
        XCTAssertEqual(result.exitCode, 0)
        do {
            _ = try await api.runApprovedProcess(payload)
            XCTFail("A process approval token must be consumed exactly once")
        } catch {}
        do {
            _ = try await api.requestProcessApproval(executableID: "zsh")
            XCTFail("Shell interpreters must never receive approval tokens")
        } catch {}
    }
}

private actor NexusTransferProgressCollector {
    private var values: [NexusTransferProgress] = []
    func append(_ progress: NexusTransferProgress) { values.append(progress) }
    func last() -> NexusTransferProgress? { values.last }
}

private actor NexusUnifiedEventCollector {
    private var values: [NexusWorkloadEvent] = []
    func append(_ event: NexusWorkloadEvent) { values.append(event) }
    func first(kind: NexusWorkloadEventKind) -> NexusWorkloadEvent? { values.first { $0.kind == kind } }
}
