import Foundation
import AuthenticationServices
import Security
import AppKit
import CryptoKit

// MARK: - Google OAuth Client config
// clientID and clientSecret are defined in GoogleCredentials.swift (gitignored).
// See GoogleCredentials.swift.example for the format.
enum GoogleDriveConfig {
    // Reversed-client-ID scheme used as the OAuth redirect callback URL
    static var callbackScheme: String {
        // e.g. "123456789-abcdef.apps.googleusercontent.com" → "com.googleusercontent.apps.123456789-abcdef"
        let parts = clientID.components(separatedBy: ".").reversed()
        return parts.joined(separator: ".")
    }
    static var redirectURI: String { "\(callbackScheme):/oauthcallback" }
    static let authEndpoint  = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let scopes        = "https://www.googleapis.com/auth/drive.file openid email"
}

// MARK: - Keychain helpers (Google Drive tokens)
private enum GDKeychain {
    static let service = "ArgusAI-GoogleDrive"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - GoogleDriveService

// GoogleDriveService is NOT @MainActor at the class level so it can be
// stored as a let property in MetricsStore (a non-isolated ObservableObject).
// Individual methods that update @Published UI state are marked @MainActor.
final class GoogleDriveService: NSObject, ObservableObject {

    @Published var connectedEmail: String?
    @Published var isAuthenticating = false
    @Published var lastError: String?

    private var accessToken: String?
    private var accessTokenExpiry: Date?

    // Dedicated session: the shared one has a 60s request timeout, far too long
    // for the UI to sit on a spinner when the network is down.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 120   // uploads can be large
        return URLSession(configuration: config)
    }()

    // MARK: Init — restore persisted state
    override init() {
        super.init()
        // Read Keychain off main actor; publish result via Task so @Published
        // mutation happens on main actor (required by SwiftUI / Combine).
        let email = GDKeychain.load(key: "connectedEmail")
        if let email {
            Task { @MainActor [weak self] in self?.connectedEmail = email }
        }
    }

    var isConnected: Bool { connectedEmail != nil }

    // MARK: - Authentication (PKCE)

    @MainActor
    func authenticate() async {
        guard !GoogleDriveConfig.clientID.hasPrefix("REPLACE") else {
            lastError = "Google Drive non configurato: imposta clientID/clientSecret in GoogleDriveService.swift"
            return
        }
        isAuthenticating = true
        lastError = nil
        do {
            try await performOAuthFlow()
        } catch {
            lastError = error.localizedDescription
        }
        isAuthenticating = false
    }

    @MainActor
    private func performOAuthFlow() async throws {
        // PKCE: generate verifier + challenge
        let verifier  = pkceVerifier()
        let challenge = pkceChallenge(from: verifier)

        // Build auth URL
        var comps = URLComponents(string: GoogleDriveConfig.authEndpoint)!
        comps.queryItems = [
            URLQueryItem(name: "client_id",             value: GoogleDriveConfig.clientID),
            URLQueryItem(name: "redirect_uri",          value: GoogleDriveConfig.redirectURI),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "scope",                 value: GoogleDriveConfig.scopes),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type",           value: "offline"),
            URLQueryItem(name: "prompt",                value: "consent"),
        ]
        guard let authURL = comps.url else { throw GDError.badURL }

