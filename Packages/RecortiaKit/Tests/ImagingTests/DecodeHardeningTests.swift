import CoreGraphics
import Domain
import Foundation
import ImageIO
import RecortiaFixtures
import Testing
import UniformTypeIdentifiers

@testable import Imaging

@Suite("IO-01: container hardening")
struct DecodeHardeningTests {
    /// Filtered scanlines of a 4x4 RGBA image, all rows filter type 0.
    private static func rawRows() -> Data {
        var raw = Data()
        for _ in 0..<4 {
            raw.append(0)
            raw.append(contentsOf: [UInt8](repeating: 200, count: 16))
        }
        return raw
    }

    /// A 4x4 RGBA PNG whose zlib stream is split over `idat` chunks, with `extra` chunks before them.
    private static func png(extra: [[UInt8]] = [], idat: [[UInt8]]) -> Data {
        var bytes = ContainerCrafting.pngSignature
        bytes += ContainerCrafting.pngChunk(
            "IHDR", ContainerCrafting.bigEndian32(4) + ContainerCrafting.bigEndian32(4) + [8, 6, 0, 0, 0])
        for chunk in extra { bytes += chunk }
        for payload in idat { bytes += ContainerCrafting.pngChunk("IDAT", payload) }
        bytes += ContainerCrafting.pngChunk("IEND", [])
        return Data(bytes)
    }

    @Test("A PNG carrying Apple's private iDOT chunk decodes only from the validated IDAT stream")
    func iDOTIsStrippedBeforeDecode() throws {
        let stream = try ContainerCrafting.zlibStream(Self.rawRows())
        let half = stream.count / 2
        let halves = [Array(stream[..<half]), Array(stream[half...])]
        let control = try ImageDecoder.decode(Self.png(idat: halves))
        #expect(control.pixelSize == PixelSize(width: 4, height: 4))

        // macOS screenshots carry iDOT, so it must not make an ordinary PNG unreadable. It lets
        // ImageIO inflate IDAT segments in parallel from stored offsets; the offset here points at
        // the second IDAT, and a hostile one could point anywhere, so ImageIO never sees the chunk.
        let big = ContainerCrafting.bigEndian32
        let payload = big(2) + big(0) + big(2) + big(0x28) + big(2) + big(2) + big(40 + 12 + UInt32(half))
        let withIDOT = Self.png(extra: [ContainerCrafting.pngChunk("iDOT", payload)], idat: halves)
        let layout = try DecodePNGStructure.layout(withIDOT)
        let decodable = DecodePNGStructure.decodableBytes(withIDOT, layout: layout)
        #expect(decodable.range(of: Data("iDOT".utf8)) == nil)
        #expect(decodable.count == withIDOT.count - (12 + payload.count))
        let decoded = try ImageDecoder.decode(withIDOT)
        #expect(decoded.pixelSize == control.pixelSize)
        let decodedBytes = decoded.image.dataProvider?.data as Data?
        let controlBytes = control.image.dataProvider?.data as Data?
        #expect(decodedBytes != nil && decodedBytes == controlBytes, "pixels come from the validated stream")
    }

    @Test("The IDAT chunk count is capped: the limit parses, one more chunk is rejected")
    func idatChunkCountIsCapped() throws {
        let stream = try ContainerCrafting.zlibStream(Self.rawRows())
        let limit = DecodePNGStructure.maxImageDataChunks
        #expect(limit == 65_536)
        // Zero-length IDAT chunks are legal; they only add chunk-walk work.
        let empties = [[UInt8]](repeating: [], count: limit - 1)
        let atLimit = Self.png(idat: [Array(stream)] + empties)
        #expect(try DecodePNGStructure.layout(atLimit).imageData.count == limit)
        let overLimit = Self.png(idat: [Array(stream)] + empties + [[]])
        #expect(throws: ImportError.corrupt) { try DecodePNGStructure.layout(overLimit) }
        #expect(throws: ImportError.corrupt) { try ImageDecoder.decode(overLimit) }
    }

