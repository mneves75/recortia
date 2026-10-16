import CryptoKit
import Domain
import Foundation

public struct GitHubResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol GitHubTransport: Sendable {
    func send(_ request: URLRequest) async throws -> GitHubResponse
}

/// GitHub.com only. Never follows redirects, stores cookies, caches credentials, or writes
/// request/response content to disk. Bounds response bodies before retaining them.
public struct GitHubURLTransport: GitHubTransport {
    public init() {}

    @concurrent
    public func send(_ request: URLRequest) async throws -> GitHubResponse {
        guard request.url?.scheme == "https", request.url?.host == "api.github.com",
            request.url?.user == nil, request.url?.password == nil, request.url?.port == nil
        else { throw GitHubUploadFailure.invalidDestination }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: NoGitHubRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubUploadFailure.invalidResponse }
        var body = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard body.count < GitHubUploader.maximumResponseBytes else { throw GitHubUploadFailure.invalidResponse }
            body.append(byte)
        }
        return GitHubResponse(statusCode: http.statusCode, body: body)
    }
}

final class NoGitHubRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// One immutable ShareSnapshot and one UUID per approved intent. Retrying that intent checks
/// the existing Git blob instead of overwriting it. There are no automatic retries after PUT.
public struct GitHubUploader: Sendable {
    public static let maximumImageBytes = 8 * 1024 * 1024
    // Contents metadata can inline base64 for files up to 1 MiB, even with object media.
    public static let maximumResponseBytes = 2 * 1024 * 1024
    private let transport: any GitHubTransport

    public init(transport: any GitHubTransport = GitHubURLTransport()) {
        self.transport = transport
    }

    @concurrent
    public func upload(
        _ snapshot: ShareSnapshot, to destination: GitHubDestination, token: String, intent: UUID,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws(GitHubUploadFailure) -> URL {
        guard destination.isValid else { throw .invalidDestination }
        guard !token.isEmpty, token.utf8.count <= 4096,
            token.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw .missingCredential }
        guard !snapshot.bytes.isEmpty, snapshot.bytes.count <= Self.maximumImageBytes else { throw .tooLarge }
        guard !Task.isCancelled else { throw .canceled }
        let base = "https://api.github.com/repos/\(destination.owner)/\(destination.repository)"
        let repoResponse = try await send(try request(base, token: token))
        try checkStatus(repoResponse, expected: [200])
        let repository: Repository = try decode(repoResponse.body)
        guard repository.full_name.lowercased() == "\(destination.owner)/\(destination.repository)".lowercased(),
            !repository.archived
        else { throw .invalidResponse }
        guard repository.private else { throw .publicRepository }
        let ext = snapshot.format == .png ? "png" : "jpg"
        let path = "screenshots/\(intent.uuidString.lowercased()).\(ext)"
        let contentsURL = "\(base)/contents/\(path)"
        var lookup = try request(contentsURL, token: token)
        lookup.setValue("application/vnd.github.object+json", forHTTPHeaderField: "Accept")
        let existing = try await send(lookup)
        let sha = Self.blobSHA(snapshot.bytes)
        if existing.statusCode == 200 {
            let file: File = try decode(existing.body)
            guard file.type == "file", file.sha == sha else { throw .conflict }
            guard !Task.isCancelled else { throw .canceled }
            guard await isCurrent() else { throw .staleDocument }
            return try validatedLink(file.html_url, destination: destination, path: path)
        }
        try checkStatus(existing, expected: [404])
        var put = try request(contentsURL, token: token)
        put.httpMethod = "PUT"
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            put.httpBody = try JSONEncoder().encode(
                Payload(message: "Recortia screenshot", content: snapshot.bytes.base64EncodedString()))
        } catch { throw .invalidResponse }
        // All encoding and preparatory awaits precede the final consent/freshness check.
        guard !Task.isCancelled else { throw .canceled }
        guard await isCurrent() else { throw .staleDocument }
        let response = try await send(put, committing: true)
        try checkStatus(response, expected: [201], committing: true)
        let result: Created = try decode(response.body, committing: true)
        guard result.content.sha == sha else { throw .completionUnknown }
        do { return try validatedLink(result.content.html_url, destination: destination, path: path) } catch {
            throw .completionUnknown
        }
    }

    /// Git's blob identifier, not an authentication or integrity security primitive.
    static func blobSHA(_ bytes: Data) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(bytes.count)\0".utf8))
        hash.update(data: bytes)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func request(_ address: String, token: String) throws(GitHubUploadFailure) -> URLRequest {
        guard let url = URL(string: address) else { throw .invalidDestination }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Recortia", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func send(_ request: URLRequest, committing: Bool = false) async throws(GitHubUploadFailure)
        -> GitHubResponse
    {
        do {
            let response = try await transport.send(request)
            guard response.body.count <= Self.maximumResponseBytes else {
                throw GitHubUploadFailure.invalidResponse
            }
            return response
        } catch {
            if committing { throw .completionUnknown }
            if Task.isCancelled || error is CancellationError { throw .canceled }
            throw (error as? GitHubUploadFailure) ?? .network
        }
    }

    private func checkStatus(_ response: GitHubResponse, expected: Set<Int>, committing: Bool = false)
        throws(GitHubUploadFailure)
    {
        if expected.contains(response.statusCode) { return }
        switch response.statusCode {
        case 401, 403, 404: throw .accessDenied
        case 429: throw .rateLimited
        case 409, 422: throw .conflict
        default: throw committing ? .completionUnknown : .invalidResponse
        }
    }

    private func decode<Value: Decodable>(_ data: Data, committing: Bool = false) throws(GitHubUploadFailure) -> Value {
        do { return try JSONDecoder().decode(Value.self, from: data) } catch {
            throw committing ? .completionUnknown : .invalidResponse
        }
    }

    private func validatedLink(_ address: String, destination: GitHubDestination, path: String)
        throws(GitHubUploadFailure) -> URL
    {
        guard let url = URL(string: address), url.scheme == "https", url.host == "github.com",
            url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
            url.path.lowercased().hasPrefix("/\(destination.owner)/\(destination.repository)/blob/".lowercased()),
            url.path.hasSuffix("/\(path)")
        else { throw .invalidResponse }
        return url
    }

    private struct Repository: Decodable { let `private`: Bool; let archived: Bool; let full_name: String }
    private struct File: Decodable { let sha: String; let html_url: String; let type: String? }
    private struct Created: Decodable { let content: File }
    private struct Payload: Encodable { let message: String; let content: String }
}
