//
//  FiatLuxApp.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/19/26.
//

import SwiftUI

@main
struct FiatLuxApp: App {
    @State private var authManager = AuthManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authManager)
        }
    }
}

struct RootView: View {
    @Environment(AuthManager.self) private var authManager

    var body: some View {
        Group {
            if authManager.isLoading {
                // Loading state while checking stored session
                VStack {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            } else if authManager.isAuthenticated {
                // User is signed in - show main app
                ContentView()
            } else {
                // User needs to sign in
                SignInView()
            }
        }
    }
}

#Preview("Root - Loading") {
    let manager = AuthManager.shared
    return RootView()
        .environment(manager)
}
