import AppKit

struct BrowserDestination {
    let url: URL
    let browser: Browser

    var name: String { browser.name }

    init?(url: URL) {
        guard url.isFileURL, let bundle = Bundle(url: url),
              bundle.infoDictionary?["CFBundlePackageType"] as? String == "APPL",
              let identifier = bundle.bundleIdentifier,
              let browser = Browser(rawValue: identifier) else { return nil }
        self.url = url
        self.browser = browser
    }

    @MainActor
    static func installed() -> [Self] {
        Browser.allCases.compactMap { browser in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.rawValue)
                .flatMap { Self(url: $0) }
        }
    }
}
