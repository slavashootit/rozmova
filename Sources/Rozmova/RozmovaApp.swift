import AppKit

@main
struct RozmovaMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only; DockPresence adds the Dock icon and main menu while a window is open.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
