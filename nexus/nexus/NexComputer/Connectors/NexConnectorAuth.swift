import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI

enum NexConnectorProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case google, notion, slack, github, discord
    var id: String { rawValue }
    var title: String { rawValue == "github" ? "GitHub" : rawValue.capitalized }
}

struct NexConnectorScopeOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
}

struct NexConnectorPublicStatus: Identifiable, Equatable, Sendable {
    let id: NexConnectorProvider
    let account: String?
    let scopes: [String]
    let connected: Bool
    let healthy: Bool
    let lastSuccessfulUse: Date?
    let detail: String
}

struct NexConnectorCredential: Codable, Equatable, Sendable {
    let provider: NexConnectorProvider
    let account: String
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let scopes: [String]
    let expiresAt: Date?
    let connectedAt: Date
    var lastSuccessfulUse: Date?
}

struct NexOAuthConfiguration: Sendable {
    let provider: NexConnectorProvider
    let clientID: String
    let authorizationURL: URL
    let tokenURL: URL
    let verificationURL: URL
    let callbackScheme: String
    let scopeSeparator: String
    let extraAuthorizationItems: [URLQueryItem]
    let extraTokenFields: [String: String]

    static func configured(_ provider: NexConnectorProvider, bundle: Bundle = .main) throws -> Self {
        let key = "NEX" + provider.title.replacingOccurrences(of: "GitHub", with: "Github") + "ClientID"
        guard let clientID = bundle.object(forInfoDictionaryKey: key) as? String,
              !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NexConnectorAuthError.clientRegistrationMissing(provider)
        }
        switch provider {
        case .google:
            return .init(provider: provider, clientID: clientID, authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!, tokenURL: URL(string: "https://oauth2.googleapis.com/token")!, verificationURL: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!, callbackScheme: "na.nexus.oauth", scopeSeparator: " ", extraAuthorizationItems: [.init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")], extraTokenFields: [:])
        case .notion:
            return .init(provider: provider, clientID: clientID, authorizationURL: URL(string: "https://api.notion.com/v1/oauth/authorize")!, tokenURL: URL(string: "https://api.notion.com/v1/oauth/token")!, verificationURL: URL(string: "https://api.notion.com/v1/users/me")!, callbackScheme: "na.nexus.oauth", scopeSeparator: " ", extraAuthorizationItems: [.init(name: "owner", value: "user")], extraTokenFields: [:])
        case .slack:
            return .init(provider: provider, clientID: clientID, authorizationURL: URL(string: "https://slack.com/oauth/v2/authorize")!, tokenURL: URL(string: "https://slack.com/api/oauth.v2.access")!, verificationURL: URL(string: "https://slack.com/api/auth.test")!, callbackScheme: "na.nexus.oauth", scopeSeparator: ",", extraAuthorizationItems: [], extraTokenFields: [:])
        case .github:
            return .init(provider: provider, clientID: clientID, authorizationURL: URL(string: "https://github.com/login/oauth/authorize")!, tokenURL: URL(string: "https://github.com/login/oauth/access_token")!, verificationURL: URL(string: "https://api.github.com/user")!, callbackScheme: "na.nexus.oauth", scopeSeparator: " ", extraAuthorizationItems: [], extraTokenFields: [:])
        case .discord:
            return .init(provider: provider, clientID: clientID, authorizationURL: URL(string: "https://discord.com/oauth2/authorize")!, tokenURL: URL(string: "https://discord.com/api/oauth2/token")!, verificationURL: URL(string: "https://discord.com/api/users/@me")!, callbackScheme: "na.nexus.oauth", scopeSeparator: " ", extraAuthorizationItems: [.init(name: "response_type", value: "code")], extraTokenFields: [:])
        }
    }
}

enum NexConnectorAuthError: LocalizedError, Equatable {
    case clientRegistrationMissing(NexConnectorProvider)
    case invalidCallback
    case stateMismatch
    case cancelled
    case exchangeFailed(String)
    case verificationFailed(String)
    case credentialUnavailable(NexConnectorProvider)