        // Open browser
        let callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: authURL,
                                                     callbackURLScheme: GoogleDriveConfig.callbackScheme) { url, error in
                if let error { cont.resume(throwing: error); return }
                guard let url else { cont.resume(throwing: GDError.noCallbackURL); return }
                cont.resume(returning: url)
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            session.start()
        }

        // Extract authorization code
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw GDError.noCodeInCallback }

        // Exchange code for tokens
        let tokens = try await exchangeCode(code, verifier: verifier)
        accessToken       = tokens.accessToken
        accessTokenExpiry = Date().addingTimeInterval(Double(tokens.expiresIn - 30))
        GDKeychain.save(key: "refreshToken", value: tokens.refreshToken)

        // Fetch email via userinfo endpoint
        if let email = try? await fetchEmail(accessToken: tokens.accessToken) {
            connectedEmail = email
            GDKeychain.save(key: "connectedEmail", value: email)
        } else {
            connectedEmail = "Google Drive"
            GDKeychain.save(key: "connectedEmail", value: "Google Drive")
        }
    }

    // MARK: - Disconnect

    @MainActor
    func disconnect() {
        accessToken       = nil
        accessTokenExpiry = nil
        connectedEmail    = nil
        GDKeychain.delete(key: "refreshToken")
        GDKeychain.delete(key: "connectedEmail")
    }

    // MARK: - Token refresh

    func validAccessToken() async throws -> String {
        // Return cached token if still valid
        if let token = accessToken, let expiry = accessTokenExpiry, Date() < expiry {
            return token
        }
        // Refresh
        guard let refreshToken = GDKeychain.load(key: "refreshToken") else {
            throw GDError.notAuthenticated
        }
        let body: [String: String] = [
            "client_id":     GoogleDriveConfig.clientID,
            "client_secret": GoogleDriveConfig.clientSecret,
            "refresh_token": refreshToken,
            "grant_type":    "refresh_token",
        ]
        var req = URLRequest(url: URL(string: GoogleDriveConfig.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.percentEncoded()
        let (data, resp_) = try await Self.session.data(for: req)
        if let http = resp_ as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // An invalid/revoked refresh token means we're effectively logged out
            GDKeychain.delete(key: "refreshToken")
            throw GDError.tokenRefreshFailed(Self.apiErrorMessage(from: data) ?? "HTTP \(http.statusCode)")
        }
        let resp = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken       = resp.access_token
        accessTokenExpiry = Date().addingTimeInterval(Double(resp.expires_in - 30))
        return resp.access_token
    }

    // MARK: - Upload file to Drive

    /// Uploads `data` as a new file in the specified Drive folder (by folder ID or URL).
    func uploadFile(name: String, data: Data, mimeType: String, folderID: String) async throws {
        let token = try await validAccessToken()

        // Build multipart/related body
        let boundary = "ArgusAI_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let metadata = """
        {"name":"\(name)","parents":["\(folderID)"]}
        """.data(using: .utf8)!

        var body = Data()
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8Data)
        body.append(metadata)
        body.append("\r\n--\(boundary)\r\n".utf8Data)
        body.append("Content-Type: \(mimeType)\r\n\r\n".utf8Data)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".utf8Data)

        let uploadURL = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!
        var req = URLRequest(url: uploadURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (respData, httpResp) = try await Self.session.data(for: req)
        guard let http = httpResp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = Self.apiErrorMessage(from: respData)
                ?? String(data: respData, encoding: .utf8)
                ?? "Unknown error"
            throw GDError.uploadFailed("HTTP \((httpResp as? HTTPURLResponse)?.statusCode ?? -1): \(msg)")
        }
    }

    /// Extracts a human-readable message from a Google API error body.
    /// Handles both shapes: `{"error": {"message": ...}}` (Drive API)
    /// and `{"error": "...", "error_description": "..."}` (OAuth endpoints).
    private static func apiErrorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
            return msg
        }
        if let err = obj["error"] as? String {
            let desc = obj["error_description"] as? String
            return desc.map { "\(err): \($0)" } ?? err
        }
        return nil
    }

    // MARK: - Folder ID extraction

    /// Extracts Drive folder ID from links like:
    ///   https://drive.google.com/drive/folders/1ABC...XYZ
    ///   https://drive.google.com/drive/folders/1ABC...XYZ?usp=sharing
    ///   https://drive.google.com/open?id=1ABC...XYZ
    static func folderID(from urlString: String) -> String? {
        let s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pattern 1: /folders/<id>
        if let range = s.range(of: #"(?<=/folders/)[A-Za-z0-9_-]+"#,
                                options: .regularExpression) {
            return String(s[range])
        }
        // Pattern 2: ?id=<id> or &id=<id>
        if let comps = URLComponents(string: s),
           let id = comps.queryItems?.first(where: { $0.name == "id" })?.value {
            return id
        }
        // Pattern 3: bare ID (no URL)
        if s.range(of: "^[A-Za-z0-9_-]{20,}$", options: .regularExpression) != nil {
            return s
        }
        return nil
    }

    // MARK: - Private helpers

    private func exchangeCode(_ code: String, verifier: String) async throws -> OAuthTokens {
        let body: [String: String] = [
            "client_id":     GoogleDriveConfig.clientID,
            "client_secret": GoogleDriveConfig.clientSecret,
            "code":          code,
            "code_verifier": verifier,
            "redirect_uri":  GoogleDriveConfig.redirectURI,
            "grant_type":    "authorization_code",
        ]
        var req = URLRequest(url: URL(string: GoogleDriveConfig.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.percentEncoded()
        let (data, resp) = try await Self.session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GDError.tokenRefreshFailed(Self.apiErrorMessage(from: data) ?? "HTTP \(http.statusCode)")
        }
        // Try to decode; if refresh_token is absent the exchange failed
        struct RawTokens: Decodable {
            let access_token: String
            let expires_in: Int
            let refresh_token: String?
        }
        let raw = try JSONDecoder().decode(RawTokens.self, from: data)
        guard let refresh = raw.refresh_token else {
            throw GDError.noRefreshToken
        }
        return OAuthTokens(accessToken: raw.access_token, expiresIn: raw.expires_in, refreshToken: refresh)
    }

    private func fetchEmail(accessToken: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await Self.session.data(for: req)
        struct UserInfo: Decodable { let email: String? }
        return try JSONDecoder().decode(UserInfo.self, from: data).email ?? "Google Drive"
    }

    private func pkceVerifier() -> String {
        var buf = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buf.count, &buf)
        return Data(buf).base64URLEncoded()
    }

    private func pkceChallenge(from verifier: String) -> String {
        let data   = Data(verifier.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest).base64URLEncoded()
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding
extension GoogleDriveService: ASWebAuthenticationPresentationContextProviding {
    // ASWebAuthenticationSession guarantees this is called on the main thread,
    // so MainActor.assumeIsolated is safe.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
        }
    }
}

// MARK: - Supporting types

private struct OAuthTokens {
    let accessToken: String
    let expiresIn:   Int
    let refreshToken: String
}

private struct TokenResponse: Decodable {
    let access_token: String
    let expires_in:   Int
}

enum GDError: LocalizedError {
    case badURL
    case noCallbackURL
    case noCodeInCallback
    case noRefreshToken
    case notAuthenticated
    case tokenRefreshFailed(String)
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .badURL:             return "URL OAuth non valido"
        case .noCallbackURL:      return "Nessuna URL di callback ricevuta da Google"
        case .noCodeInCallback:   return "Il callback Google non contiene un codice di autorizzazione"
        case .noRefreshToken:     return "Google non ha restituito un refresh token (riprova, assicurati di dare il consenso)"
        case .notAuthenticated:   return "Non connesso a Google Drive — effettua il login prima di esportare"
        case .tokenRefreshFailed(let m): return "Autenticazione Google fallita: \(m) — riconnetti l'account e riprova"
        case .uploadFailed(let m): return "Upload su Drive fallito: \(m)"
        }
    }
}

// MARK: - Data / String extensions

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    var utf8Data: Data { self }
}

private extension String {
    var utf8Data: Data { data(using: .utf8)! }
}

private extension Dictionary where Key == String, Value == String {
    func percentEncoded() -> Data? {
        map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(ek)=\(ev)"
        }
        .joined(separator: "&")
        .data(using: .utf8)
    }
}
