//
//  AuthManager.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/29/26.
//

import Foundation
import SwiftUI

/// Manages authentication state using Clerk
@Observable
class AuthManager {
    static let shared = AuthManager()

    // MARK: - Configuration

    // TODO: Move to environment config or Info.plist
    static let clerkPublishableKey = "pk_test_cXVpY2stdG9ydG9pc2UtMzMuY2xlcmsuYWNjb3VudHMuZGV2JA"

    // MARK: - State

    var isAuthenticated: Bool = false
    var isLoading: Bool = true
    var currentUser: ClerkUser?
    var sessionToken: String?
    var sessionId: String?

    // MARK: - Keychain Keys

    private let tokenKey = "com.fiatlux.clerk.sessionToken"
    private let userKey = "com.fiatlux.clerk.user"
    private let sessionIdKey = "com.fiatlux.clerk.sessionId"

    // MARK: - Token Refresh

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 45  // Refresh every 45 seconds (JWTs expire at 60)

    private init() {
        loadStoredSession()
    }

    // MARK: - Session Management

    /// Load stored session from Keychain on app launch
    private func loadStoredSession() {
        isLoading = true
        print("[Auth] Loading stored session...")

        if let token = KeychainHelper.load(key: tokenKey),
           let storedSessionId = KeychainHelper.load(key: sessionIdKey),
           let userData = KeychainHelper.loadData(key: userKey),
           let user = try? JSONDecoder().decode(ClerkUser.self, from: userData) {
            print("[Auth] Found stored session for user: \(user.id)")
            self.sessionToken = token
            self.sessionId = storedSessionId
            self.currentUser = user
            self.isAuthenticated = true

            // Update BackendService with token
            BackendService.shared = BackendService(
                environment: .dev,
                apiKey: nil,
                authToken: token
            )

            // Immediately refresh the token (stored one is likely expired)
            Task {
                await refreshToken()
            }

            // Start periodic refresh
            startTokenRefresh()
        } else {
            print("[Auth] No stored session found")
        }

        isLoading = false
        print("[Auth] Load complete - isAuthenticated: \(isAuthenticated), isLoading: \(isLoading)")
    }

    /// Sign in with email/password via backend (which calls Clerk Backend API)
    func signIn(email: String, password: String) async throws {
        await MainActor.run {
            isLoading = true
            print("[Auth] isLoading set to true")
        }

        do {
            // Call our backend's /auth/signin endpoint
            let backendURL = BackendService.shared.baseURL
            let signInURL = URL(string: "\(backendURL)/auth/signin")!

            var request = URLRequest(url: signInURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "email": email,
                "password": password
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            print("[Auth] Calling backend /auth/signin for: \(email)")
            print("[Auth] Backend URL: \(signInURL)")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AuthError.invalidResponse
            }

            print("[Auth] Response status: \(httpResponse.statusCode)")
            if let responseStr = String(data: data, encoding: .utf8) {
                print("[Auth] Response body: \(responseStr.prefix(500))")
            }

            if httpResponse.statusCode != 200 {
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMessage = errorJson["error"] as? String {
                    throw AuthError.signInFailed(errorMessage)
                }
                throw AuthError.signInFailed("Sign in failed: \(httpResponse.statusCode)")
            }

            // Parse response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let userDict = json["user"] as? [String: Any],
                  let userId = userDict["id"] as? String,
                  let token = json["token"] as? String,
                  let sessionId = json["session_id"] as? String else {
                throw AuthError.signInFailed("Invalid response from server")
            }

            let user = ClerkUser(
                id: userId,
                email: userDict["email"] as? String ?? email,
                firstName: userDict["first_name"] as? String,
                lastName: userDict["last_name"] as? String,
                imageUrl: userDict["image_url"] as? String
            )

            print("[Auth] Sign-in successful for user: \(userId)")

            await MainActor.run {
                completeSignIn(user: user, token: token, sessionId: sessionId)
                isLoading = false
                print("[Auth] isLoading set to false, isAuthenticated: \(isAuthenticated)")
            }
        } catch {
            await MainActor.run {
                isLoading = false
                print("[Auth] isLoading set to false due to error: \(error)")
            }
            throw error
        }
    }

    /// Complete sign-in with OAuth (called from SignInView after web auth)
    /// Note: OAuth flows may not have a sessionId, so token refresh won't work for those
    func completeOAuthSignIn(token: String, user: ClerkUser, sessionId: String? = nil) {
        completeSignIn(user: user, token: token, sessionId: sessionId)
    }

