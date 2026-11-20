import CryptoKit
import Domain
import Foundation
import Synchronization
import Testing

@testable import MacPlatform

// NET-01/RED: malformed destination, public/moved repository, missing credentials, stale
// consent, cancellation, payload/response limits, redirects, denial, and uncertain PUT completion.
// No test contacts GitHub, reads Keychain, or uploads a real screenshot.
actor UploadTransportFixture: GitHubTransport {
    var replies: [GitHubResponse]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [GitHubResponse]) { self.replies = replies }

    func send(_ request: URLRequest, mayStart: @escaping @MainActor @Sendable () -> Bool) async throws
        -> GitHubResponse
    {
        // The boundary the real transport keeps: nothing is recorded as sent unless allowed.
        guard await mayStart() else { throw GitHubUploadFailure.staleDocument }
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        return replies.removeFirst()
    }
}

/// Answers the GETs, then fails the PUT as a transport does when its task is canceled before the
/// request is handed off: with CancellationError, and nothing sent.
actor CancelingPutTransport: GitHubTransport {
    var replies: [GitHubResponse]

    init(replies: [GitHubResponse]) { self.replies = replies }

    func send(_ request: URLRequest, mayStart: @escaping @MainActor @Sendable () -> Bool) async throws
        -> GitHubResponse
    {
        guard request.httpMethod != "PUT", !replies.isEmpty else { throw CancellationError() }
        return replies.removeFirst()
    }
}

@Suite("GitHub upload: private, sanitized, bounded, idempotent (NET-01)")
struct GitHubUploadTests {
    let destination = GitHubDestination(owner: "fixture-owner", repository: "private-captures")
    let intent = UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID()

    /// A synthetic token admitted the only way the app can make one.
    static func token() throws(GitHubUploadFailure) -> GitHubToken {
        try GitHubTokenStore.validatedToken("ghp_synthetic")
    }

    func reply(_ code: Int, _ json: String) -> GitHubResponse {
        GitHubResponse(statusCode: code, body: Data(json.utf8))
    }

