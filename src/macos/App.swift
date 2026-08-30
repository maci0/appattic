import SwiftCrossUI
import DefaultBackend

@main
struct AppAtticApp: App {
    var body: some Scene {
        WindowGroup("AppAttic") {
            ContentView()
                .font(.system(size: 13))
        }
        .defaultSize(width: 1180, height: 720)
    }
}
