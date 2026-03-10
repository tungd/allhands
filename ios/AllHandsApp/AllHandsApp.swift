import SwiftUI

@main
struct AllHandsApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
