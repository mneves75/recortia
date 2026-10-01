import Domain
import Features
import SwiftUI

enum GitHubUploadStrings {
    static func message(_ failure: GitHubUploadFailure) -> String {
        switch failure {
        case .invalidDestination: String(localized: "Enter a valid GitHub owner and repository name.")
        case .missingCredential: String(localized: "Save a GitHub token in Settings before uploading.")
        case .credentialsUnavailable: String(localized: "The GitHub token could not be accessed in Keychain.")
        case .publicRepository: String(localized: "Upload refused: the GitHub repository is public.")
        case .tooLarge: String(localized: "GitHub uploads are limited to 8 MB. Reduce the export scale.")
        case .accessDenied:
            String(localized: "GitHub denied access. Check the private repository and token permissions.")
        case .rateLimited: String(localized: "GitHub rate limit reached. Try again later.")
        case .conflict: String(localized: "GitHub could not create this file. No existing file was replaced.")
        case .staleDocument: String(localized: "Upload stopped because the image or upload consent changed.")
        case .canceled: String(localized: "Upload canceled before sending the image.")
        case .network: String(localized: "GitHub could not be reached. No image upload was started.")
        case .completionUnknown:
            String(
                localized:
                    "The upload may have reached GitHub. Check the repository before trying again; remote copies cannot be recalled."
            )
        case .invalidResponse: String(localized: "GitHub returned an unexpected response. Upload stopped.")
        }
    }
}

/// Destination edits disable automation until the user explicitly enables it again. Tokens
/// exist only in this secure field until saved to the app's Keychain; never in preferences.
struct GitHubUploadSettings: View {
    let settings: SettingsStore
    let credentials: (any GitHubCredentialService)?
    @State private var owner = ""
    @State private var repository = ""
    @State private var token = ""
    @State private var message: String?
    @State private var confirmingAutomaticUpload = false

    private var destination: GitHubDestination {
        GitHubDestination(
            owner: owner.trimmingCharacters(in: .whitespacesAndNewlines),
            repository: repository.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        Form {
            Section {
                TextField("Repository owner", text: $owner)
                TextField("Private repository", text: $repository)
                SecureField("Fine-grained GitHub token", text: $token)
                Button("Save destination and token") { save() }
                    .disabled(credentials == nil || !destination.isValid || token.isEmpty)
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            } header: {
                Text("GitHub destination")
            } footer: {
                Text(
                    "Use a dedicated private repository and a fine-grained token restricted to it, with Contents: read and write. The token stays in Keychain. Each upload creates a commit in screenshots/."
                )
                .font(.callout)
            }
            Section {
                if let configuration = settings.preferences.githubUpload {
                    Text("\(configuration.destination.owner)/\(configuration.destination.repository)")
                    Toggle(
                        "Upload automatically after capture",
                        isOn: Binding(
                            get: { settings.preferences.githubUpload?.automatic == true },
                            set: { enabled in
                                if enabled {
                                    confirmingAutomaticUpload = true
                                } else {
                                    settings.update { $0.githubUpload?.automatic = false }
                                }
                            })
                    )
                    .disabled(credentials == nil)
                    Button("Remove destination and token") { remove(configuration.destination) }
                } else {
                    Text("Automatic upload is off. Save a destination and token first.")
                }
            } header: {
                Text("Automatic upload")
            } footer: {
                Text(
                    "When enabled, each still capture is uploaded before later edits or redaction. Uploads require a private repository and are limited to 8 MB. Git history retains earlier images; turning this off or closing Recortia does not delete remote copies."
                )
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            owner = settings.preferences.githubUpload?.destination.owner ?? ""
            repository = settings.preferences.githubUpload?.destination.repository ?? ""
        }
        .onDisappear { token = "" }
        .confirmationDialog("Enable automatic upload to GitHub?", isPresented: $confirmingAutomaticUpload) {
            Button("Enable automatic upload") { settings.update { $0.githubUpload?.automatic = true } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let configuration = settings.preferences.githubUpload {
                Text(
                    "Every new still capture will be sent to \(configuration.destination.owner)/\(configuration.destination.repository) before you can edit or redact it. Remote copies cannot be recalled."
                )
            }
        }
    }

    private func save() {
        guard let credentials else { return }
        do {
            try credentials.store(token, for: destination)
            settings.update { $0.githubUpload = GitHubUploadPreferences(destination: destination) }
            token = ""
            message = String(localized: "Destination saved. Enable automatic upload separately.")
        } catch { message = GitHubUploadStrings.message(error) }
    }

    private func remove(_ destination: GitHubDestination) {
        settings.update { $0.githubUpload?.automatic = false }
        guard let credentials else { return }
        do {
            try credentials.remove(for: destination)
            settings.update { $0.githubUpload = nil }
            token = ""
            message = nil
        } catch { message = GitHubUploadStrings.message(error) }
    }
}
