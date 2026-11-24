import FirebaseAppCheck
import FirebaseCore
import SwiftUI

@main
struct PlainlyApp: App {
    init() {
        // Firebase AI Logic enforces App Check. This build uses the debug provider, as the hackathon rules allow: on first
        // launch it prints a debug token to the console, which is registered once in the Firebase console. A store build
        // would use App Attest instead.
        // A shared test build carries the one debug token already registered for this app (from a git-ignored file), so
        // judges' simulators work without their own Firebase setup, as the Android test APK does.
        if let url = Bundle.main.url(forResource: "AppCheckDebugToken", withExtension: "txt"),
           let token = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            UserDefaults.standard.set(token, forKey: "GACAppCheckDebugToken")
        }
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
