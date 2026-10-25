import SwiftData
import SwiftUI

@main
struct MunshiApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .modelContainer(for: Book.self)
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
