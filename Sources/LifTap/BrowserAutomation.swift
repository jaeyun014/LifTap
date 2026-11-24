import Foundation
import Carbon
import Darwin

struct RestoreReport: Codable, Sendable {
    var opened: Int
    var failed: Int
    var skipped: Int
    var unconfirmed: Int
    var errorCode: Int?

    var message: String {
        var parts = ["\(opened)개 열림"]
        if skipped > 0 { parts.append("\(skipped)개 건너뜀") }
        if failed > 0 { parts.append("\(failed)개 실패") }
        if unconfirmed > 0 { parts.append("\(unconfirmed)개 결과 미확인") }
        return parts.joined(separator: " · ")
    }
}

enum CaptureScope: String, Codable, Sendable {
    case window, activeTab, cutTab
}

enum BrowserAutomation {
    struct CutTab: Codable, Sendable {
        let tab: BrowserTab
        let identity: [String]
    }

    private struct Request: Codable {
        let browser: Browser
        let urls: [String]? // nil captures from the front window
        var captureScope: CaptureScope? = nil
        var closeTab: CutTab? = nil
    }

    private struct Response: Codable {
        var tabs: [BrowserTab]?
        var report: RestoreReport?
        var errorCode: Int?
        var cutTab: CutTab?
        var closed: Bool?
    }

    static func cutCandidate(in browser: Browser) throws -> CutTab {
        let response = try run(Request(browser: browser, urls: nil, captureScope: .cutTab))
        guard let candidate = response.cutTab, candidate.tab.isTransferable else {
            throw LifTapError.noTransferableTabs
        }
        return candidate
    }

    static func close(_ candidate: CutTab, in browser: Browser) throws -> Bool {
        try run(Request(browser: browser, urls: nil, closeTab: candidate)).closed == true
    }

    static func capture(in browser: Browser, scope: CaptureScope) throws -> [BrowserTab] {
        let response = try run(Request(browser: browser, urls: nil, captureScope: scope))
        guard let tabs = response.tabs else { throw LifTapError.workerFailed }
        return tabs
    }

    static func restore(_ session: TabSession, in browser: Browser) throws -> RestoreReport {
        let urls = session.tabs.compactMap { $0.isTransferable ? $0.url : nil }
        let skipped = session.tabs.count - urls.count
        guard !urls.isEmpty else {
            return RestoreReport(opened: 0, failed: 0, skipped: skipped, unconfirmed: 0)
        }
        let response = try run(Request(browser: browser, urls: urls))
        guard var report = response.report,
              report.opened + report.failed + report.unconfirmed == urls.count
        else { throw LifTapError.workerFailed }
        report.skipped = skipped
        return report
    }

    static func error(for code: Int?, browser: Browser) -> LifTapError {
        switch code {
        case -1743, -1744, -10004: .permissionDenied(browser)
        case -1712: .timedOut(browser)
        case -600, -609: .browserUnavailable(browser)
        case -10001: .noWindow
        case -10002: .newWindowNotIdentified(browser)
        default: .browserFailed(browser, code)
        }
    }

