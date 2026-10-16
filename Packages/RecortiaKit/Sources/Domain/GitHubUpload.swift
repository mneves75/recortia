import Foundation

public struct GitHubDestination: Hashable, Sendable, Codable {
    public var owner: String
    public var repository: String

    public init(owner: String, repository: String) {
        self.owner = owner
        self.repository = repository
    }

    public var isValid: Bool {
        Self.validComponent(owner) && Self.validComponent(repository)
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 100 && value != "." && value != ".."
            && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 95
            }
    }
}

public struct GitHubUploadPreferences: Hashable, Sendable, Codable {
    public var destination: GitHubDestination
    public var automatic: Bool

    public init(destination: GitHubDestination, automatic: Bool = false) {
        self.destination = destination
        self.automatic = automatic
    }
}

public enum GitHubUploadFailure: Error, Hashable, Sendable {
    case invalidDestination
    case missingCredential
    case credentialsUnavailable
    case publicRepository
    case tooLarge
    case accessDenied
    case rateLimited
    case conflict
    case staleDocument
    case canceled
    case network
    /// The PUT may have reached GitHub. Never promise cancellation or automatic deletion.
    case completionUnknown
    case invalidResponse
}
