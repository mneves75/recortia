import CryptoKit
import Domain
import Foundation
import Synchronization

struct GitHubResponse: Sendable {
    let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

protocol GitHubTransport: Sendable {
    /// Sends `request` only if `mayStart`, checked as the last step before the request is handed
    /// to the network, still allows it; otherwise throws `GitHubUploadFailure.staleDocument`
    /// having sent nothing.
    func send(_ request: URLRequest, mayStart: @escaping @MainActor @Sendable () -> Bool) async throws
        -> GitHubResponse
}

/// A session that creates request tasks; the app uses an ephemeral URLSession, tests a recorder.
protocol GitHubSession: Sendable {
    /// Creates, without starting, a task for `request` that reports to `collector`.
    func task(for request: URLRequest, collector: GitHubResponseCollector) -> any GitHubSessionTask
    /// Ends the session and cancels anything still running.
    func finish()
}

protocol GitHubSessionTask: Sendable {
    func resume()
    func cancel()
}

extension URLSession: GitHubSession {
    func task(for request: URLRequest, collector: GitHubResponseCollector) -> any GitHubSessionTask {
        let task = dataTask(with: request)
        // A per-task delegate, set before the task starts, receives its response and data.
        task.delegate = collector
        return task
    }

    func finish() { invalidateAndCancel() }
}

extension URLSessionDataTask: GitHubSessionTask {}

/// GitHub.com only. Never follows redirects, stores cookies, caches credentials, or writes
/// request/response content to disk. Bounds response bodies before retaining them.
struct GitHubURLTransport: GitHubTransport {
    private let makeSession: @Sendable () -> any GitHubSession

    public init() {
        self.init(makeSession: { Self.ephemeralSession() })
    }

    init(makeSession: @escaping @Sendable () -> any GitHubSession) {
        self.makeSession = makeSession
    }

    private static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: NoGitHubRedirects(), delegateQueue: nil)
    }

    @concurrent
    public func send(_ request: URLRequest, mayStart: @escaping @MainActor @Sendable () -> Bool) async throws
        -> GitHubResponse
    {
        guard request.url?.scheme == "https", request.url?.host == "api.github.com",
            request.url?.user == nil, request.url?.password == nil, request.url?.port == nil
        else { throw GitHubUploadFailure.invalidDestination }
        try Task.checkCancellation()
        let session = makeSession()
        defer { session.finish() }
        let collector = GitHubResponseCollector(limit: GitHubUploader.maximumResponseBytes)
        // NET-01's boundary is the request handed to URLSession. The consent check (which also
        // marks a PUT committed) and the creation and start of the task are one main-actor step:
        // a revocation processed before it stops the request, and one processed after it finds the
        // request already started.
        // A cancellation that arrived while waiting for the main actor is honored in that step too.
        let started: Result<any GitHubSessionTask, any Error> = await MainActor.run {
            guard !Task.isCancelled else { return .failure(CancellationError()) }
            guard mayStart() else { return .failure(GitHubUploadFailure.staleDocument) }
            let task = session.task(for: request, collector: collector)
            task.resume()
            return .success(task)
        }
        let task = try started.get()
        return try await withTaskCancellationHandler {
            try await collector.response()
        } onCancel: {
            task.cancel()
        }
    }
}