    var privateRepo: GitHubResponse {
        reply(200, #"{"private":true,"archived":false,"full_name":"fixture-owner/private-captures"}"#)
    }

    func file(_ snapshot: ShareSnapshot, wrapped: Bool) -> GitHubResponse {
        let path = "screenshots/\(intent.uuidString.lowercased()).png"
        let sha = GitHubUploader.blobSHA(snapshot.bytes)
        let json =
            "{\"sha\":\"\(sha)\",\"html_url\":\"https://github.com/fixture-owner/private-captures/blob/main/\(path)\",\"type\":\"file\"}"
        return reply(wrapped ? 201 : 200, wrapped ? "{\"content\":\(json)}" : json)
    }

    @Test("Only the sanitized snapshot is uploaded, with a stable intent path")
    func sanitizedPayload() async throws {
        let snapshot = TestSupport.snapshot()
        let transport = UploadTransportFixture([privateRepo, reply(404, "{}"), file(snapshot, wrapped: true)])
        let url = try await GitHubUploader(transport: transport).upload(
            snapshot, to: destination, token: try Self.token(), intent: intent, isLive: { true }, isCurrent: { true })
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "PUT"])
        let put = try #require(requests.last)
        let body = try #require(put.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["content"] == snapshot.bytes.base64EncodedString())
        #expect(json["sha"] == nil, "upload must never replace an existing file")
        #expect(put.url?.lastPathComponent == "\(intent.uuidString.lowercased()).png")
        #expect(url.host == "github.com")
        #expect(requests.allSatisfy { $0.url?.host == "api.github.com" && $0.url?.user == nil })
    }

    @Test("A public repository is rejected before any content request")
    func publicRepositoryDenied() async {
        let transport = UploadTransportFixture([
            reply(200, #"{"private":false,"archived":false,"full_name":"fixture-owner/private-captures"}"#)
        ])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: try Self.token(), intent: intent, isLive: { true },
                isCurrent: { true })
            Issue.record("public repository was accepted")
        } catch { #expect(error == .publicRepository) }
        #expect(await transport.requests.count == 1)
    }

    @Test("Revoked consent or a stale document prevents PUT")
    func staleDocumentDenied() async {
        let transport = UploadTransportFixture([privateRepo, reply(404, "{}")])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: try Self.token(), intent: intent, isLive: { true },
                isCurrent: { false })
            Issue.record("stale upload was accepted")
        } catch { #expect(error == .staleDocument) }
        #expect(await transport.requests.allSatisfy { $0.httpMethod != "PUT" })
    }

    @Test(
        "Malformed destinations cannot change the host or escape the repository",
        arguments: [
            "../other", "a/b", "user@evil.example", "a?x=1", "a%2Fb", "", ".", "..",
        ])
    func invalidDestination(owner: String) async {
        let transport = UploadTransportFixture([])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: GitHubDestination(owner: owner, repository: "captures"),
                token: try Self.token(), intent: intent, isLive: { true }, isCurrent: { true })
            Issue.record("invalid destination was accepted")
        } catch { #expect(error == .invalidDestination) }
        #expect(await transport.requests.isEmpty)
    }

    // R3-08 (third review of T1a): a cancellation before any task was created reached the PUT's
    // error mapping as completionUnknown, although nothing had been sent.
    @Test("A PUT canceled before its request is handed off is canceled, never of unknown completion")
    func putCanceledBeforeHandoffIsCanceled() async throws {
        let transport = CancelingPutTransport(replies: [privateRepo, reply(404, "{}")])
        await #expect(throws: GitHubUploadFailure.canceled) {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: try Self.token(), intent: intent, isLive: { true },
                isCurrent: { true })
        }
    }

    @Test("A transport send from a canceled task checks no consent and creates no task")
    func canceledSendCreatesNoTask() async throws {
        let session = RecordingGitHubSession()
        let transport = GitHubURLTransport(makeSession: { session })
        let request = URLRequest(url: try #require(URL(string: "https://api.github.com/repos/fixture/captures")))
        let checked = Mutex(false)
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(
                request,
                mayStart: {
                    checked.withLock { $0 = true }
                    return true
                })
        }.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!checked.withLock { $0 })
        #expect(session.events.isEmpty, "a task was created for a canceled send")
    }

    @Test("No retry follows an indeterminate PUT; the user is warned it may have completed")
    func uncertainCompletion() async {
        let transport = UploadTransportFixture([privateRepo, reply(404, "{}")])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: try Self.token(), intent: intent, isLive: { true },
                isCurrent: { true })
            Issue.record("failed PUT was reported successful")
        } catch { #expect(error == .completionUnknown) }
        #expect(await transport.requests.map(\.httpMethod) == ["GET", "GET", "PUT"])
    }

    @Test("Reconciliation supports inline base64 metadata for a 400 KiB accepted image")
    func inlineMetadataFits() async throws {
        let snapshot = TestSupport.snapshot(bytes: Data(repeating: 7, count: 400 * 1024))
        let metadata =
            "{\"type\":\"file\",\"sha\":\"\(GitHubUploader.blobSHA(snapshot.bytes))\",\"html_url\":\"https://github.com/fixture-owner/private-captures/blob/main/screenshots/\(intent.uuidString.lowercased()).png\",\"content\":\"\(snapshot.bytes.base64EncodedString())\"}"
        let transport = UploadTransportFixture([privateRepo, reply(200, metadata)])
        _ = try await GitHubUploader(transport: transport).upload(
            snapshot, to: destination, token: try Self.token(), intent: intent, isLive: { true }, isCurrent: { true })
        #expect(
            await transport.requests.last?.value(forHTTPHeaderField: "Accept") == "application/vnd.github.object+json")
    }

    @Test("Mixed-case settings get a link to the configured repository")
    func canonicalLink() async throws {
        let snapshot = TestSupport.snapshot()
        let transport = UploadTransportFixture([privateRepo, reply(404, "{}"), file(snapshot, wrapped: true)])
        let configured = GitHubDestination(owner: "Fixture-Owner", repository: "Private-Captures")
        let result = try await GitHubUploader(transport: transport).upload(
            snapshot, to: configured, token: try Self.token(), intent: intent, isLive: { true }, isCurrent: { true })
        #expect(result.host == "github.com")
    }

    // R08 (adversarial review of T1a): the success link was the response's html_url, so a
    // responder could put the bearer token in its branch segment and the editor would offer it.
    @Test("The success link is built from the destination and path, never taken from the response")
    func linkIgnoresResponseURL() async throws {
        let snapshot = TestSupport.snapshot()
        let path = "screenshots/\(intent.uuidString.lowercased()).png"
        let sha = GitHubUploader.blobSHA(snapshot.bytes)
        let reflected =
            "{\"sha\":\"\(sha)\",\"type\":\"file\",\"html_url\":\"https://github.com/fixture-owner/private-captures/blob/ghp_synthetic/\(path)\"}"
        let expected = "https://github.com/fixture-owner/private-captures/blob/HEAD/\(path)"
        for replies in [
            [privateRepo, reply(404, "{}"), reply(201, "{\"content\":\(reflected)}")],  // created
            [privateRepo, reply(200, reflected)],  // already uploaded by this intent
        ] {
            let link = try await GitHubUploader(transport: UploadTransportFixture(replies)).upload(
                snapshot, to: destination, token: try Self.token(), intent: intent, isLive: { true },
                isCurrent: { true })
            #expect(!link.absoluteString.contains("synthetic"), "the token reached the link")
            #expect(link.absoluteString == expected)
        }
    }

    @Test(
        "HTTP failures are typed before any image request",
        arguments: [
            (401, GitHubUploadFailure.accessDenied), (403, .accessDenied), (404, .accessDenied),
            (409, .conflict), (422, .conflict), (429, .rateLimited), (500, .invalidResponse), (302, .invalidResponse),
        ])
    func statusFailure(code: Int, expected: GitHubUploadFailure) async {
        let transport = UploadTransportFixture([reply(code, "{}")])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: try Self.token(), intent: intent, isLive: { true },
                isCurrent: { true })
            Issue.record("HTTP failure was accepted")
        } catch { #expect(error == expected) }
        #expect(await transport.requests.count == 1)
    }

    @Test(
        "Malformed, archived or renamed repository metadata is refused",
        arguments: [
            "{}", #"{"private":true,"archived":true,"full_name":"fixture-owner/private-captures"}"#,
            #"{"private":true,"archived":false,"full_name":"other/private-captures"}"#,
        ])
    func invalidRepository(metadata: String) async {
        let transport = UploadTransportFixture([reply(200, metadata)])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: try Self.token(), intent: intent, isLive: { true },
                isCurrent: { true })
            Issue.record("invalid metadata was accepted")
        } catch { #expect(error == .invalidResponse) }
        #expect(await transport.requests.count == 1)
    }

    @Test("An existing different blob cannot be overwritten")
    func existingConflict() async {
        let transport = UploadTransportFixture([
            privateRepo,
            reply(
                200,
                #"{"type":"file","sha":"different","html_url":"https://github.com/fixture-owner/private-captures/blob/main/a.png"}"#
            ),
        ])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: try Self.token(), intent: intent, isLive: { true },
                isCurrent: { true })
            Issue.record("conflicting blob was accepted")
        } catch { #expect(error == .conflict) }
        #expect(await transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    // R2-D07 (program 2026-11): the repository and file lookups ran before the only consent
    // check, which guarded the image PUT alone.
    @Test("No authenticated request, lookups included, is sent once the upload's consent is gone")
    func lookupsNeedLiveConsent() async throws {
        for liveChecks in 0...1 {
            let transport = UploadTransportFixture([privateRepo, reply(404, "{}")])
            let remaining = Counter(liveChecks)
            do {
                _ = try await GitHubUploader(transport: transport).upload(
                    TestSupport.snapshot(), to: destination, token: try Self.token(), intent: intent,
                    isLive: { remaining.take() }, isCurrent: { true })
                Issue.record("an upload without live consent succeeded")
            } catch { #expect(error == .staleDocument) }
            #expect(await transport.requests.count == liveChecks, "requests sent after consent was gone")
        }
    }

    /// Answers true `count` times, then false.
    @MainActor
    final class Counter: Sendable {
        private var count: Int
        nonisolated init(_ count: Int) { self.count = count }
        func take() -> Bool {
            defer { count -= 1 }
            return count > 0
        }
    }

    // A malformed token cannot reach the uploader at all: `GitHubToken` comes only from
    // `GitHubTokenStore.validatedToken`, whose control-character cases are in its own suite.
    @Test("An oversized image is rejected before a request")
    func requestLimits() async {
        let transport = UploadTransportFixture([])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(bytes: Data(count: GitHubUploader.maximumImageBytes + 1)),
                to: destination, token: try Self.token(), intent: intent, isLive: { true }, isCurrent: { true })
            Issue.record("oversized image was accepted")
        } catch { #expect(error == .tooLarge) }
        #expect(await transport.requests.isEmpty)
    }

    @Test("Malformed success and a server failure after PUT report uncertain completion", arguments: [201, 500])
    func malformedCompletion(code: Int) async {
        let transport = UploadTransportFixture([privateRepo, reply(404, "{}"), reply(code, "{}")])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: try Self.token(), intent: intent, isLive: { true },
                isCurrent: { true })
            Issue.record("malformed PUT was accepted")
        } catch { #expect(error == .completionUnknown) }
    }

    @Test("Canceled upload does not begin requests")
    @MainActor
    func cancelBeforeRequests() async {
        let transport = UploadTransportFixture([])
        let task = Task {
            try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: try Self.token(), intent: intent, isLive: { true },
                isCurrent: { true })
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("canceled task was accepted") } catch {
            #expect(error as? GitHubUploadFailure == .canceled)
        }
        #expect(await transport.requests.isEmpty)
    }

    // R07 (second review of T1a): the transport awaited the consent check, then handed the request
    // to URLSession in a later turn, so a revocation processed on the main actor in between could
    // not stop a request that had been approved under the old consent.
    @Test("The consent check and the start of the request happen in one main-actor step")
    @MainActor
    func consentCheckAndStartAreOneStep() async throws {
        let session = RecordingGitHubSession()
        let transport = GitHubURLTransport(makeSession: { session })
        let request = URLRequest(url: try #require(URL(string: "https://api.github.com/repos/fixture/captures")))
        var revoked = false
        let mayStart: @MainActor @Sendable () -> Bool = {
            session.log("check")
            guard !revoked else { return false }
            // A revocation queued on the main actor during the check runs after this step.
            Task { @MainActor in
                revoked = true
                session.log("revoke")
            }
            return true
        }
        let response = try await transport.send(request, mayStart: mayStart)
        #expect(response.statusCode == 200)
        await Task.yield()
        #expect(revoked, "control: the revocation never ran")
        #expect(session.events == ["check", "create", "resume", "revoke"])
        await #expect(throws: GitHubUploadFailure.staleDocument) {
            _ = try await transport.send(request, mayStart: mayStart)
        }
        #expect(
            session.events == ["check", "create", "resume", "revoke", "check"], "a request started after revocation")
    }

    @Test("A response larger than the bound is refused and its task canceled")
    func oversizedResponseIsRefused() async throws {
        let session = RecordingGitHubSession(body: Data(count: GitHubUploader.maximumResponseBytes + 1))
        let transport = GitHubURLTransport(makeSession: { session })
        let request = URLRequest(url: try #require(URL(string: "https://api.github.com/repos/fixture/captures")))
        await #expect(throws: GitHubUploadFailure.invalidResponse) {
            _ = try await transport.send(request, mayStart: { true })
        }
        #expect(session.events.contains("cancel"))
    }

    @Test("Redirect delegate declines the redirected request")
    func redirectsDeclined() throws {
        let url = try #require(URL(string: "https://api.github.com/repos/fixture/captures"))
        let evil = try #require(URL(string: "https://example.com/steal"))
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": evil.absoluteString]))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        NoGitHubRedirects().urlSession(
            session, task: session.dataTask(with: url),
            willPerformHTTPRedirection: response, newRequest: URLRequest(url: evil)
        ) { request in
            #expect(request == nil)
        }
    }
}

/// A session that records when tasks are created, started and canceled, and answers each started
/// task at once with a 200 and `body`.
final class RecordingGitHubSession: GitHubSession, Sendable {
    private let state = Mutex<[String]>([])
    private let body: Data

    init(body: Data = Data("{}".utf8)) { self.body = body }

    var events: [String] { state.withLock { $0 } }
    func log(_ event: String) { state.withLock { $0.append(event) } }

    func task(for request: URLRequest, collector: GitHubResponseCollector) -> any GitHubSessionTask {
        log("create")
        return Task(session: self, request: request, collector: collector)
    }

    func finish() {}

    struct Task: GitHubSessionTask {
        let session: RecordingGitHubSession
        let request: URLRequest
        let collector: GitHubResponseCollector

        func resume() {
            session.log("resume")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            collector.receive(response: response)
            collector.receive(data: session.body, cancel: cancel)
            collector.complete(error: nil)
        }

        func cancel() { session.log("cancel") }
    }
}
