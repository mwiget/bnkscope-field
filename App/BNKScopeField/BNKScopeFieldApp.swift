import SwiftUI

@main
struct BNKScopeFieldApp: App {
    @State private var store = ClusterStore()
    @State private var engine = TelemetryEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(engine)
                .preferredColorScheme(.dark)
                .tint(Theme.primary)
                .task { store.load(); await store.probeAll() }
        }
        .onChange(of: scenePhase) { _, phase in
            // The iPad sleeping, or the app being swiped away, must stop the
            // scrape loop — otherwise it keeps a tunnel open into a live TMM pod
            // for a session nobody is watching.
            switch phase {
            case .active:                 engine.resume()
            case .inactive, .background:  engine.pause()
            @unknown default:             engine.pause()
            }
        }
    }
}
