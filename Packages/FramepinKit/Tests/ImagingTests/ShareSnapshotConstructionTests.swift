import Foundation
import Testing

/// FR-07: only the export pipeline may construct a ShareSnapshot. `ShareSnapshot.init` is
/// `package`-scoped, so this source scan guards code inside FramepinKit and the app target.
@Suite("ShareSnapshot is constructed only by the export pipeline")
struct ShareSnapshotConstructionTests {
    static let allowedFile = "Packages/FramepinKit/Sources/Imaging/ExportPipeline.swift"
    static let pattern = try? NSRegularExpression(
        pattern: #"ShareSnapshot\s*(\.\s*init\s*)?\(|\.init\s*\(\s*documentID\s*:"#)

    private static var repositoryRoot: URL {
        // .../Packages/FramepinKit/Tests/ImagingTests/<this file>
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func constructionSites(in source: String) -> Int {
        guard let pattern else { return 0 }
        return pattern.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
    }

    private func swiftFiles(under relativePath: String) -> [URL] {
        let root = Self.repositoryRoot.appendingPathComponent(relativePath)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test("The scanner recognizes construction spellings (planted control)")
    func scannerDetectsPlantedConstruction() throws {
        #expect(Self.pattern != nil)
        #expect(Self.constructionSites(in: "let s = ShareSnapshot(documentID: id, revision: 1)") == 1)
        #expect(Self.constructionSites(in: "let s = ShareSnapshot.init(documentID: id)") == 1)
        #expect(Self.constructionSites(in: "let s: ShareSnapshot = .init(documentID: id)") == 1)
        #expect(Self.constructionSites(in: "func write(_ snapshot: ShareSnapshot) {}") == 0)
    }

    @Test("No file other than the export pipeline constructs a ShareSnapshot")
    func onlyExportPipelineConstructs() throws {
        let root = Self.repositoryRoot
        let files = swiftFiles(under: "Packages/FramepinKit/Sources") + swiftFiles(under: "FramepinApp")
        #expect(files.count > 10, "scan found too few files; is the repository root right? \(root.path)")
        var allowedSites = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let sites = Self.constructionSites(in: source)
            let relative = String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            if relative == Self.allowedFile {
                allowedSites = sites
            } else {
                #expect(sites == 0, "\(relative) constructs a ShareSnapshot")
            }
        }
        #expect(allowedSites == 1, "the export pipeline must be the single construction site")
    }
}