    var errorDescription: String? {
        switch self {
        case .clientRegistrationMissing(let provider): "This Nexus build has no registered \(provider.title) OAuth client. Add the release client ID to the app's signed Info.plist; no personal API key is required."
        case .invalidCallback: "The authorization callback was invalid."
        case .stateMismatch: "The authorization state did not match, so Nexus rejected the callback."
        case .cancelled: "Connection cancelled."
        case .exchangeFailed(let detail): "The provider rejected the authorization exchange: \(detail)"
        case .verificationFailed(let detail): "Nexus could not verify the connection: \(detail)"
        case .credentialUnavailable(let provider): "\(provider.title) is not connected."
        }
    }
}

protocol NexConnectorCredentialStoring: Sendable {
    func credential(for provider: NexConnectorProvider) throws -> NexConnectorCredential?
    func save(_ credential: NexConnectorCredential) throws
    func remove(_ provider: NexConnectorProvider) throws
}

struct NexKeychainConnectorCredentialStore: NexConnectorCredentialStoring, Sendable {
    private let secrets: NexusSecretStore
    init(secrets: NexusSecretStore = NexusKeychainSecretStore(service: "na.nexus.connectors.oauth")) { self.secrets = secrets }
    func credential(for provider: NexConnectorProvider) throws -> NexConnectorCredential? {
        guard let data = try secrets.data(for: "oauth.\(provider.rawValue).v1") else { return nil }
        return try JSONDecoder.connector.decode(NexConnectorCredential.self, from: data)
    }
    func save(_ credential: NexConnectorCredential) throws {
        try secrets.set(try JSONEncoder.connector.encode(credential), for: "oauth.\(credential.provider.rawValue).v1")
    }
    func remove(_ provider: NexConnectorProvider) throws { try secrets.delete(account: "oauth.\(provider.rawValue).v1") }
}

protocol NexOAuthTransporting: Sendable {
    func exchange(configuration: NexOAuthConfiguration, code: String, verifier: String, callbackURL: URL, scopes: [String]) async throws -> NexConnectorCredential
    func verify(configuration: NexOAuthConfiguration, credential: NexConnectorCredential) async throws -> String
    func revoke(configuration: NexOAuthConfiguration, credential: NexConnectorCredential) async throws
}

struct NexOAuthURLSessionTransport: NexOAuthTransporting {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func exchange(configuration: NexOAuthConfiguration, code: String, verifier: String, callbackURL: URL, scopes: [String]) async throws -> NexConnectorCredential {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var fields = configuration.extraTokenFields
        fields.merge(["grant_type": "authorization_code", "client_id": configuration.clientID, "code": code, "code_verifier": verifier, "redirect_uri": callbackURL.absoluteString]) { _, new in new }
        request.httpBody = fields.sorted { $0.key < $1.key }.map { "\($0.key.urlFormEncoded)=\($0.value.urlFormEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw NexConnectorAuthError.exchangeFailed(Self.safeProviderError(data))
        }
        let expires = (json["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) }
        return .init(provider: configuration.provider, account: "Connected account", accessToken: access, refreshToken: json["refresh_token"] as? String, tokenType: (json["token_type"] as? String) ?? "Bearer", scopes: scopes, expiresAt: expires, connectedAt: .now, lastSuccessfulUse: nil)
    }

    func verify(configuration: NexOAuthConfiguration, credential: NexConnectorCredential) async throws -> String {
        var request = URLRequest(url: configuration.verificationURL)
        request.setValue("\(credential.tokenType) \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if configuration.provider == .notion { request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NexConnectorAuthError.verificationFailed(Self.safeProviderError(data))
        }
        return (json["email"] as? String) ?? (json["login"] as? String) ?? (json["name"] as? String) ?? (json["user"] as? String) ?? "Connected account"
    }

    func revoke(configuration: NexOAuthConfiguration, credential: NexConnectorCredential) async throws {
        // Providers without a standardized RFC 7009 endpoint are disconnected
        // locally. Their status view explains how to revoke remotely.
        try Task.checkCancellation()
    }

    private static func safeProviderError(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "HTTP request failed" }
        return (json["error_description"] as? String) ?? (json["error"] as? String) ?? (json["message"] as? String) ?? "HTTP request failed"
    }
}

@MainActor
final class NexConnectorAuthController: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = NexConnectorAuthController()
    @Published private(set) var statuses: [NexConnectorProvider: NexConnectorPublicStatus] = [:]
    @Published private(set) var activeProvider: NexConnectorProvider?
    @Published private(set) var message: String?
    @Published private(set) var enabledScopes: [NexConnectorProvider: Set<String>] = [:]

    private let store: any NexConnectorCredentialStoring
    private let transport: any NexOAuthTransporting
    private var session: ASWebAuthenticationSession?

    init(store: any NexConnectorCredentialStoring = NexKeychainConnectorCredentialStore(), transport: any NexOAuthTransporting = NexOAuthURLSessionTransport()) {
        self.store = store
        self.transport = transport
        super.init()
        reload()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }

