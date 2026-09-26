import Foundation

/// A typed identifier; `Tag` prevents mixing, for example, an asset ID with a layer ID.
public struct TypedID<Tag>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) { self.raw = raw }

    public var description: String { raw.uuidString }
}

public enum AssetTag {}
public enum LayerTag {}
public enum AnnotationTag {}
public enum MaskTag {}
public enum DocumentTag {}
public enum RequestTag {}
public enum CalloutTag {}

public typealias AssetID = TypedID<AssetTag>
public typealias LayerID = TypedID<LayerTag>
public typealias AnnotationID = TypedID<AnnotationTag>
public typealias MaskID = TypedID<MaskTag>
public typealias DocumentID = TypedID<DocumentTag>
public typealias RequestID = TypedID<RequestTag>
public typealias CalloutID = TypedID<CalloutTag>

/// Identity carried by every asynchronous result (OCR, render, capture, export).
///
/// A result is accepted only if its request was not canceled and the document's revision and
/// privacy epoch still match (SPEC.md §6, concurrency policy).
public struct RequestIdentity: Hashable, Sendable {
    public let requestID: RequestID
    public let documentID: DocumentID
    public let revision: UInt64
    public let privacyEpoch: UInt64

    public init(requestID: RequestID = RequestID(), documentID: DocumentID, revision: UInt64, privacyEpoch: UInt64) {
        self.requestID = requestID
        self.documentID = documentID
        self.revision = revision
        self.privacyEpoch = privacyEpoch
    }
}
