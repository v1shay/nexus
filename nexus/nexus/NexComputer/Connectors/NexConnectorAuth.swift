import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Network
import SwiftUI

enum NexConnectorProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case google, notion, slack, github, discord
    var id: String { rawValue }
    var title: String { rawValue == "github" ? "GitHub" : rawValue.capitalized }
    /// Discord is intentionally browser-only. Nexus never stores a Discord
    /// user credential or presents it as a connectable provider.
    var supportsUserConnection: Bool { self != .discord }
}

enum NexOAuthTokenAuthentication: Sendable, Equatable {
    case none
    case formClientSecret
    case basicClientSecret
}

/// App-registration secrets are deliberately separate from account tokens.
/// They are device-local Keychain entries, never plist values or UserDefaults.
struct NexConnectorRegistrationStore: Sendable {
    private let secrets: NexusSecretStore

    init(secrets: NexusSecretStore = NexusKeychainSecretStore(service: "na.nexus.connectors.registration")) {
        self.secrets = secrets
    }

    func clientSecret(for provider: NexConnectorProvider) throws -> String? {
        guard let data = try secrets.data(for: "oauth.\(provider.rawValue).client-secret.v1") else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func githubAppPrivateKey() throws -> Data? {
        try secrets.data(for: "github.app.private-key.v1")
    }

    func githubAppID() throws -> String? {
        guard let data = try secrets.data(for: "github.app.id.v1") else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
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
    let redirectURL: URL?
    let clientSecret: String?
    let tokenAuthentication: NexOAuthTokenAuthentication
    let usesPKCE: Bool
    /// Native Google desktop clients must use an ephemeral loopback callback,
    /// not a hosted web redirect or a custom URI scheme.
    let usesLoopbackRedirect: Bool

    init(
        provider: NexConnectorProvider,
        clientID: String,
        authorizationURL: URL,
        tokenURL: URL,
        verificationURL: URL,
        callbackScheme: String,
        scopeSeparator: String,
        extraAuthorizationItems: [URLQueryItem],
        extraTokenFields: [String: String],
        redirectURL: URL? = nil,
        clientSecret: String? = nil,
        tokenAuthentication: NexOAuthTokenAuthentication = .none,
        usesPKCE: Bool = true,
        usesLoopbackRedirect: Bool = false
    ) {
        self.provider = provider
        self.clientID = clientID
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.verificationURL = verificationURL
        self.callbackScheme = callbackScheme
        self.scopeSeparator = scopeSeparator
        self.extraAuthorizationItems = extraAuthorizationItems
        self.extraTokenFields = extraTokenFields
        self.redirectURL = redirectURL
        self.clientSecret = clientSecret
        self.tokenAuthentication = tokenAuthentication
        self.usesPKCE = usesPKCE
        self.usesLoopbackRedirect = usesLoopbackRedirect
    }

    static func configured(
        _ provider: NexConnectorProvider,
        bundle: Bundle = .main,
        registrations: NexConnectorRegistrationStore = .init()
    ) throws -> Self {
        guard provider.supportsUserConnection else { throw NexConnectorAuthError.providerUnavailable(provider) }
        let key = "NEX" + provider.title.replacingOccurrences(of: "GitHub", with: "Github") + "ClientID"
        guard let clientID = bundle.object(forInfoDictionaryKey: key) as? String,
              !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NexConnectorAuthError.clientRegistrationMissing(provider)
        }
        let redirectURL: URL?
        switch provider {
        case .notion, .slack, .github:
            redirectURL = (bundle.object(forInfoDictionaryKey: "NEXOAuthWebRedirectURL") as? String).flatMap(URL.init(string:))
        case .google, .discord:
            redirectURL = nil
        }
        let secret = try registrations.clientSecret(for: provider)
        func configuration(
            authorizationURL: String,
            tokenURL: String,
            verificationURL: String,
            separator: String,
            authorizationItems: [URLQueryItem] = [],
            tokenAuthentication: NexOAuthTokenAuthentication = .none,
            usesPKCE: Bool = true,
            usesLoopbackRedirect: Bool = false
        ) throws -> Self {
            if tokenAuthentication != .none, secret?.isEmpty != false {
                throw NexConnectorAuthError.clientSecretMissing(provider)
            }
            return .init(
                provider: provider,
                clientID: clientID,
                authorizationURL: URL(string: authorizationURL)!,
                tokenURL: URL(string: tokenURL)!,
                verificationURL: URL(string: verificationURL)!,
                callbackScheme: "na.nexus.oauth",
                scopeSeparator: separator,
                extraAuthorizationItems: authorizationItems,
                extraTokenFields: [:],
                redirectURL: redirectURL,
                clientSecret: secret,
                tokenAuthentication: tokenAuthentication,
                usesPKCE: usesPKCE,
                usesLoopbackRedirect: usesLoopbackRedirect
            )
        }
        switch provider {
        case .google:
            return try configuration(authorizationURL: "https://accounts.google.com/o/oauth2/v2/auth", tokenURL: "https://oauth2.googleapis.com/token", verificationURL: "https://openidconnect.googleapis.com/v1/userinfo", separator: " ", authorizationItems: [.init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")], usesLoopbackRedirect: true)
        case .notion:
            return try configuration(authorizationURL: "https://api.notion.com/v1/oauth/authorize", tokenURL: "https://api.notion.com/v1/oauth/token", verificationURL: "https://api.notion.com/v1/users/me", separator: " ", authorizationItems: [.init(name: "owner", value: "user")], tokenAuthentication: .basicClientSecret, usesPKCE: false)
        case .slack:
            return try configuration(authorizationURL: "https://slack.com/oauth/v2/authorize", tokenURL: "https://slack.com/api/oauth.v2.access", verificationURL: "https://slack.com/api/auth.test", separator: ",", tokenAuthentication: .formClientSecret, usesPKCE: false)
        case .github:
            return try configuration(authorizationURL: "https://github.com/login/oauth/authorize", tokenURL: "https://github.com/login/oauth/access_token", verificationURL: "https://api.github.com/user", separator: " ", tokenAuthentication: .formClientSecret)
        case .discord:
            throw NexConnectorAuthError.providerUnavailable(provider)
        }
    }
}

enum NexConnectorAuthError: LocalizedError, Equatable {
    case clientRegistrationMissing(NexConnectorProvider)
    case invalidCallback
    case stateMismatch
    case cancelled
    case clientSecretMissing(NexConnectorProvider)
    case providerUnavailable(NexConnectorProvider)
    case exchangeFailed(String)
    case verificationFailed(String)
    case credentialUnavailable(NexConnectorProvider)

    var errorDescription: String? {
        switch self {
        case .clientRegistrationMissing(let provider): "This Nexus build has no registered \(provider.title) OAuth client. Add the release client ID to the app's signed Info.plist; no personal API key is required."
        case .invalidCallback: "The authorization callback was invalid."
        case .stateMismatch: "The authorization state did not match, so Nexus rejected the callback."
        case .cancelled: "Connection cancelled."
        case .clientSecretMissing(let provider): "The \(provider.title) OAuth client secret is missing from this Mac's Keychain."
        case .providerUnavailable(let provider): "\(provider.title) is intentionally browser-only and cannot be connected as a Nexus account."
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
    func refresh(configuration: NexOAuthConfiguration, credential: NexConnectorCredential) async throws -> NexConnectorCredential
    func revoke(configuration: NexOAuthConfiguration, credential: NexConnectorCredential) async throws
}

struct NexOAuthURLSessionTransport: NexOAuthTransporting {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func exchange(configuration: NexOAuthConfiguration, code: String, verifier: String, callbackURL: URL, scopes: [String]) async throws -> NexConnectorCredential {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch configuration.tokenAuthentication {
        case .basicClientSecret:
            guard let secret = configuration.clientSecret else { throw NexConnectorAuthError.clientSecretMissing(configuration.provider) }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Basic \(Data("\(configuration.clientID):\(secret)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["grant_type": "authorization_code", "code": code, "redirect_uri": callbackURL.absoluteString])
        case .none, .formClientSecret:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var fields = configuration.extraTokenFields
            fields.merge(["grant_type": "authorization_code", "client_id": configuration.clientID, "code": code, "redirect_uri": callbackURL.absoluteString]) { _, new in new }
            if configuration.usesPKCE { fields["code_verifier"] = verifier }
            if case .formClientSecret = configuration.tokenAuthentication, let secret = configuration.clientSecret { fields["client_secret"] = secret }
            request.httpBody = fields.sorted { $0.key < $1.key }.map { "\($0.key.urlFormEncoded)=\($0.value.urlFormEncoded)" }.joined(separator: "&").data(using: .utf8)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw NexConnectorAuthError.exchangeFailed(Self.safeProviderError(data))
        }
        let expires = (json["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) }
        let account: String
        if configuration.provider == .notion {
            // Notion's successful OAuth exchange is itself the authoritative
            // proof of access and returns the connected workspace identity.
            // Calling /v1/users/me afterward is unnecessary and can reject a
            // valid workspace-scoped OAuth token.
            account = (json["workspace_name"] as? String) ?? "Notion workspace"
        } else {
            account = "Connected account"
        }
        return .init(provider: configuration.provider, account: account, accessToken: access, refreshToken: json["refresh_token"] as? String, tokenType: (json["token_type"] as? String) ?? "Bearer", scopes: scopes, expiresAt: expires, connectedAt: .now, lastSuccessfulUse: nil)
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

    func refresh(configuration: NexOAuthConfiguration, credential: NexConnectorCredential) async throws -> NexConnectorCredential {
        guard let refreshToken = credential.refreshToken else { throw NexConnectorAuthError.credentialUnavailable(configuration.provider) }
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch configuration.tokenAuthentication {
        case .basicClientSecret:
            guard let secret = configuration.clientSecret else { throw NexConnectorAuthError.clientSecretMissing(configuration.provider) }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Basic \(Data("\(configuration.clientID):\(secret)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["grant_type": "refresh_token", "refresh_token": refreshToken])
        case .none, .formClientSecret:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var fields = ["grant_type": "refresh_token", "client_id": configuration.clientID, "refresh_token": refreshToken]
            if case .formClientSecret = configuration.tokenAuthentication, let secret = configuration.clientSecret { fields["client_secret"] = secret }
            request.httpBody = fields.sorted { $0.key < $1.key }.map { "\($0.key.urlFormEncoded)=\($0.value.urlFormEncoded)" }.joined(separator: "&").data(using: .utf8)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let access = json["access_token"] as? String else { throw NexConnectorAuthError.exchangeFailed(Self.safeProviderError(data)) }
        return .init(provider: credential.provider, account: credential.account, accessToken: access, refreshToken: (json["refresh_token"] as? String) ?? refreshToken, tokenType: (json["token_type"] as? String) ?? credential.tokenType, scopes: credential.scopes, expiresAt: (json["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) }, connectedAt: credential.connectedAt, lastSuccessfulUse: credential.lastSuccessfulUse)
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

/// A one-shot, loopback-only OAuth receiver for native desktop clients.
/// It never persists the callback or serves a general HTTP endpoint.
final class NexLoopbackOAuthCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "na.nexus.oauth.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var completedCallback: Result<URL, Error>?
    private var redirectURL: URL?
    private var finished = false

    deinit { stop() }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: NexConnectorAuthError.invalidCallback)
                    return
                }
                guard self.listener == nil else {
                    continuation.resume(throwing: NexConnectorAuthError.invalidCallback)
                    return
                }
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                do {
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    self.readyContinuation = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port,
                                  let redirect = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback") else {
                                self.finishStart(.failure(NexConnectorAuthError.invalidCallback))
                                return
                            }
                            self.redirectURL = redirect
                            self.finishStart(.success(redirect))
                        case .failed(let error):
                            self.finishStart(.failure(error))
                            self.finishCallback(.failure(error))
                        case .cancelled:
                            self.finishStart(.failure(NexConnectorAuthError.cancelled))
                            self.finishCallback(.failure(NexConnectorAuthError.cancelled))
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.receive(connection)
                    }
                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if let completedCallback {
                continuation.resume(with: completedCallback)
                return
            }
            guard listener != nil else {
                continuation.resume(throwing: NexConnectorAuthError.cancelled)
                return
            }
            callbackContinuation = continuation
        }
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        let callback = callbackContinuation
        callbackContinuation = nil
        let start = readyContinuation
        readyContinuation = nil
        completedCallback = .failure(NexConnectorAuthError.cancelled)
        finished = true
        lock.unlock()
        listener?.cancel()
        callback?.resume(throwing: NexConnectorAuthError.cancelled)
        start?.resume(throwing: NexConnectorAuthError.cancelled)
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil,
                  let data,
                  let request = String(data: data, encoding: .utf8),
                  let requestLine = request.components(separatedBy: "\r\n").first,
                  requestLine.hasPrefix("GET "),
                  let target = requestLine.split(separator: " ").dropFirst().first,
                  let base = self.redirectURL,
                  let callback = URL(string: String(target), relativeTo: base)?.absoluteURL else {
                self.writeResponse(to: connection, status: "400 Bad Request", body: "Invalid Nexus callback.")
                self.finishCallback(.failure(NexConnectorAuthError.invalidCallback))
                return
            }
            self.writeResponse(to: connection, status: "200 OK", body: "Nexus connected. You can return to the app.")
            self.finishCallback(.success(callback))
        }
    }

    private func writeResponse(to connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finishStart(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func finishCallback(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = callbackContinuation
        callbackContinuation = nil
        completedCallback = result
        lock.unlock()
        continuation?.resume(with: result)
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
                let appCallback = URL(string: "\(configuration.callbackScheme)://oauth/callback")!
                let loopback = configuration.usesLoopbackRedirect ? NexLoopbackOAuthCallbackServer() : nil
                let redirect: URL
                if let loopback {
                    redirect = try await loopback.start()
                } else {
                    redirect = configuration.redirectURL ?? appCallback
                }
                var components = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false)!
                components.queryItems = [
                    .init(name: "client_id", value: configuration.clientID), .init(name: "redirect_uri", value: redirect.absoluteString),
                    .init(name: "response_type", value: "code"), .init(name: "scope", value: selectedScopes.joined(separator: configuration.scopeSeparator)),
                    .init(name: "state", value: state)
                ] + configuration.extraAuthorizationItems
                if configuration.usesPKCE {
                    components.queryItems?.append(contentsOf: [.init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256")])
                }
                guard let authorizationURL = components.url else { throw NexConnectorAuthError.invalidCallback }
                activeProvider = provider
                message = "Opening \(provider.title)…"
                let callbackURL: URL
                if let loopback {
                    guard NSWorkspace.shared.open(authorizationURL) else { throw NexConnectorAuthError.invalidCallback }
                    callbackURL = try await loopback.waitForCallback()
                    try NexConnectorSecurityPolicy.validateLoopbackCallback(callbackURL, expectedRedirect: redirect)
                    loopback.stop()
                } else {
                    callbackURL = try await authenticate(url: authorizationURL, scheme: configuration.callbackScheme)
                    try NexConnectorSecurityPolicy.validateCallback(callbackURL, expectedScheme: configuration.callbackScheme)
                }
                let query = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard query.first(where: { $0.name == "state" })?.value == state else { throw NexConnectorAuthError.stateMismatch }
                guard let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw NexConnectorAuthError.invalidCallback }
                var credential = try await transport.exchange(configuration: configuration, code: code, verifier: verifier, callbackURL: redirect, scopes: selectedScopes)
                let account = provider == .notion ? credential.account : try await transport.verify(configuration: configuration, credential: credential)
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
        for provider in NexConnectorProvider.allCases where provider.supportsUserConnection && enabledScopes[provider] == nil {
            let saved = UserDefaults.standard.stringArray(forKey: "nex.connector.scopes.\(provider.rawValue)") ?? []
            enabledScopes[provider] = Set(saved.isEmpty ? Self.minimumScopes(provider) : saved)
        }
        statuses = Dictionary(uniqueKeysWithValues: NexConnectorProvider.allCases.filter(\.supportsUserConnection).map { provider in
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

actor NexAuthenticatedConnectorSession {
    private let store: any NexConnectorCredentialStoring
    private let transport: any NexOAuthTransporting
    private let configuration: @Sendable (NexConnectorProvider) throws -> NexOAuthConfiguration
    init(store: any NexConnectorCredentialStoring = NexKeychainConnectorCredentialStore(), transport: any NexOAuthTransporting = NexOAuthURLSessionTransport(), configuration: @escaping @Sendable (NexConnectorProvider) throws -> NexOAuthConfiguration = { try NexOAuthConfiguration.configured($0) }) { self.store = store; self.transport = transport; self.configuration = configuration }

    func validCredential(for provider: NexConnectorProvider, now: Date = .now) async throws -> NexConnectorCredential {
        guard var credential = try store.credential(for: provider) else { throw NexConnectorAuthError.credentialUnavailable(provider) }
        if let expiry = credential.expiresAt, expiry <= now.addingTimeInterval(60) {
            guard credential.refreshToken != nil else { try store.remove(provider); throw NexConnectorAuthError.credentialUnavailable(provider) }
            do {
                credential = try await transport.refresh(configuration: try configuration(provider), credential: credential)
                try store.save(credential)
            } catch {
                // A transient provider/network failure must not erase the
                // durable OAuth record.  Removing it here forced a fresh
                // browser authorization after every restart whenever a
                // refresh happened to race a provider outage.  Keep the
                // credential so the next request can retry; explicit
                // Disconnect/Revoke is the only path that removes it.
                throw error
            }
        }
        return credential
    }

    func markSuccessful(_ credential: NexConnectorCredential, at date: Date = .now) throws {
        try store.save(.init(provider: credential.provider, account: credential.account, accessToken: credential.accessToken, refreshToken: credential.refreshToken, tokenType: credential.tokenType, scopes: credential.scopes, expiresAt: credential.expiresAt, connectedAt: credential.connectedAt, lastSuccessfulUse: date))
    }

    func markRevoked(_ provider: NexConnectorProvider) throws { try store.remove(provider) }
}

enum NexConnectorSecurityPolicy {
    static func validateCallback(_ url: URL, expectedScheme: String) throws {
        guard url.scheme == expectedScheme, url.host == "oauth", url.path == "/callback", url.user == nil, url.password == nil else { throw NexConnectorAuthError.invalidCallback }
    }

    static func validateLoopbackCallback(_ url: URL, expectedRedirect: URL) throws {
        guard url.scheme == "http",
              url.host == "127.0.0.1",
              url.port == expectedRedirect.port,
              url.path == "/oauth/callback",
              url.user == nil,
              url.password == nil else {
            throw NexConnectorAuthError.invalidCallback
        }
    }

    static func redacted(_ value: String, credentials: [NexConnectorCredential] = []) -> String {
        var output = value
        for secret in credentials.flatMap({ [$0.accessToken, $0.refreshToken].compactMap { $0 } }) where !secret.isEmpty { output = output.replacingOccurrences(of: secret, with: "<redacted>") }
        let patterns = [#"(?i)(access_token|refresh_token|authorization_code|client_secret|code)=([^&\s]+)"#, #"(?i)Bearer\s+[A-Za-z0-9._~+/-]+=*"#]
        for pattern in patterns { output = output.replacingOccurrences(of: pattern, with: "$1=<redacted>", options: .regularExpression) }
        return output
    }
}

struct NexConnectionsSettingsView: View {
    @ObservedObject var controller: NexConnectorAuthController
    var body: some View {
        Section("Connections") {
            ForEach(NexConnectorProvider.allCases.filter(\.supportsUserConnection)) { provider in
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
        let providers = provider.map { [$0] } ?? NexConnectorProvider.allCases.filter(\.supportsUserConnection)
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
