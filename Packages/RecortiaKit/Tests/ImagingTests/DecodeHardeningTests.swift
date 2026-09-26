import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

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

    @Test("A JPEG that reaches SOS without any SOFn is corrupt")
    func sosWithoutSOFIsRejected() {
        // SOI, then SOS straight away.
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFF, 0xD9]
        #expect(throws: ImportError.corrupt) { try DecodeJPEGStructure.header(Data(bytes)) }
    }
}
