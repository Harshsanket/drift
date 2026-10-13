import SwiftUI

@main
struct DriftApp: App {
    @State private var model = ListViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 700)
    }
}