    func connect(_ provider: NexConnectorProvider, scopes: [String]? = nil) {
        guard activeProvider == nil else { return }
        Task {
            do {
                let configuration = try NexOAuthConfiguration.configured(provider)
                let selectedScopes = scopes ?? Self.minimumScopes(provider)
                let state = Self.randomURLSafe(bytes: 32)
                let verifier = Self.randomURLSafe(bytes: 48)
                let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
                let callback = URL(string: "\(configuration.callbackScheme)://oauth/callback")!
                var components = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false)!
                components.queryItems = [
                    .init(name: "client_id", value: configuration.clientID), .init(name: "redirect_uri", value: callback.absoluteString),
                    .init(name: "response_type", value: "code"), .init(name: "scope", value: selectedScopes.joined(separator: configuration.scopeSeparator)),
                    .init(name: "state", value: state), .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256")
                ] + configuration.extraAuthorizationItems
                guard let authorizationURL = components.url else { throw NexConnectorAuthError.invalidCallback }
                activeProvider = provider
                message = "Opening \(provider.title)…"
                let callbackURL = try await authenticate(url: authorizationURL, scheme: configuration.callbackScheme)
                let query = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard query.first(where: { $0.name == "state" })?.value == state else { throw NexConnectorAuthError.stateMismatch }
                guard let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw NexConnectorAuthError.invalidCallback }
                var credential = try await transport.exchange(configuration: configuration, code: code, verifier: verifier, callbackURL: callback, scopes: selectedScopes)
                let account = try await transport.verify(configuration: configuration, credential: credential)
                credential = .init(provider: credential.provider, account: account, accessToken: credential.accessToken, refreshToken: credential.refreshToken, tokenType: credential.tokenType, scopes: credential.scopes, expiresAt: credential.expiresAt, connectedAt: credential.connectedAt, lastSuccessfulUse: .now)
                try store.save(credential)
                message = "\(provider.title) connected."
            } catch {
                message = error.localizedDescription
            }
            activeProvider = nil
            reload()
        }
    }

    func disconnect(_ provider: NexConnectorProvider, revoke: Bool = false) {
        Task {
            do {
                if revoke, let credential = try store.credential(for: provider), let configuration = try? NexOAuthConfiguration.configured(provider) { try await transport.revoke(configuration: configuration, credential: credential) }
                try store.remove(provider)
                message = "\(provider.title) disconnected."
            } catch { message = error.localizedDescription }
            reload()
        }
    }

    func setScope(_ scope: String, enabled: Bool, for provider: NexConnectorProvider) {
        var selected = enabledScopes[provider] ?? Set(Self.minimumScopes(provider))
        if enabled { selected.insert(scope) } else if !Self.minimumScopes(provider).contains(scope) { selected.remove(scope) }
        enabledScopes[provider] = selected
        UserDefaults.standard.set(Array(selected).sorted(), forKey: "nex.connector.scopes.\(provider.rawValue)")
    }

    func connectWithEnabledScopes(_ provider: NexConnectorProvider) {
        connect(provider, scopes: Array(enabledScopes[provider] ?? Set(Self.minimumScopes(provider))).sorted())
    }

    func credential(for provider: NexConnectorProvider) throws -> NexConnectorCredential? { try store.credential(for: provider) }

    func reload() {
        for provider in NexConnectorProvider.allCases where enabledScopes[provider] == nil {
            let saved = UserDefaults.standard.stringArray(forKey: "nex.connector.scopes.\(provider.rawValue)") ?? []
            enabledScopes[provider] = Set(saved.isEmpty ? Self.minimumScopes(provider) : saved)
        }
        statuses = Dictionary(uniqueKeysWithValues: NexConnectorProvider.allCases.map { provider in
            let credential: NexConnectorCredential?
            do { credential = try store.credential(for: provider) } catch { credential = nil }
            let healthy = credential.map { $0.expiresAt.map { $0 > .now } ?? true } ?? false
            return (provider, .init(id: provider, account: credential?.account, scopes: credential?.scopes ?? [], connected: credential != nil, healthy: healthy, lastSuccessfulUse: credential?.lastSuccessfulUse, detail: credential == nil ? "Not connected" : "Connected"))
        })
    }

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { continuation.resume(throwing: NexConnectorAuthError.cancelled); return }
                guard error == nil, let callback else { continuation.resume(throwing: error ?? NexConnectorAuthError.invalidCallback); return }
                continuation.resume(returning: callback)
            }
            auth.presentationContextProvider = self
            auth.prefersEphemeralWebBrowserSession = false
            session = auth
            guard auth.start() else { continuation.resume(throwing: NexConnectorAuthError.invalidCallback); return }
        }
    }

    static func scopeOptions(_ provider: NexConnectorProvider) -> [NexConnectorScopeOption] {
        switch provider {
        case .google: [
            .init(id: "openid", title: "Account", detail: "Verify the connected Google account."),
            .init(id: "https://www.googleapis.com/auth/calendar.readonly", title: "Calendar read", detail: "Read calendars and availability."),
            .init(id: "https://www.googleapis.com/auth/calendar.events", title: "Calendar write", detail: "Create and update events after confirmation."),
            .init(id: "https://www.googleapis.com/auth/gmail.readonly", title: "Gmail read", detail: "Search and read selected mail."),
            .init(id: "https://www.googleapis.com/auth/gmail.modify", title: "Gmail modify", detail: "Draft, label, and archive mail."),
            .init(id: "https://www.googleapis.com/auth/contacts.readonly", title: "Contacts", detail: "Resolve people and contact details.")
        ]
        case .notion: [.init(id: "notion.content.read", title: "Read pages", detail: "Search and read connected pages."), .init(id: "notion.content.write", title: "Update pages", detail: "Create and update pages after confirmation.")]
        case .slack: [.init(id: "channels:history", title: "Read conversations", detail: "Search connected Slack conversations."), .init(id: "chat:write", title: "Send messages", detail: "Send confirmed drafts.")]
        case .github: [.init(id: "repo", title: "Repositories", detail: "Read repositories and perform confirmed writes."), .init(id: "notifications", title: "Notifications", detail: "Read and update GitHub notifications.")]
        case .discord: [.init(id: "identify", title: "Identity", detail: "Verify the authorized Discord account."), .init(id: "guilds", title: "Servers", detail: "Access only officially authorized servers.")]
        }
    }

    static func minimumScopes(_ provider: NexConnectorProvider) -> [String] {
        switch provider { case .google: ["openid"]; case .notion: ["notion.content.read"]; case .slack: ["channels:history"]; case .github: ["repo"]; case .discord: ["identify", "guilds"] }
    }

    private static func randomURLSafe(bytes: Int) -> String { Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncoded }
}

