import Domain
import Foundation
import Imaging
import Testing

@testable import Features

// Failure modes (FR-03, IO-01): unreadable/oversized file, empty pasteboard, each decoder
// rejection, a clipboard read without an explicit Paste, and import depending on screen access.
@MainActor
final class ImportHarness {
    let input = FakeImageInput()
    let assets = FakeAssetService()
    let permission = FakeScreenPermission(isGranted: false)
    let coordinator: ImportCoordinator
    var imported: [DocumentSession] = []

    init() {
        coordinator = ImportCoordinator(input: input, assets: assets)
        coordinator.onImported = { [unowned self] in self.imported.append($0) }
    }
}

@Suite("ImportCoordinator (FR-03, IO-01, PERM-01)")
@MainActor
struct ImportCoordinatorTests {
    let file = URL(fileURLWithPath: "/tmp/framepin-tests/fixture.png")

    @Test("Opening a file creates a new document session without screen permission")
    func openFile() async throws {
        let h = ImportHarness()
        h.input.files[file] = .success(Data(repeating: 1, count: 32))
        let session = try await h.coordinator.importImage(from: .file(file)).get()
        #expect(session.document.layers.count == 1)
        #expect(h.assets.imported.first?.origin == .imported)
        #expect(h.imported.count == 1)
        #expect(h.input.pasteboardReads == 0)
        #expect(h.permission.requestCount == 0)
    }

    @Test("Paste reads the clipboard exactly once, only on request")
    func paste() async throws {
        let h = ImportHarness()
        #expect(h.input.pasteboardReads == 0)
        h.input.pasteboardData = Data(repeating: 2, count: 16)
        _ = try await h.coordinator.importImage(from: .pasteboard).get()
        #expect(h.input.pasteboardReads == 1)
        #expect(h.assets.imported.first?.origin == .pasted)
    }

    @Test("An empty clipboard is a typed, user-presentable error")
    func emptyPasteboard() async {
        let h = ImportHarness()
        let result = await h.coordinator.importImage(from: .pasteboard)
        #expect(result.failureValue == .nothingToPaste)
        #expect(h.coordinator.lastFailure == .nothingToPaste)
        #expect(h.imported.isEmpty)
    }

    @Test("Dropped data and dropped files import without touching the clipboard")
    func drop() async throws {
        let h = ImportHarness()
        h.input.files[file] = .success(Data([1, 2, 3]))
        _ = try await h.coordinator.importImage(from: .droppedFile(file)).get()
        _ = try await h.coordinator.importImage(from: .droppedData(Data([4, 5]))).get()
        #expect(h.imported.count == 2)
        #expect(h.input.pasteboardReads == 0)
    }

    @Test(
        "Reader and decoder errors map to import failures",
        arguments: [
            (ImportError.tooManyBytes, ImportFailure.tooLarge),
            (.tooManyPixels, .tooManyPixels),
            (.invalidDimensions, .invalidDimensions),
            (.unsupportedFormat, .unsupportedFormat),
            (.multiFrame, .multipleFrames),
            (.corrupt, .corrupt),
            (.unreadable, .unreadable),
        ])
    func errorMapping(error: ImportError, expected: ImportFailure) async {
        let reader = ImportHarness()
        reader.input.files[file] = .failure(error)
        #expect(await reader.coordinator.importImage(from: .file(file)).failureValue == expected)

        let decoder = ImportHarness()
        decoder.assets.importError = error
        #expect(await decoder.coordinator.importImage(from: .droppedData(Data([0]))).failureValue == expected)
        #expect(decoder.imported.isEmpty)
    }

    @Test("A successful import clears the previous failure")
    func clearsFailure() async throws {
        let h = ImportHarness()
        _ = await h.coordinator.importImage(from: .pasteboard)
        #expect(h.coordinator.lastFailure != nil)
        _ = try await h.coordinator.importImage(from: .droppedData(Data([1]))).get()
        #expect(h.coordinator.lastFailure == nil)
    }
}

@Suite("Support models")
@MainActor
struct SupportModelTests {
    @Test("Login item reflects the service and reports failures without claiming success")
    func loginItem() {
        let service = FakeLoginItem()
        let model = LoginItemModel(service: service)
        #expect(model.isEnabled == false)
        model.setEnabled(true)
        #expect(model.isEnabled)
        #expect(model.lastErrorOccurred == false)

        service.error = TestError()
        model.setEnabled(false)
        #expect(model.isEnabled)  // still what the system reports
        #expect(model.lastErrorOccurred)
    }

    @Test("OCR languages are loaded from the service, never assumed")
    func ocrLanguages() async {
        let service = FakeTextRecognition()
        let model = OCRLanguagesModel(service: service)
        #expect(model.state == .notLoaded)
        await model.load()
        #expect(model.state == .loaded([Locale.Language(identifier: "en-US"), Locale.Language(identifier: "pt-BR")]))

        service.languages = []
        await model.load()
        #expect(model.state == .unavailable)
    }

    @Test("Shortcut registration failures are tracked per name")
    func shortcutStatus() {
        let probe = FakeShortcutProbe()
        let model = ShortcutStatusModel(probe: probe)
        probe.failing = ["captureRegion"]
        model.shortcutChanged(named: "captureRegion", isAssigned: true)
        model.shortcutChanged(named: "captureWindow", isAssigned: true)
        #expect(model.failedNames == ["captureRegion"])

        model.shortcutChanged(named: "captureRegion", isAssigned: false)
        #expect(model.failedNames.isEmpty)
    }
}
