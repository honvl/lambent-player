import StoreKitTest
import XCTest

/// Presses the Siri Remote on the simulator, in the Lambent app (or `DRIVE_APP`), step by step.
///
/// `DRIVE_STEPS` is a comma list: `up`, `down`, `left`, `right`, `select`, `menu`, `play`, `home` (each with an optional
/// `:count`), `hold:seconds` (select held), `relaunch`, `type:text` (no commas), `wait:seconds`, and `shot:name` (a PNG in `DRIVE_OUT`). `DRIVE_LAUNCH=1`
/// launches the app afresh; otherwise it is brought forward as it is.
final class Driver: XCTestCase {
    func testDrive() throws {
        let env = ProcessInfo.processInfo.environment
        // `DRIVE_STOREKIT` names a .storekit file: purchases then complete against a local test store, with no Apple account.
        // The session lives as long as the test, so one drive does the whole purchase.
        var session: SKTestSession?
        if let file = env["DRIVE_STOREKIT"], !file.isEmpty {
            let s = try SKTestSession(contentsOf: URL(fileURLWithPath: file))
            s.disableDialogs = false
            s.clearTransactions()
            session = s
        }
        defer { withExtendedLifetime(session) {} }
        let app = XCUIApplication(bundleIdentifier: env["DRIVE_APP"] ?? "app.getlambent.viewer")
        if env["DRIVE_LAUNCH"] == "1" { app.launch() } else { app.activate() }
        let out = URL(fileURLWithPath: env["DRIVE_OUT"] ?? NSTemporaryDirectory())
        let remote = XCUIRemote.shared
        for step in (env["DRIVE_STEPS"] ?? "").split(separator: ",") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let arg = parts.count > 1 ? parts[1] : ""
            let count = Int(arg) ?? 1
            let button: XCUIRemote.Button? = switch name {
            case "up": .up
            case "down": .down
            case "left": .left
            case "right": .right
            case "select": .select
            case "menu": .menu
            case "play": .playPause
            case "home": .home
            default: nil
            }
            if let button {
                for _ in 0..<count {
                    remote.press(button)
                    usleep(350_000)
                }
            } else if name == "hold" {
                remote.press(.select, forDuration: Double(arg) ?? 1)
            } else if name == "type" {
                // Into the focused text field, through the system keyboard.
                app.typeText(arg)
            } else if name == "relaunch" {
                // The app is closed and opened again, as when someone leaves it and comes back.
                app.terminate()
                app.launch()
            } else if name == "wait" {
                usleep(useconds_t((Double(arg) ?? 1) * 1_000_000))
            } else if name == "shot" {
                let png = XCUIScreen.main.screenshot().pngRepresentation
                try png.write(to: out.appendingPathComponent("\(arg.isEmpty ? "shot" : arg).png"))
            } else {
                XCTFail("unknown step \(name)")
            }
        }
    }
}
