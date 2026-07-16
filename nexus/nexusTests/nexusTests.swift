import XCTest
@testable import nexus

final class NexusGeometryTests: XCTestCase {
    func testDictationWingsPreserveThePhysicalNotchGap() {
        let physicalNotch = CGSize(width: 190, height: 32)
        let listening = NotchGeometry.listeningSize(for: physicalNotch)
        let regions = NotchGeometry.horizontalRegions(in: listening)

        XCTAssertEqual(listening.width, 314)
        XCTAssertEqual(regions.leftWing.width, 62)
        XCTAssertEqual(regions.notchGap.width, physicalNotch.width)
        XCTAssertEqual(regions.rightWing.width, 62)
        XCTAssertEqual(regions.leftWing.maxX, regions.notchGap.minX)
        XCTAssertEqual(regions.notchGap.maxX, regions.rightWing.minX)
        XCTAssertEqual(regions.rightWing.maxX, listening.width)
    }

    func testDictationReleaseSavesTextAndOpensOverlay() {
        var state = NotchInteractionState()
        state.beginDictation()
        state.updateTranscript("Send the project update")
        state.finishDictation()

        XCTAssertEqual(state.presentation, .overlay)
        XCTAssertEqual(state.transcript, "Send the project update")
    }

    func testEveryNotchFrameRemainsCenteredDuringExpansion() {
        let screen = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let closed = NotchGeometry.centeredTopFrame(
            for: CGSize(width: 190, height: 32),
            on: screen
        )
        let expanded = NotchGeometry.centeredTopFrame(
            for: CGSize(width: 680, height: 245),
            on: screen
        )

        XCTAssertEqual(closed.midX, screen.midX)
        XCTAssertEqual(expanded.midX, screen.midX)
        XCTAssertEqual(closed.maxY, screen.maxY)
        XCTAssertEqual(expanded.maxY, screen.maxY)
    }

    func testOllamaRegistryParserExtractsOfficialLibraryModels() {
        let html = #"<a href="/library/llama3.2"></a><a href="/library/qwen3"></a><a href="/download"></a>"#
        let identifiers = ModelCatalogService.matches(
            pattern: ##"href="/library/([^"#?]+)""##,
            in: html
        )

        XCTAssertEqual(identifiers, ["llama3.2", "qwen3"])
    }

    func testRAMRecommendationEstimateUnderstandsParameterTags() {
        XCTAssertEqual(ModelCatalog.estimatedMinimumRAM(for: "gemma3:12b"), 11)
        XCTAssertEqual(ModelCatalog.estimatedMinimumRAM(for: "model-without-size"), 0)
    }

    func testOnlyPreparationAndDownloadsAreActiveStates() {
        XCTAssertTrue(ModelDownloadState.preparing("Starting").isActive)
        XCTAssertTrue(ModelDownloadState.downloading(progress: 0.5, completedBytes: 50, totalBytes: 100, status: "pulling").isActive)
        XCTAssertFalse(ModelDownloadState.installed.isActive)
        XCTAssertFalse(ModelDownloadState.failed("failed").isActive)
    }
}
