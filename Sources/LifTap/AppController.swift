import AppKit

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let store = SessionStore.local
    private var statusItem: NSStatusItem?
    private var hotKeys: HotKeys?
    private var panel: SessionPanel?
    private let feedback = Feedback()
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hotKeys = HotKeys { [weak self] command in self?.run(command) }
        self.hotKeys = hotKeys
        let registered = hotKeys.register()
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "LifTap")
            button.toolTip = "LifTap"
        }

        let menu = NSMenu()
        for command in Command.allCases {
            let title = registered.contains(command) ? command.title + "   " + command.shortcut : command.title
            let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(command.rawValue)
            menu.addItem(item)
        }
        let unavailable = Command.allCases.filter { !registered.contains($0) }
        if !unavailable.isEmpty {
            menu.addItem(.separator())
            for command in unavailable {
                menu.addItem(NSMenuItem(title: "단축키 사용 불가  " + command.shortcut,
                                        action: nil, keyEquivalent: ""))
            }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "LifTap 종료", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: ""))
        statusItem.menu = menu
        if !unavailable.isEmpty {
            announce("등록하지 못한 단축키가 있어요. 메뉴 막대에서 같은 기능을 실행할 수 있어요.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys?.unregister()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let browser = NSWorkspace.shared.frontmostApplication?.bundleIdentifier.flatMap(Browser.init(rawValue:))
        showPanel(defaultBrowser: browser)
        return false
    }

    @objc private func menuCommand(_ item: NSMenuItem) {
        if let command = Command(rawValue: UInt32(item.tag)) { run(command) }
    }

    private func run(_ command: Command) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let browser = frontmost?.bundleIdentifier.flatMap(Browser.init(rawValue:))
        switch command {
        case .capture:
            guard let browser else {
                announce(LifTapError.unsupportedBrowser.localizedDescription, isError: true)
                return
            }
            let capturedAt = Date()
            perform {
                let tabs = try BrowserAutomation.capture(in: browser)
                let session = try TabSession(browser: browser, createdAt: capturedAt, tabs: tabs)
                try self.store.save(session)
                return .captured(session.tabs.count)
            }
        case .restoreLatest:
            if let browser {
                restore(key: nil, in: browser)
            } else {
                showPanel(defaultBrowser: nil, chooseTarget: true)
            }
        case .showSessions:
            if let panel, panel.isKeyWindow {
                panel.close()
            } else {
                showPanel(defaultBrowser: browser)
            }
        }
    }

    private func showPanel(defaultBrowser: Browser?, chooseTarget: Bool = false) {
        if let panel {
            if chooseTarget {
                panel.prepareTarget(nil)
                panel.reload()
            } else if !panel.isKeyWindow {
                panel.prepareTarget(defaultBrowser)
            }
            panel.show(chooseTarget: chooseTarget)
            return
        }
        feedback.dismiss()
        let panel = SessionPanel(store: store, defaultBrowser: defaultBrowser)
        self.panel = panel
        panel.onRestore = { [weak self] key, browser in self?.restore(key: key, in: browser) }
        panel.onClose = { [weak self] in self?.panel = nil }
        panel.setBusy(busy)
        panel.show(chooseTarget: chooseTarget)
    }

    private func restore(key: String?, in browser: Browser) {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.rawValue) != nil else {
            announce(LifTapError.browserUnavailable(browser).localizedDescription, isError: true)
            return
        }
        perform {
            let session = try key.map(self.store.load) ?? self.store.latest()
            return .restored(try BrowserAutomation.restore(session, in: browser), browser)
        }
    }

    private enum OperationResult: Sendable {
        case captured(Int)
        case restored(RestoreReport, Browser)
    }

    private func perform(_ action: @escaping @Sendable () throws -> OperationResult) {
        guard !busy else {
            announce("브라우저 작업이 진행 중이에요.")
            return
        }
        busy = true
        panel?.setBusy(true)
        announce("브라우저 작업 중…")
        Task {
            defer {
                busy = false
                panel?.setBusy(false)
            }
            do {
                let result = try await Task.detached(priority: .userInitiated, operation: action).value
                switch result {
                case let .captured(count):
                    panel?.reload()
                    announce("\(count)개 탭을 저장했어요.")
                case let .restored(report, browser):
                    let issue = report.errorCode.map { BrowserAutomation.error(for: $0, browser: browser).localizedDescription }
                    let text = [report.message, issue].compactMap { $0 }.joined(separator: "\n")
                    if report.opened > 0 {
                        if report.failed == 0 && report.unconfirmed == 0 { panel?.close() }
                        NSRunningApplication.runningApplications(withBundleIdentifier: browser.rawValue).first?.activate()
                        feedback.show(text, relativeTo: statusItem?.button, isError: issue != nil)
                        panel?.setStatus(text, isError: issue != nil)
                    } else {
                        announce(text, isError: true)
                    }
                }
            } catch {
                announce(error.localizedDescription, isError: true)
            }
        }
    }

    private func announce(_ text: String, isError: Bool = false) {
        if let panel, panel.isKeyWindow {
            panel.setStatus(text, isError: isError)
        } else {
            feedback.show(text, relativeTo: statusItem?.button, isError: isError)
        }
    }
}
