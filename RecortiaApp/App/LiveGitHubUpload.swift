import Domain
import Features
import Foundation
import MacPlatform

final class LiveGitHubUpload: GitHubUploadService, GitHubCredentialService {
    private let tokens = GitHubTokenStore()
    private let uploader = GitHubUploader()

    func store(_ token: String, for destination: GitHubDestination) throws(GitHubUploadFailure) {
        try tokens.store(token, for: destination)
    }

    func remove(for destination: GitHubDestination) throws(GitHubUploadFailure) {
        try tokens.remove(for: destination)
    }

    func upload(
        _ snapshot: ShareSnapshot, to destination: GitHubDestination, intent: UUID,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws(GitHubUploadFailure) -> URL {
        let token = try tokens.load(for: destination)
        return try await uploader.upload(snapshot, to: destination, token: token, intent: intent, isCurrent: isCurrent)
    }
}
