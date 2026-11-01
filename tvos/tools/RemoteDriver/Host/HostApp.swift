import SwiftUI

/// UI tests need an app of their own to run beside; the driver works on another app by its bundle id.
@main
struct HostApp: App {
    var body: some Scene {
        WindowGroup { Text("Remote driver") }
    }
}