    private func completeSignIn(user: ClerkUser, token: String, sessionId: String?) {
        print("[Auth] Completing sign-in for: \(user.email)")
        self.currentUser = user
        self.sessionToken = token
        self.sessionId = sessionId
        self.isAuthenticated = true

        // Store in Keychain
        KeychainHelper.save(key: tokenKey, value: token)
        if let sessionId = sessionId {
            KeychainHelper.save(key: sessionIdKey, value: sessionId)
        }
        if let userData = try? JSONEncoder().encode(user) {
            KeychainHelper.saveData(key: userKey, data: userData)
            print("[Auth] Saved user to Keychain")
        }

        // Update BackendService
        BackendService.shared = BackendService(
            environment: .dev,
            apiKey: nil,
            authToken: token
        )

        // Start periodic token refresh (only if we have a session for refresh)
        if sessionId != nil {
            startTokenRefresh()
        } else {
            print("[Auth] No session ID - token refresh disabled (OAuth flow)")
        }

        print("[Auth] Sign-in complete - isAuthenticated: \(isAuthenticated)")
    }

    /// Sign out and clear stored session
    func signOut() {
        // Stop refresh timer
        stopTokenRefresh()

        currentUser = nil
        sessionToken = nil
        sessionId = nil
        isAuthenticated = false

        // Clear Keychain
        KeychainHelper.delete(key: tokenKey)
        KeychainHelper.delete(key: userKey)
        KeychainHelper.delete(key: sessionIdKey)

        // Reset BackendService
        BackendService.shared = BackendService(environment: .dev)
    }

    // MARK: - Token Refresh

    private func startTokenRefresh() {
        stopTokenRefresh()  // Clear any existing timer

        print("[Auth] Starting token refresh timer (every \(refreshInterval)s)")
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.refreshToken()
            }
        }
    }

    private func stopTokenRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Refresh the JWT token using the stored session
    /// Fails silently on network errors to allow offline note-taking
    func refreshToken() async {
        guard let sessionId = sessionId else {
            print("[Auth] No session ID, cannot refresh")
            return
        }

        print("[Auth] Refreshing token...")

        do {
            let backendURL = BackendService.shared.baseURL
            let refreshURL = URL(string: "\(backendURL)/auth/refresh")!

            var request = URLRequest(url: refreshURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10  // Short timeout for refresh

            let body: [String: Any] = ["session_id": sessionId]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[Auth] Refresh failed: invalid response (offline?)")
                return  // Fail silently, keep existing token
            }

            if httpResponse.statusCode == 401 {
                // Session explicitly revoked - sign out
                print("[Auth] Session revoked (401), signing out")
                await MainActor.run {
                    signOut()
                }
                return
            }

            guard httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newToken = json["token"] as? String else {
                // Server error - fail silently, keep existing token
                print("[Auth] Refresh returned \(httpResponse.statusCode), keeping existing token")
                return
            }

            await MainActor.run {
                self.sessionToken = newToken
                KeychainHelper.save(key: self.tokenKey, value: newToken)

                // Update BackendService with new token
                BackendService.shared = BackendService(
                    environment: .dev,
                    apiKey: nil,
                    authToken: newToken
                )
                print("[Auth] Token refreshed successfully")
            }
        } catch {
            // Network error (offline) - fail silently, user can still take notes
            print("[Auth] Refresh failed (offline?): \(error.localizedDescription)")
            // Don't sign out - let user continue with local note-taking
        }
    }
}

// MARK: - Models

struct ClerkUser: Codable, Identifiable {
    let id: String
    let email: String
    let firstName: String?
    let lastName: String?
    let imageUrl: String?

    var displayName: String {
        if let first = firstName, let last = lastName {
            return "\(first) \(last)"
        }
        return firstName ?? email
    }

    var initials: String {
        let first = firstName?.prefix(1) ?? ""
        let last = lastName?.prefix(1) ?? ""
        if first.isEmpty && last.isEmpty {
            return String(email.prefix(1)).uppercased()
        }
        return "\(first)\(last)".uppercased()
    }
}

// Clerk API response models
struct ClerkSignInResponse: Codable {
    let client: ClerkClient?
}

struct ClerkClient: Codable {
    let sessions: [ClerkSession]?
}

struct ClerkSession: Codable {
    let user: ClerkSessionUser?
    let lastActiveToken: ClerkToken?

    enum CodingKeys: String, CodingKey {
        case user
        case lastActiveToken = "last_active_token"
    }
}

struct ClerkSessionUser: Codable {
    let id: String
    let firstName: String?
    let lastName: String?
    let imageUrl: String?

    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case imageUrl = "image_url"
    }
}

struct ClerkToken: Codable {
    let jwt: String
}

// MARK: - Errors

enum AuthError: LocalizedError {
    case invalidResponse
    case signInFailed(String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from authentication server"
        case .signInFailed(let message):
            return message
        case .notAuthenticated:
            return "Not authenticated"
        }
    }
}

// MARK: - Keychain Helper

struct KeychainHelper {
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        saveData(key: key, data: data)
    }

    static func saveData(key: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        guard let data = loadData(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func loadData(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