    private static func run(_ request: Request) throws -> Response {
        guard let executable = Bundle.main.executableURL else { throw LifTapError.workerFailed }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--automation-worker"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let response: Response
        do {
            let data = try JSONEncoder().encode(request)
            // A worker that exits early must not take the menu bar app down with it.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try process.run()
            do {
                try input.fileHandleForWriting.write(contentsOf: data)
                try input.fileHandleForWriting.close()
            } catch {
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
                throw error
            }
            let reply = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw LifTapError.workerFailed }
            response = try JSONDecoder().decode(Response.self, from: reply)
        } catch {
            throw LifTapError.workerFailed
        }
        if let code = response.errorCode { throw error(for: code, browser: request.browser) }
        return response
    }

    // This is the main thread of the short-lived worker. The UI process never loads a script.
    static func serve() throws {
        let request = try JSONDecoder().decode(Request.self,
                                               from: FileHandle.standardInput.readDataToEndOfFile())
        let script: String
        let handler: String
        let args = NSAppleEventDescriptor.list()
        if let candidate = request.closeTab {
            guard candidate.tab.isTransferable, candidate.identity.count == 4 else { throw LifTapError.workerFailed }
            script = cutScript(for: request.browser)
            handler = "closecapturedtab"
            let expected = candidate.identity + [candidate.tab.url, candidate.tab.title]
            let items = NSAppleEventDescriptor.list()
            for (index, value) in expected.enumerated() {
                items.insert(NSAppleEventDescriptor(string: value), at: index + 1)
            }
            args.insert(items, at: 1)
        } else if let urls = request.urls {
            script = restoreScript(for: request.browser)
            handler = "restoretabs"
            guard !urls.isEmpty, urls.allSatisfy({ BrowserTab(title: "", url: $0).isTransferable })
            else { throw LifTapError.workerFailed }
            let list = NSAppleEventDescriptor.list()
            for (index, url) in urls.enumerated() {
                list.insert(NSAppleEventDescriptor(string: url), at: index + 1)
            }
            args.insert(list, at: 1)
        } else if request.captureScope == .cutTab {
            script = cutScript(for: request.browser)
            handler = "inspectcurrenttab"
        } else {
            script = captureScript(for: request.browser, scope: request.captureScope ?? .window)
            handler = "capturetabs"
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                           eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(args, forKeyword: AEKeyword(keyDirectObject))

        var errorInfo: NSDictionary?
        let value = NSAppleScript(source: script)?.executeAppleEvent(event, error: &errorInfo)
        let response: Response
        if let errorInfo {
            response = Response(errorCode: errorInfo[NSAppleScript.errorNumber] as? Int ?? -1)
        } else if request.closeTab != nil {
            response = Response(closed: value?.booleanValue)
        } else if request.captureScope == .cutTab {
            guard let value, value.numberOfItems == 6 else { throw LifTapError.workerFailed }
            let fields = (1...6).compactMap { value.atIndex($0)?.stringValue }
            guard fields.count == 6 else { throw LifTapError.workerFailed }
            response = Response(cutTab: CutTab(tab: BrowserTab(title: fields[5], url: fields[4]),
                                               identity: Array(fields.prefix(4))))
        } else if let urls = request.urls {
            guard let value, value.numberOfItems == 4,
                  let opened = value.atIndex(1)?.int32Value,
                  let failed = value.atIndex(2)?.int32Value,
                  let unconfirmed = value.atIndex(3)?.int32Value,
                  let code = value.atIndex(4)?.int32Value,
                  opened >= 0, failed >= 0, unconfirmed >= 0,
                  Int(opened) + Int(failed) + Int(unconfirmed) == urls.count
            else { throw LifTapError.workerFailed }
            response = Response(report: RestoreReport(opened: Int(opened), failed: Int(failed),
                                                       skipped: 0, unconfirmed: Int(unconfirmed),
                                                       errorCode: code == 0 ? nil : Int(code)))
        } else {
            guard let value, value.descriptorType == DescType(typeAEList) else { throw LifTapError.workerFailed }
            var tabs: [BrowserTab] = []
            for index in 0..<value.numberOfItems {
                guard let pair = value.atIndex(index + 1), pair.numberOfItems == 2,
                      let url = pair.atIndex(2)?.stringValue, !url.isEmpty
                else { continue }
                tabs.append(BrowserTab(title: pair.atIndex(1)?.stringValue ?? "", url: url))
            }
            response = Response(tabs: tabs)
        }
        try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(response))
    }

    static func captureScript(for browser: Browser, scope: CaptureScope) -> String {
        let titleProperty = browser == .safari ? "name" : "title"
        let snapshot: String
        switch scope {
        case .window:
            snapshot = "set snapshot to get every tab of window id sourceID"
        case .activeTab, .cutTab:
            let selectedTabProperty = browser == .safari ? "current tab" : "active tab"
            snapshot = """
            set selectedTab to get \(selectedTabProperty) of window id sourceID
            set snapshot to {selectedTab}
            """
        }
        return """
        on captureTabs()
            with timeout of 12 seconds
                tell application id "\(browser.rawValue)"
                    try
                        set sourceID to id of front window
                    on error errorText number errorCode
                        if errorCode is -1728 or errorCode is -1719 then error number -10001
                        error errorText number errorCode
                    end try
                    \(snapshot)
                    set captured to {}
                    repeat with sourceTab in snapshot
                        try
                            set tabURL to URL of sourceTab
                            if tabURL is not missing value and tabURL is not "" then
                                set tabTitle to ""
                                try
                                    set tabTitle to \(titleProperty) of sourceTab
                                on error errorText number errorCode
                                    if errorCode is not -1728 and errorCode is not -1719 and errorCode is not -1700 then error errorText number errorCode
                                end try
                                if tabTitle is missing value then set tabTitle to ""
                                set end of captured to {tabTitle, tabURL}
                            end if
                        on error errorText number errorCode
                            if errorCode is not -1728 and errorCode is not -1719 and errorCode is not -1700 then error errorText number errorCode
                        end try
                    end repeat
                    return captured
                end tell
            end timeout
        end captureTabs
        """
    }

    private static func cutScript(for browser: Browser) -> String {
        let tabProperty = browser == .safari ? "current tab" : "active tab"
        let titleProperty = browser == .safari ? "name" : "title"
        let identity = browser == .safari
            ? "{(index of chosenTab) as text, (pid of chosenTab) as text, (count of tabs of chosenWindow) as text}"
            : "{(id of chosenTab) as text, \"\", \"\"}"
        return """
        on inspectCurrentTab()
            with timeout of 12 seconds
                tell application id "\(browser.rawValue)"
                    try
                        set windowID to id of front window
                    on error errorText number errorCode
                        if errorCode is -1728 or errorCode is -1719 then error number -10001
                        error errorText number errorCode
                    end try
                    set chosenWindow to window id windowID
                    set chosenTab to get \(tabProperty) of chosenWindow
                    return my describeTab(windowID, chosenWindow, chosenTab)
                end tell
            end timeout
        end inspectCurrentTab

        on closeCapturedTab(expected)
            with timeout of 12 seconds
                tell application id "\(browser.rawValue)"
                    if not frontmost then return false
                    set windowID to id of front window
                    set chosenWindow to window id windowID
                    set chosenTab to get \(tabProperty) of chosenWindow
                    set actual to my describeTab(windowID, chosenWindow, chosenTab)
                    considering case
                        if actual is not equal to expected then return false
                    end considering
                    close chosenTab
                    return true
                end tell
            end timeout
        end closeCapturedTab

        on describeTab(windowID, chosenWindow, chosenTab)
            tell application id "\(browser.rawValue)"
                set tabURL to URL of chosenTab
                set tabTitle to \(titleProperty) of chosenTab
                if tabURL is missing value then set tabURL to ""
                if tabTitle is missing value then set tabTitle to ""
                return {(windowID as text)} & \(identity) & {tabURL, tabTitle}
            end tell
        end describeTab
        """
    }

    static func restoreScript(for browser: Browser) -> String {
        let createWindow: String
        let raiseWindow: String
        switch browser {
        case .chrome, .aside:
            createWindow = "set targetID to id of (make new window)"
            raiseWindow = ""
        case .safari:
            // Safari returns a document, not a window. Only use an unambiguous new window ID.
            createWindow = """
            set existingIDs to get id of every window
            make new document
            set newIDs to {}
            set currentIDs to get id of every window
            repeat with windowID in currentIDs
                if existingIDs does not contain (contents of windowID) then set end of newIDs to (contents of windowID)
            end repeat
            if (count of newIDs) is not 1 then error number -10002
            set targetID to first item of newIDs
            """
            // Changing the index while Safari is in the background has no effect.
            raiseWindow = """
            if openedCount > 0 then
                try
                    activate
                    set index of window id targetID to 1
                end try
            end if
            """
        }
        return """
        on restoreTabs(addresses)
            set openedCount to 0
            set failedCount to 0
            set unknownCount to 0
            set lastError to 0
            set addressCount to count of addresses
            set reuseInitialTab to true
            with timeout of 12 seconds
                tell application id "\(browser.rawValue)"
                    try
                        \(createWindow)
                    on error number errorCode
                        if errorCode is -1712 then return {0, 0, addressCount, errorCode}
                        return {0, addressCount, 0, errorCode}
                    end try
                    repeat with indexNumber from 1 to addressCount
                        set addressText to item indexNumber of addresses
                        try
                            tell window id targetID
                                if reuseInitialTab then
                                    set URL of first tab to addressText
                                else
                                    make new tab at end of tabs with properties {URL:addressText}
                                end if
                            end tell
                            set reuseInitialTab to false
                            set openedCount to openedCount + 1
                        on error number errorCode
                            if errorCode is -1712 then
                                set unknownCount to 1
                                set failedCount to failedCount + (addressCount - indexNumber)
                                set lastError to errorCode
                                exit repeat
                            end if
                            set failedCount to failedCount + 1
                            set lastError to errorCode
                            if errorCode is -1728 or errorCode is -1719 or errorCode is -1743 or errorCode is -1744 or errorCode is -10004 or errorCode is -600 or errorCode is -609 then
                                set failedCount to failedCount + (addressCount - indexNumber)
                                exit repeat
                            end if
                        end try
                    end repeat
                    \(raiseWindow)
                end tell
            end timeout
            return {openedCount, failedCount, unknownCount, lastError}
        end restoreTabs
        """
    }
}
