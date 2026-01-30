//
//  SignInView.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/29/26.
//

import SwiftUI
import AuthenticationServices

struct SignInView: View {
    @Environment(AuthManager.self) private var authManager

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isSigningIn: Bool = false
    @State private var errorMessage: String?
    @State private var showingError: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo and title
            VStack(spacing: 16) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.yellow)

                Text("FiatLux")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("From tablets to code")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 48)

            // Sign in form
            VStack(spacing: 16) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.none)  // Disabled to prevent Safari password manager popup
                    .autocapitalization(.none)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.none)  // Disabled to prevent Safari password manager popup

                Button {
                    signInWithEmail()
                } label: {
                    if isSigningIn {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        Text("Sign In")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(email.isEmpty || password.isEmpty || isSigningIn)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 400)

            // Spacer to push footer down
            Spacer()
                .frame(height: 48)

            // OAuth buttons (disabled for now - need redirect URI setup)
            // TODO: Configure fiatlux:// URL scheme and handle OAuth callback
            /*
            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.email, .fullName]
                } onCompletion: { result in
                    handleAppleSignIn(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)

                Button {
                    signInWithGoogle()
                } label: {
                    HStack {
                        Image(systemName: "globe")
                        Text("Continue with Google")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 400)
            */

            Spacer()

            // Footer
            Text("By signing in, you agree to our Terms of Service")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .alert("Sign In Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "An error occurred")
        }
    }

    private func signInWithEmail() {
        guard !email.isEmpty, !password.isEmpty else { return }

        isSigningIn = true
        errorMessage = nil

        Task {
            do {
                print("[SignIn] Attempting sign in for: \(email)")
                try await authManager.signIn(email: email, password: password)
                print("[SignIn] Sign in completed, isAuthenticated: \(authManager.isAuthenticated)")
            } catch {
                print("[SignIn] ERROR: \(error)")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showingError = true
                    print("[SignIn] Showing error alert: \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                isSigningIn = false
                print("[SignIn] Done, isAuthenticated: \(authManager.isAuthenticated)")
            }
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
                // Get identity token
                guard let identityToken = appleIDCredential.identityToken,
                      let tokenString = String(data: identityToken, encoding: .utf8) else {
                    errorMessage = "Failed to get Apple ID token"
                    showingError = true
                    return
                }

                // Exchange Apple token for Clerk session
                // This would typically call your backend which then calls Clerk
                exchangeAppleToken(tokenString, credential: appleIDCredential)
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func exchangeAppleToken(_ token: String, credential: ASAuthorizationAppleIDCredential) {
        // For now, create a mock user from Apple credentials
        // In production, this should call Clerk's OAuth endpoint via your backend
        let email = credential.email ?? "apple-user@icloud.com"
        let user = ClerkUser(
            id: credential.user,
            email: email,
            firstName: credential.fullName?.givenName,
            lastName: credential.fullName?.familyName,
            imageUrl: nil
        )

        // TODO: Exchange Apple token for Clerk JWT via backend
        // For now, use Apple's token directly (backend needs to verify differently)
        authManager.completeOAuthSignIn(token: token, user: user)
    }

    private func signInWithGoogle() {
        // Open Clerk's Google OAuth flow
        // This typically opens a web view or Safari
        let clerkOAuthURL = "https://\(clerkFrontendAPI)/v1/oauth_authorize?provider=oauth_google"

        guard let url = URL(string: clerkOAuthURL) else { return }

        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif

        // Handle callback via deep link in FiatLuxApp.swift
    }

    private var clerkFrontendAPI: String {
        // Extract from publishable key: pk_test_xxx -> xxx.clerk.accounts.dev
        let key = AuthManager.clerkPublishableKey
        if key.hasPrefix("pk_test_") {
            let encoded = String(key.dropFirst(8))
            if let data = Data(base64Encoded: encoded),
               let decoded = String(data: data, encoding: .utf8) {
                return decoded
            }
        }
        return "clerk.accounts.dev"
    }
}

#Preview {
    SignInView()
        .environment(AuthManager.shared)
}