    /// Inserts a copy of the first SOFn segment right after it.
    private static func duplicatingFirstSOF(_ jpeg: Data) throws -> Data {
        let bytes = [UInt8](jpeg)
        var offset = 2
        while offset + 4 <= bytes.count, bytes[offset] == 0xFF {
            let marker = bytes[offset + 1]
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let end = offset + 2 + length
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                let segment = Array(bytes[offset..<end])
                return Data(Array(bytes[..<end]) + segment + Array(bytes[end...]))
            }
            if marker == 0xDA { break }
            offset = end
        }
        throw FixtureError.invalidArgument
    }

    @Test("A JPEG with a second SOFn before SOS is corrupt; the header walk does not stop at the first")
    func secondSOFIsRejected() throws {
        let jpeg = try ContainerCrafting.jpegData(try ChartFixture.geometryChart(width: 32, height: 16))
        #expect(try DecodeJPEGStructure.header(jpeg).pixelSize == PixelSize(width: 32, height: 16))
        let twoFrames = try Self.duplicatingFirstSOF(jpeg)
        #expect(twoFrames.count > jpeg.count)
        #expect(throws: ImportError.corrupt) { try DecodeJPEGStructure.header(twoFrames) }
        #expect(throws: ImportError.corrupt) { try ImageDecoder.decode(twoFrames) }
    }

    /// The first `marker` segment (marker through its declared length) of `jpeg`.
    private static func firstSegment(_ jpeg: [UInt8], marker target: UInt8) throws -> [UInt8] {
        var offset = 2
        while offset + 4 <= jpeg.count, jpeg[offset] == 0xFF {
            let marker = jpeg[offset + 1]
            let end = offset + 2 + (Int(jpeg[offset + 2]) << 8 | Int(jpeg[offset + 3]))
            if marker == target
                || (target == 0xC0 && (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker))
            {
                return Array(jpeg[offset..<end])
            }
            if marker == 0xDA { break }
            offset = end
        }
        throw FixtureError.invalidArgument
    }

    /// `jpeg` with `segment` inserted `copies` times just before its EOI marker.
    private static func insertingBeforeEOI(_ jpeg: Data, _ segment: [UInt8], copies: Int = 1) -> Data {
        var bytes = [UInt8](jpeg)
        precondition(bytes.suffix(2) == [0xFF, 0xD9])
        bytes.insert(contentsOf: Array([[UInt8]](repeating: segment, count: copies).joined()), at: bytes.count - 2)
        return Data(bytes)
    }

    // Hardening (security run-2): the walk stopped at the first scan, so a frame header after it
    // went unseen, and scan count (progressive decode cost) was unbounded.
    @Test("A JPEG with a frame header after its first scan is corrupt")
    func sofAfterScanIsRejected() throws {
        let jpeg = try ContainerCrafting.jpegData(try ChartFixture.geometryChart(width: 32, height: 16))
        let sof = try Self.firstSegment([UInt8](jpeg), marker: 0xC0)
        let late = Self.insertingBeforeEOI(jpeg, sof)
        #expect(throws: ImportError.corrupt) { try DecodeJPEGStructure.header(late) }
    }

    @Test("The scan count is capped: the limit parses, one more scan is rejected")
    func scanCountIsCapped() throws {
        let jpeg = try ContainerCrafting.jpegData(try ChartFixture.geometryChart(width: 32, height: 16))
        let sos = try Self.firstSegment([UInt8](jpeg), marker: 0xDA)
        let limit = DecodeJPEGStructure.maxScans
        let atLimit = Self.insertingBeforeEOI(jpeg, sos, copies: limit - 1)
        #expect(try DecodeJPEGStructure.header(atLimit).pixelSize == PixelSize(width: 32, height: 16))
        let overLimit = Self.insertingBeforeEOI(jpeg, sos, copies: limit)
        #expect(throws: ImportError.corrupt) { try DecodeJPEGStructure.header(overLimit) }
    }

    @Test("Control: a progressive JPEG with many scans decodes")
    func progressiveJPEGDecodes() throws {
        let image = try ChartFixture.geometryChart(width: 64, height: 48)
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, image,
            [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let bytes = [UInt8](data as Data)
        let scans = zip(bytes, bytes.dropFirst()).filter { $0 == 0xFF && $1 == 0xDA }.count
        #expect(scans > 1, "control must be progressive")
        #expect(try ImageDecoder.decode(data as Data).pixelSize == PixelSize(width: 64, height: 48))
    }

    // By design (FR-03, verify round 4): Paste reads a TIFF-only clipboard so that the importer can
    // refuse it with an explicit reason; TIFF is never decoded.
    @Test("TIFF data, as a TIFF-only clipboard supplies it, is refused as an unsupported format")
    func tiffIsUnsupported() throws {
        let image = try ChartFixture.geometryChart(width: 32, height: 16)
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(throws: ImportError.unsupportedFormat) { try ImageDecoder.decode(data as Data) }
    }

    @Test("A JPEG that reaches SOS without any SOFn is corrupt")
    func sosWithoutSOFIsRejected() {
        // SOI, then SOS straight away.
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFF, 0xD9]
        #expect(throws: ImportError.corrupt) { try DecodeJPEGStructure.header(Data(bytes)) }
    }
}
