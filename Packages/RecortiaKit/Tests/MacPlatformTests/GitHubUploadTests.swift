import CryptoKit
import Domain
import Foundation
import Testing

@testable import MacPlatform

// NET-01/RED: malformed destination, public/moved repository, missing credentials, stale
// consent, cancellation, payload/response limits, redirects, denial, and uncertain PUT completion.
// No test contacts GitHub, reads Keychain, or uploads a real screenshot.
actor UploadTransportFixture: GitHubTransport {
    var replies: [GitHubResponse]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [GitHubResponse]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> GitHubResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        return replies.removeFirst()
    }
}

@Suite("GitHub upload: private, sanitized, bounded, idempotent (NET-01)")
struct GitHubUploadTests {
    let destination = GitHubDestination(owner: "fixture-owner", repository: "private-captures")
    let intent = UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID()

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
            snapshot, to: destination, token: "synthetic-token", intent: intent, isCurrent: { true })
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

    @Test("Retrying the same intent recognizes the existing blob without another PUT")
    func retryDoesNotDuplicate() async throws {
        let snapshot = TestSupport.snapshot()
        let transport = UploadTransportFixture([privateRepo, file(snapshot, wrapped: false)])
        _ = try await GitHubUploader(transport: transport).upload(
            snapshot, to: destination, token: "synthetic-token", intent: intent, isCurrent: { true })
        #expect(await transport.requests.map(\.httpMethod) == ["GET", "GET"])
    }

    @Test("A public repository is rejected before any content request")
    func publicRepositoryDenied() async {
        let transport = UploadTransportFixture([
            reply(200, #"{"private":false,"archived":false,"full_name":"fixture-owner/private-captures"}"#)
        ])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: "synthetic-token", intent: intent, isCurrent: { true })
            Issue.record("public repository was accepted")
        } catch { #expect(error == .publicRepository) }
        #expect(await transport.requests.count == 1)
    }

    @Test("Revoked consent or a stale document prevents PUT")
    func staleDocumentDenied() async {
        let transport = UploadTransportFixture([privateRepo, reply(404, "{}")])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: "synthetic-token", intent: intent, isCurrent: { false })
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
                token: "synthetic-token", intent: intent, isCurrent: { true })
            Issue.record("invalid destination was accepted")
        } catch { #expect(error == .invalidDestination) }
        #expect(await transport.requests.isEmpty)
    }

    @Test("No retry follows an indeterminate PUT; the user is warned it may have completed")
    func uncertainCompletion() async {
        let transport = UploadTransportFixture([privateRepo, reply(404, "{}")])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: "synthetic-token", intent: intent, isCurrent: { true })
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
            snapshot, to: destination, token: "synthetic-token", intent: intent, isCurrent: { true })
        #expect(
            await transport.requests.last?.value(forHTTPHeaderField: "Accept") == "application/vnd.github.object+json")
    }

    @Test("Mixed-case settings accept GitHub's canonical repository link")
    func canonicalLink() async throws {
        let snapshot = TestSupport.snapshot()
        let transport = UploadTransportFixture([privateRepo, reply(404, "{}"), file(snapshot, wrapped: true)])
        let configured = GitHubDestination(owner: "Fixture-Owner", repository: "Private-Captures")
        let result = try await GitHubUploader(transport: transport).upload(
            snapshot, to: configured, token: "synthetic-token", intent: intent, isCurrent: { true })
        #expect(result.host == "github.com")
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
                TestSupport.snapshot(), to: destination, token: "synthetic-token", intent: intent, isCurrent: { true })
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
                TestSupport.snapshot(), to: destination, token: "synthetic-token", intent: intent, isCurrent: { true })
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
                TestSupport.snapshot(), to: destination, token: "synthetic-token", intent: intent, isCurrent: { true })
            Issue.record("conflicting blob was accepted")
        } catch { #expect(error == .conflict) }
        #expect(await transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test("Image size and invalid token are rejected before a request")
    func requestLimits() async {
        let transport = UploadTransportFixture([])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(bytes: Data(count: GitHubUploader.maximumImageBytes + 1)),
                to: destination, token: "synthetic-token", intent: intent, isCurrent: { true })
            Issue.record("oversized image was accepted")
        } catch { #expect(error == .tooLarge) }
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: "bad\r\nheader", intent: intent, isCurrent: { true })
            Issue.record("header injection token was accepted")
        } catch { #expect(error == .missingCredential) }
        #expect(await transport.requests.isEmpty)
    }

    @Test("Oversized responses are refused")
    func responseLimit() async {
        let transport = UploadTransportFixture([
            GitHubResponse(statusCode: 200, body: Data(count: GitHubUploader.maximumResponseBytes + 1))
        ])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: "synthetic-token", intent: intent, isCurrent: { true })
            Issue.record("oversized response was accepted")
        } catch { #expect(error == .invalidResponse) }
    }

    @Test("Malformed success and a server failure after PUT report uncertain completion", arguments: [201, 500])
    func malformedCompletion(code: Int) async {
        let transport = UploadTransportFixture([privateRepo, reply(404, "{}"), reply(code, "{}")])
        do {
            _ = try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: "synthetic-token", intent: intent, isCurrent: { true })
            Issue.record("malformed PUT was accepted")
        } catch { #expect(error == .completionUnknown) }
    }

    @Test("Canceled upload does not begin requests")
    @MainActor
    func cancelBeforeRequests() async {
        let transport = UploadTransportFixture([])
        let task = Task {
            try await GitHubUploader(transport: transport).upload(
                TestSupport.snapshot(), to: destination, token: "synthetic-token", intent: intent, isCurrent: { true })
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("canceled task was accepted") } catch {
            #expect(error as? GitHubUploadFailure == .canceled)
        }
        #expect(await transport.requests.isEmpty)
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
