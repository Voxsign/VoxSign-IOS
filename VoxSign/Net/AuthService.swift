//
//  AuthService.swift
//  VoxSign
//
//  Google sign-in (cloud mode): OIDC Authorization Code + PKCE, iOS-type OAuth client.
//  Flow (iOS-type client):
//    1. Generate code_verifier + code_challenge(S256)
//    2. ASWebAuthenticationSession opens the accounts.google.com consent page
//       (redirect_uri = com.googleusercontent.apps.<client-id>:// custom scheme,
//        captured reliably on iOS — the Web client's http://127.0.0.1 callback capture is
//        unreliable on a real device)
//    3. User consents -> callback captures ?code=
//    4. iOS public client + PKCE exchanges id_token (no client_secret, zero iOS secrets)
//    5. POST cloud /v1/auth/google {id_token} -> server JWKS RS256 verify -> tenant -> session JWT
//  Zero third-party dependencies: AuthenticationServices + CryptoKit only.
//

import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// Google OAuth parameters (iOS-type client; public client, safe to embed).
enum GoogleOAuth {
    /// Created in Google Cloud Console (iOS type, Bundle ID ai.voxsign.ios).
    static var clientID: String {
        "914563065668-50u3b19qin911rqg1p2msrg661n8v4pp.apps.googleusercontent.com"
    }
    /// Authorization callback for the iOS-type client: reverse-DNS scheme.
    /// Note: the Console registers the part WITHOUT the `.apps.googleusercontent.com` suffix
    /// (verified: including the suffix -> redirect_uri_mismatch).
    private static var schemePrefix: String {
        "com.googleusercontent.apps.\(clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: ""))"
    }
    static var redirectURI: String { "\(schemePrefix)://" }
    /// callbackURLScheme for ASWebAuthenticationSession (without ://).
    static var callbackScheme: String { schemePrefix }
    static let scope = "openid email profile"
    static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
}

/// Response to POST /v1/auth/google (session JWT + tenant info).
struct GoogleLoginResult: Decodable, Equatable {
    let token: String
    let tenant: String
    let email: String
    let tier: String
    let trialUntil: String?
    let quota: GoogleQuota?

    struct GoogleQuota: Decodable, Equatable {
        let used: Int?
        let limit: Int?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case used, limit
            case resetsAt = "resets_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case token, tenant, email, tier, quota
        case trialUntil = "trial_until"
    }
}

/// Response to GET /v1/me (sign-in state refresh).
struct MeResult: Decodable, Equatable {
    let tenant: String
    let email: String
    let tier: String
    let trialUntil: String?
    let quota: GoogleLoginResult.GoogleQuota?
    enum CodingKeys: String, CodingKey {
        case tenant, email, tier, quota
        case trialUntil = "trial_until"
    }
}

/// Google sign-in orchestration: PKCE + ASWebAuthenticationSession + iOS id_token exchange + cloud verify.
final class AuthService: NSObject {
    static let shared = AuthService()

    private var session: ASWebAuthenticationSession?

    /// Start Google consent; returns the authorization code + PKCE verifier.
    func authorize(base: String) async throws -> (code: String, verifier: String) {
        let verifier = Self.generateVerifier()
        let challenge = Self.s256Challenge(verifier)
        guard var comps = URLComponents(string: GoogleOAuth.authorizationEndpoint) else {
            throw APIError.transport("Invalid OAuth endpoint")
        }
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: GoogleOAuth.clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleOAuth.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuth.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
        ]
        guard let url = comps.url else {
            throw APIError.transport("Failed to build OAuth URL")
        }
        let code = try await startSession(url: url, callbackScheme: GoogleOAuth.callbackScheme)
        return (code, verifier)
    }

    /// Exchange id_token with the iOS public client + PKCE (no client_secret; the token never touches the cloud, zero iOS secrets).
    func exchangeIDToken(code: String, verifier: String) async throws -> String {
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: GoogleOAuth.clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleOAuth.redirectURI),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        guard let endpoint = URL(string: GoogleOAuth.tokenEndpoint),
              let body = comps.percentEncodedQuery else {
            throw APIError.transport("Invalid Google token endpoint")
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.transport("No response from Google token exchange")
        }
        guard (200...299).contains(http.statusCode),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = j["id_token"] as? String, !idToken.isEmpty else {
            let body = String(decoding: data, as: UTF8.self)
            throw APIError.http(http.statusCode, body)
        }
        return idToken
    }

    // MARK: - ASWebAuthenticationSession

    @MainActor
    private func startSession(url: URL, callbackScheme: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            var auth: ASWebAuthenticationSession?
            let completion: ASWebAuthenticationSession.CompletionHandler = { callbackURL, error in
                defer { self.session = nil }
                if let error = error {
                    cont.resume(throwing: Self.mapAuthError(error))
                    return
                }
                guard let callbackURL = callbackURL,
                      let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
                      !code.isEmpty else {
                    cont.resume(throwing: APIError.transport("No code in Google callback (user may have canceled)"))
                    return
                }
                cont.resume(returning: code)
            }
            auth = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme, completionHandler: completion)
            self.session = auth
            auth?.presentationContextProvider = self
            auth?.prefersEphemeralWebBrowserSession = false
            // start() returning false means the sheet failed to present (e.g. no key window);
            // in that case completion is never called — we must throw immediately, otherwise the
            // continuation never resumes and the user gets no feedback.
            if auth?.start() != true {
                auth = nil
                self.session = nil
                cont.resume(throwing: APIError.transport("Could not present the Google sign-in window, please retry"))
            }
        }
    }

    private static func mapAuthError(_ error: Error) -> Error {
        if let e = error as? ASWebAuthenticationSessionError {
            switch e.code {
            case .canceledLogin:
                return APIError.transport("Sign-in canceled")
            default:
                return APIError.transport("Google sign-in failed: \(e.localizedDescription)")
            }
        }
        return APIError.transport("Google sign-in failed: \(error.localizedDescription)")
    }

    // MARK: - PKCE（RFC 7636）

    /// Generate a 32-byte random verifier -> base64url (43 chars).
    static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    /// SHA-256(verifier) -> base64url.
    static func s256Challenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

extension AuthService: ASWebAuthenticationPresentationContextProviding {
    @MainActor
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Prefer the foreground scene's keyWindow; fall back to the first window.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                return key
            }
        }
        if let w = scenes.first?.windows.first { return w }
        return ASPresentationAnchor()
    }
}

extension Data {
    /// base64url (RFC 4648 section 5, no padding).
    func base64URLEncodedString() -> String {
        var s = base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }
}
