import SwiftUI

@main
struct DugApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.collar)
                .tint(Theme.gold)
        }
    }
}

enum Theme {
    /// Dug's golden retriever fur.
    static let gold = Color(red: 0.86, green: 0.60, blue: 0.24)
    /// The voice-box collar.
    static let collar = Color(red: 0.42, green: 0.45, blue: 0.50)
    static let card = Color(.secondarySystemGroupedBackground)
    static let background = Color(.systemGroupedBackground)
}
