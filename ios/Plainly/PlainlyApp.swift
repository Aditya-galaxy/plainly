import FirebaseAppCheck
import FirebaseCore
import SwiftUI

@main
struct PlainlyApp: App {
    init() {
        // Firebase AI Logic enforces App Check. This build uses the debug provider, as the hackathon rules allow: on first
        // launch it prints a debug token to the console, which is registered once in the Firebase console. A store build
        // would use App Attest instead.
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
