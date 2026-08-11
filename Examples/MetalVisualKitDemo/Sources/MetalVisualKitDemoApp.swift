import SwiftUI

@main
struct MetalVisualKitDemoApp: App {
    var body: some Scene {
        WindowGroup {
            MetalVisualShowcase()
                .preferredColorScheme(.dark)
        }
    }
}
