import Foundation

enum Browser: String, CaseIterable, Codable, Sendable {
    case chrome = "com.google.Chrome"
    case safari = "com.apple.Safari"
    case aside = "at.studio.AsideBrowser"

    var name: String {
        switch self {
        case .chrome: "Google Chrome"
        case .safari: "Safari"
        case .aside: "Aside"
        }
    }
}

struct BrowserTab: Codable, Equatable, Sendable {
    let title: String
    let url: String

    var isTransferable: Bool {
        guard let components = URLComponents(string: url),
              let host = components.host, !host.isEmpty
        else { return false }
        return ["http", "https"].contains(components.scheme?.lowercased())
    }
}

struct SessionSummary: Sendable {
    let key: String
    let name: String
    let sourceBrowser: Browser
    let createdAt: Date
    let tabCount: Int
}

struct TabSession: Codable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let id: UUID
    fileprivate(set) var name: String
    let sourceBrowser: Browser
    let createdAt: Date
    let tabs: [BrowserTab]

    init(browser: Browser, createdAt: Date, tabs: [BrowserTab]) throws {
        guard tabs.contains(where: \.isTransferable) else {
            throw LifTapError.noTransferableTabs
        }
        schemaVersion = Self.currentSchemaVersion
        id = UUID()
        sourceBrowser = browser
        self.createdAt = createdAt
        self.tabs = tabs
        let representative = tabs.lazy.filter(\.isTransferable)
            .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        name = representative.map { String($0.prefix(90)) }
            ?? browser.name + " · " + createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    var key: String {
        let microseconds = Int64(createdAt.timeIntervalSince1970 * 1_000_000)
        return String(format: "%020lld", microseconds) + "-" + id.uuidString + ".json"
    }

    var summary: SessionSummary {
        SessionSummary(key: key, name: name, sourceBrowser: sourceBrowser,
                       createdAt: createdAt, tabCount: tabs.count)
    }
}

struct SessionPage: Sendable {
    var sessions: [SessionSummary] = []
    var nextCursor: String?
    var unreadableCount = 0
}

enum SessionSection: Sendable {
    case grouped, single

    init(tabCount: Int) { self = tabCount == 1 ? .single : .grouped }
}

struct SessionStore: Sendable {
    let directory: URL

    static let local = SessionStore(directory: URL.applicationSupportDirectory
        .appending(path: "LifTap/Sessions", directoryHint: .isDirectory))

