import AppKit
import UniformTypeIdentifiers

struct BrowserDestination: Sendable {
    let url: URL
    let name: String
    let scriptedBrowser: Browser?

    init?(url: URL) {
        guard url.isFileURL, let bundle = Bundle(url: url),
              bundle.infoDictionary?["CFBundlePackageType"] as? String == "APPL",
              let identifier = bundle.bundleIdentifier,
              identifier != Bundle.main.bundleIdentifier else { return nil }
        self.url = url
        scriptedBrowser = Browser(rawValue: identifier)
        name = scriptedBrowser?.name
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    @MainActor
    static func installed() -> [Self] {
        let workspace = NSWorkspace.shared
        let known = Browser.allCases.compactMap { workspace.urlForApplication(withBundleIdentifier: $0.rawValue) }
        let htmlHandlers = Set(workspace.urlsForApplications(toOpen: UTType.html).map { $0.resolvingSymlinksInPath() })
        let webHandlers = workspace.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            .filter { htmlHandlers.contains($0.resolvingSymlinksInPath()) }
        var seen = Set<URL>()
        return (known + webHandlers).compactMap { url in
            guard seen.insert(url.resolvingSymlinksInPath()).inserted else { return nil }
            return Self(url: url)
        }
    }

    @MainActor
    func open(_ urls: [URL]) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.open(urls, withApplicationAt: url, configuration: configuration)
    }
}
