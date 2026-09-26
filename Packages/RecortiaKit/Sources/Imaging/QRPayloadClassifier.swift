import Foundation

/// Conservative classification of QR payload bytes (FR-08). The kind only labels untrusted data
/// for display; nothing here opens, fetches, or acts on it.
package enum QRPayloadClassifier {
    /// URI schemes whose purpose is to request a payment.
    static let paymentSchemes: Set<String> = [
        "bitcoin", "bitcoincash", "litecoin", "dogecoin", "ethereum", "monero", "zcash", "lightning", "upi", "payto",
    ]

    package static func classify(_ bytes: Data) -> QRPayload {
        guard let string = String(validating: bytes, as: UTF8.self) else {
            return QRPayload(bytes: bytes, string: nil, kind: .binary)
        }
        return QRPayload(bytes: bytes, string: string, kind: kind(of: string))
    }

    static func kind(of string: String) -> QRPayload.Kind {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.prefix(5).lowercased() == "wifi:" { return .wifi }
        // EMV merchant-presented codes (including Pix / BR Code) begin with payload format "01".
        if trimmed.hasPrefix("000201") { return .payment }
        guard let scheme = scheme(of: trimmed) else { return .text }
        if paymentSchemes.contains(scheme) { return .payment }
        if (scheme == "http" || scheme == "https"), let url = webURL(string) { return .webURL(url) }
        return .otherScheme(scheme)
    }

    /// A web URL only when the exact payload is an absolute http(s) URL with a host and no user
    /// info (which disguises the real host), with no whitespace or control characters and no
    /// normalization by `URL`.
    private static func webURL(_ string: String) -> URL? {
        guard
            !string.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }),
            let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host(percentEncoded: true), !host.isEmpty, url.absoluteString == string,
            url.user(percentEncoded: true) == nil, url.password(percentEncoded: true) == nil
        else { return nil }
        return url
    }

    /// RFC 3986 scheme: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) followed by ":", lowercased.
    static func scheme(of string: String) -> String? {
        guard let colon = string.firstIndex(of: ":") else { return nil }
        let candidate = string[..<colon].unicodeScalars
        guard let first = candidate.first, first.isASCII, CharacterSet.letters.contains(first) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.")
        guard candidate.allSatisfy({ allowed.contains($0) }) else { return nil }
        return String(String.UnicodeScalarView(candidate)).lowercased()
    }
}