    func save(_ session: TabSession) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(session)
            try data.write(to: directory.appendingPathComponent(session.key), options: .atomic)
        } catch {
            throw LifTapError.storageWrite
        }
    }

    func load(_ key: String) throws -> TabSession {
        guard Self.isSessionKey(key) else { throw LifTapError.storageRead }
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent(key))
            let session = try JSONDecoder().decode(TabSession.self, from: data)
            guard session.schemaVersion == TabSession.currentSchemaVersion, session.key == key else {
                throw LifTapError.storageRead
            }
            return session
        } catch {
            throw LifTapError.storageRead
        }
    }

    func rename(_ key: String, to proposedName: String) throws -> SessionSummary {
        var session = try load(key)
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LifTapError.emptySessionName }
        if session.name != name {
            session.name = name
            try save(session)
        }
        return session.summary
    }

    func delete(_ key: String) throws {
        guard Self.isSessionKey(key) else { throw LifTapError.storageDelete }
        let file = directory.appendingPathComponent(key)
        do {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw LifTapError.storageDelete
            }
            try FileManager.default.removeItem(at: file)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return
        } catch {
            throw LifTapError.storageDelete
        }
    }

    func latest() throws -> TabSession {
        guard let key = try newestKeys(limit: 1, before: nil).first else {
            throw LifTapError.noSessions
        }
        return try load(key)
    }

    func page(before: String?, section: SessionSection? = nil) throws -> SessionPage {
        if let section {
            var result = SessionPage()
            let entries = try newestEntries(limit: 11, before: before) { key -> SessionSummary? in
                do {
                    let summary = try autoreleasepool { try load(key).summary }
                    return SessionSection(tabCount: summary.tabCount) == section ? summary : nil
                } catch {
                    result.unreadableCount += 1
                    return nil
                }
            }
            result.sessions = entries.prefix(10).map(\.value)
            if entries.count == 11 { result.nextCursor = entries[9].key }
            return result
        }
        let keys = try newestKeys(limit: 11, before: before)
        var result = SessionPage()
        for key in keys.prefix(10) {
            do {
                let summary = try autoreleasepool { try load(key).summary }
                result.sessions.append(summary)
            } catch {
                result.unreadableCount += 1
            }
        }
        if keys.count == 11 { result.nextCursor = keys[9] }
        return result
    }

    private func newestKeys(limit: Int, before: String?) throws -> [String] {
        try newestEntries(limit: limit, before: before) { $0 }.map(\.key)
    }

    private func newestEntries<Value>(
        limit: Int, before: String?, read: (String) -> Value?
    ) throws -> [(key: String, value: Value)] {
        var matches: [(key: String, value: Value)] = []
        var listingError: NSError?
        let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [],
                                                     options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) { _, error in
            listingError = error as NSError
            return false
        }
        guard let entries else { throw LifTapError.storageRead }
        // Keep at most one page of matches, even when one section has few sessions.
        while let key = autoreleasepool(invoking: { (entries.nextObject() as? URL)?.lastPathComponent }) {
            guard Self.isSessionKey(key), before.map({ key < $0 }) ?? true else { continue }
            let index = matches.firstIndex { $0.key < key } ?? matches.endIndex
            guard index < limit, let value = read(key) else { continue }
            matches.insert((key, value), at: index)
            if matches.count > limit { matches.removeLast() }
        }
        if let listingError {
            if listingError.domain == NSCocoaErrorDomain,
               [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(listingError.code) { return [] }
            throw LifTapError.storageRead
        }
        return matches
    }

    private static func isSessionKey(_ key: String) -> Bool {
        guard key.utf8.count == 62, key.hasSuffix(".json"), !key.contains("/") else { return false }
        let stamp = key.prefix(20)
        return stamp.utf8.allSatisfy { (48...57).contains($0) }
            && key.dropFirst(20).first == "-"
            && UUID(uuidString: String(key.dropFirst(21).dropLast(5))) != nil
    }
}

enum LifTapError: LocalizedError {
    case windowHasUnrestorableTabs
    case emptySessionName
    case unsupportedBrowser, noWindow, noTransferableTabs, noSessions
    case browserUnavailable(Browser), permissionDenied(Browser), timedOut(Browser), newWindowNotIdentified(Browser)
    case browserFailed(Browser, Int?), workerFailed, storageRead, storageWrite, storageDelete

    var errorDescription: String? {
        switch self {
        case .windowHasUnrestorableTabs: "복원할 수 없는 탭이 있어 창을 그대로 두었어요."
        case .emptySessionName: "세션 이름을 입력해 주세요."
        case .unsupportedBrowser: "Chrome, Safari 또는 Aside 창을 활성화한 뒤 다시 담아 주세요."
        case .noWindow: "현재 브라우저에 담을 수 있는 창이 없어요."
        case .noTransferableTabs: "담을 수 있는 웹 주소(HTTP 또는 HTTPS)가 없어요."
        case .noSessions: "저장한 세션이 없어요. 브라우저에서 먼저 탭을 담아 주세요."
        case let .browserUnavailable(browser): "\(browser.name)을(를) 사용할 수 없어요."
        case let .permissionDenied(browser):
            "시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 LifTap의 \(browser.name) 제어를 허용해 주세요."
        case let .timedOut(browser): "\(browser.name)의 응답 시간이 초과됐어요."
        case let .newWindowNotIdentified(browser):
            "\(browser.name)의 새 창을 확인할 수 없어요. 브라우저를 확인한 뒤 다시 시도해 주세요."
        case let .browserFailed(browser, code):
            "\(browser.name)이(가) 작업을 완료하지 못했어요" + (code.map { " (오류 \($0))." } ?? ".")
        case .workerFailed: "브라우저 작업의 결과를 확인할 수 없어요. 다시 열기 전에 브라우저를 확인해 주세요."
        case .storageRead: "저장된 세션을 읽을 수 없어요."
        case .storageWrite: "세션을 저장하지 못했어요. 디스크 공간과 저장 폴더 권한을 확인해 주세요."
        case .storageDelete: "세션을 삭제하지 못했어요."
        }
    }
}
