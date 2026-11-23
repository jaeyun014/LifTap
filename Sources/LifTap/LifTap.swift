import AppKit
import Foundation

@main
enum LifTap {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--automation-worker" {
            do { try BrowserAutomation.serve() } catch { exit(EXIT_FAILURE) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppController()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