struct NexConnectionsSettingsView: View {
    @ObservedObject var controller: NexConnectorAuthController
    var body: some View {
        Section("Connections") {
            ForEach(NexConnectorProvider.allCases) { provider in
                let status = controller.statuses[provider]
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(NexConnectorAuthController.scopeOptions(provider)) { option in
                            Toggle(isOn: Binding(
                                get: { controller.enabledScopes[provider]?.contains(option.id) == true },
                                set: { controller.setScope(option.id, enabled: $0, for: provider) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                    Text(option.detail).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(NexConnectorAuthController.minimumScopes(provider).contains(option.id))
                        }
                        HStack {
                            if status?.connected == true {
                                Button("Reconnect") { controller.connectWithEnabledScopes(provider) }
                                Button("Disconnect") { controller.disconnect(provider) }
                                Button("Revoke Access", role: .destructive) { controller.disconnect(provider, revoke: true) }
                            } else { Button("Connect \(provider.title)") { controller.connectWithEnabledScopes(provider) } }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack {
                        Image(systemName: status?.connected == true ? (status?.healthy == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill") : "circle")
                            .foregroundStyle(status?.connected == true ? (status?.healthy == true ? .green : .orange) : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.title).font(.headline)
                            Text(status?.account ?? "Not connected").font(.caption).foregroundStyle(.secondary)
                            if let date = status?.lastSuccessfulUse { Text("Last used \(date.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary) }
                        }
                        Spacer()
                        if controller.activeProvider == provider { ProgressView().controlSize(.small) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        if let message = controller.message { Section { Text(message).font(.caption).textSelection(.enabled) } }
    }
}

struct NexConnectorManagementService: Sendable {
    let store: any NexConnectorCredentialStoring
    init(store: any NexConnectorCredentialStoring = NexKeychainConnectorCredentialStore()) { self.store = store }

    func status(provider: NexConnectorProvider? = nil) throws -> [NexConnectorPublicStatus] {
        let providers = provider.map { [$0] } ?? NexConnectorProvider.allCases
        return try providers.map { item in
            let credential = try store.credential(for: item)
            return .init(id: item, account: credential?.account, scopes: credential?.scopes ?? [], connected: credential != nil, healthy: credential?.expiresAt.map { $0 > .now } ?? (credential != nil), lastSuccessfulUse: credential?.lastSuccessfulUse, detail: credential == nil ? "Not connected" : "Connected")
        }
    }

    func disconnect(_ provider: NexConnectorProvider) throws { try store.remove(provider) }

    func doctor() throws -> [String] {
        try status().map { "\($0.id.title): \($0.connected ? ($0.healthy ? "healthy" : "reconnect required") : "not connected")" }
    }
}

private extension Data {
    var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
private extension String {
    var urlFormEncoded: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? self }
}
private extension JSONEncoder {
    static var connector: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }
}
private extension JSONDecoder {
    static var connector: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