/// Collects one task's response, refusing a body over `limit` bytes by canceling the task.
final class GitHubResponseCollector: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var statusCode: Int?
        var body = Data()
        var failure: (any Error)?
        var result: Result<GitHubResponse, any Error>?
        var waiter: CheckedContinuation<GitHubResponse, any Error>?
    }

    private let state = Mutex(State())
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func receive(response: URLResponse) {
        state.withLock { $0.statusCode = (response as? HTTPURLResponse)?.statusCode }
    }

    func receive(data: Data, cancel: () -> Void) {
        let exceeded = state.withLock { state -> Bool in
            guard state.failure == nil else { return false }
            guard state.body.count + data.count <= limit else {
                state.failure = GitHubUploadFailure.invalidResponse
                state.body = Data()
                return true
            }
            state.body.append(data)
            return false
        }
        if exceeded { cancel() }
    }

    func complete(error: (any Error)?) {
        let resolved = state.withLock {
            state -> (CheckedContinuation<GitHubResponse, any Error>, Result<GitHubResponse, any Error>)? in
            guard state.result == nil else { return nil }
            let result: Result<GitHubResponse, any Error> =
                if let failure = state.failure {
                    .failure(failure)
                } else if let error {
                    .failure(error)
                } else if let statusCode = state.statusCode {
                    .success(GitHubResponse(statusCode: statusCode, body: state.body))
                } else {
                    .failure(GitHubUploadFailure.invalidResponse)
                }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter.map { ($0, result) }
        }
        if let (waiter, result) = resolved { waiter.resume(with: result) }
    }

    /// The task's response once it completes.
    func response() async throws -> GitHubResponse {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<GitHubResponse, any Error>? in
                if let result = state.result { return result }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        receive(response: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receive(data: data, cancel: { dataTask.cancel() })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        complete(error: error)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
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
    static let maximumImageBytes = 8 * 1024 * 1024
    // Contents metadata can inline base64 for files up to 1 MiB, even with object media.
    static let maximumResponseBytes = 2 * 1024 * 1024
    private let transport: any GitHubTransport

    public init() {
        self.init(transport: GitHubURLTransport())
    }

    /// Tests inject a scripted transport; the app always uses `GitHubURLTransport`.
    init(transport: any GitHubTransport) {
        self.transport = transport
    }

    @concurrent
    public func upload(
        _ snapshot: ShareSnapshot, to destination: GitHubDestination, token: GitHubToken, intent: UUID,
        isLive: @escaping @MainActor @Sendable () -> Bool,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws(GitHubUploadFailure) -> URL {
        guard destination.isValid else { throw .invalidDestination }
        guard !snapshot.bytes.isEmpty, snapshot.bytes.count <= Self.maximumImageBytes else { throw .tooLarge }
        guard !Task.isCancelled else { throw .canceled }
        let base = "https://api.github.com/repos/\(destination.owner)/\(destination.repository)"
        // No authenticated request, lookups included, once the consent behind it is gone: the
        // transport checks `isLive` (and `isCurrent` for the image) just before sending.
        let repoResponse = try await send(try request(base, token: token), mayStart: isLive)
        try checkStatus(repoResponse, expected: [200])
        let repository: Repository = try decode(repoResponse.body)
        guard repository.full_name.lowercased() == "\(destination.owner)/\(destination.repository)".lowercased(),
            !repository.archived
        else { throw .invalidResponse }
        guard repository.private else { throw .publicRepository }
        let path = "screenshots/\(intent.uuidString.lowercased()).\(snapshot.format.fileExtension)"
        let contentsURL = "\(base)/contents/\(path)"
        var lookup = try request(contentsURL, token: token)
        lookup.setValue("application/vnd.github.object+json", forHTTPHeaderField: "Accept")
        guard !Task.isCancelled else { throw .canceled }
        let existing = try await send(lookup, mayStart: isLive)
        let sha = Self.blobSHA(snapshot.bytes)
        if existing.statusCode == 200 {
            let file: File = try decode(existing.body)
            guard file.type == "file", file.sha == sha else { throw .conflict }
            guard !Task.isCancelled else { throw .canceled }
            guard await isCurrent() else { throw .staleDocument }
            return try link(to: destination, path: path)
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
        let response = try await send(put, committing: true, mayStart: isCurrent)
        try checkStatus(response, expected: [201], committing: true)
        let result: Created = try decode(response.body, committing: true)
        guard result.content.sha == sha else { throw .completionUnknown }
        do { return try link(to: destination, path: path) } catch { throw .completionUnknown }
    }

    /// Git's blob identifier, not an authentication or integrity security primitive.
    static func blobSHA(_ bytes: Data) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(bytes.count)\0".utf8))
        hash.update(data: bytes)
        return hash.finalize().map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    private func request(_ address: String, token: GitHubToken) throws(GitHubUploadFailure) -> URLRequest {
        guard let url = URL(string: address) else { throw .invalidDestination }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Recortia", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func send(
        _ request: URLRequest, committing: Bool = false, mayStart: @escaping @MainActor @Sendable () -> Bool
    ) async throws(GitHubUploadFailure) -> GitHubResponse {
        do {
            let response = try await transport.send(request, mayStart: mayStart)
            guard response.body.count <= Self.maximumResponseBytes else {
                throw GitHubUploadFailure.invalidResponse
            }
            return response
        } catch {
            // Refused before sending: nothing reached GitHub, even for the image.
            if error as? GitHubUploadFailure == .staleDocument { throw .staleDocument }
            // The transport reports cancellation before the handoff as CancellationError: no task
            // existed, so even a PUT is canceled, not of unknown completion. Cancellation after the
            // handoff surfaces as the task's own error.
            if error is CancellationError { throw .canceled }
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

    /// The file's page on github.com, built only from the admitted destination and the generated
    /// path; HEAD is the default branch the upload commits to. Nothing from a response reaches it,
    /// so a responder cannot put the token, or anything else, in the link the editor offers.
    private func link(to destination: GitHubDestination, path: String) throws(GitHubUploadFailure) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        // Each segment is percent-encoded by URLComponents; the destination is validated already.
        components.path =
            "/"
            + ([destination.owner, destination.repository, "blob", "HEAD"] + path.split(separator: "/").map(String.init))
            .joined(separator: "/")
        guard let url = components.url else { throw .invalidDestination }
        return url
    }

    private struct Repository: Decodable { let `private`: Bool; let archived: Bool; let full_name: String }
    /// The response's own links are not decoded; see `link(to:path:)`.
    private struct File: Decodable { let sha: String; let type: String? }
    private struct Created: Decodable { let content: File }
    private struct Payload: Encodable { let message: String; let content: String }
}
