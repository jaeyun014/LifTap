import Foundation
import Testing
@testable import LifTap

struct SessionTests {
    private let web = BrowserTab(title: "연구 자료", url: "https://example.test/notes?q=1#start")
    private let browserPage = BrowserTab(title: "설정", url: "chrome://settings/")

    @Test func archivePreservesOrderDuplicatesAndMetadata() throws {
        try withStore { store in
            let tabs = [browserPage, web, web]
            let original = try session(0, tabs: tabs)
            try store.save(original)
            let reopened = SessionStore(directory: store.directory)
            let latest = try reopened.latest()
            #expect(latest.id == original.id)
            #expect(latest.schemaVersion == 1)
            #expect(latest.name == web.title)
            #expect(latest.sourceBrowser == .chrome)
            #expect(latest.createdAt == original.createdAt)
            #expect(latest.tabs == tabs)
        }
    }

    @Test func pagesKeepOlderSessionsAvailable() throws {
        try withStore { store in
            let sessions = try (0..<24).map { try session($0, tabs: [web]) }
            for item in sessions.reversed() { try store.save(item) }
            let first = try store.page(before: nil)
            let second = try store.page(before: first.nextCursor)
            let third = try store.page(before: second.nextCursor)
            #expect(first.sessions.map(\.key) == sessions[14..<24].reversed().map(\.key))
            #expect(second.sessions.map(\.key) == sessions[4..<14].reversed().map(\.key))
            #expect(third.sessions.map(\.key) == sessions[0..<4].reversed().map(\.key))
            #expect(third.nextCursor == nil)
            #expect(try store.latest().id == sessions[23].id)
        }
    }

    @Test func groupedAndSingleSessionsHaveIndependentPages() throws {
        try withStore { store in
            let sessions = try (0..<25).map { index in
                try session(index, tabs: index.isMultiple(of: 2) ? [web] : [web, web])
            }
            for item in sessions.reversed() { try store.save(item) }

            for section in [SessionSection.grouped, .single] {
                let expected = sessions.reversed().filter { SessionSection(tabCount: $0.tabs.count) == section }
                let first = try store.page(before: nil, section: section)
                let second = try store.page(before: first.nextCursor, section: section)
                #expect(first.sessions.count == 10)
                #expect(first.sessions.map(\.key) + second.sessions.map(\.key) == expected.map(\.key))
                #expect(second.nextCursor == nil)
            }
            #expect(try store.latest().key == sessions[24].key)
        }
    }

    @Test func emptyAndInternalOnlyCapturesLeaveTheArchiveIntact() throws {
        try withStore { store in
            #expect(try store.page(before: nil).sessions.isEmpty)
            #expect(throws: LifTapError.self) { try store.latest() }
            let original = try session(0, tabs: [web])
            try store.save(original)
            #expect(throws: LifTapError.self) { try session(1, tabs: []) }
            #expect(throws: LifTapError.self) { try session(2, tabs: [browserPage]) }
            #expect(try store.latest().id == original.id)
        }
    }

    @Test func failedWriteLeavesEarlierSessionReadable() throws {
        try withStore { store in
            let original = try session(0, tabs: [web])
            try store.save(original)
            let next = try session(1, tabs: [web])
            let blockedPath = store.directory.appendingPathComponent(next.key)
            try FileManager.default.createDirectory(at: blockedPath, withIntermediateDirectories: false)
            #expect(throws: LifTapError.self) { try store.save(next) }
            #expect(try store.load(original.key).id == original.id)
        }
    }

    @Test func damagedLatestIsReportedAndOlderFilesCanStillBeRead() throws {
        try withStore { store in
            let earlier = try session(0, tabs: [web])
            let latest = try session(1, tabs: [web])
            try store.save(earlier)
            try store.save(latest)
            try Data("broken".utf8).write(to: store.directory.appendingPathComponent(latest.key))
            #expect(throws: LifTapError.self) { try store.latest() }
            let page = try store.page(before: nil)
            #expect(page.unreadableCount == 1)
            #expect(page.sessions.map(\.key) == [earlier.key])
        }
    }

    @Test func deletionUpdatesTheListAndLatestWithoutTouchingOtherSessions() throws {
        try withStore { store in
            let earlier = try session(0, tabs: [web])
            let latest = try session(1, tabs: [web])
            try store.save(earlier)
            try store.save(latest)

            try store.delete(latest.key)
            try store.delete(latest.key)
            #expect(try store.latest().id == earlier.id)
            #expect(try store.page(before: nil).sessions.map(\.key) == [earlier.key])
            #expect(throws: LifTapError.self) { try store.load(latest.key) }

            try store.delete(earlier.key)
            #expect(try store.page(before: nil).sessions.isEmpty)
            #expect(throws: LifTapError.self) { try store.latest() }
        }
    }

    @Test func renamePersistsWithoutChangingTheSessionKeyOrTabs() throws {
        try withStore { store in
            let original = try session(0, tabs: [web, web])
            try store.save(original)

            let renamed = try store.rename(original.key, to: "  새 이름  ")
            #expect(renamed.key == original.key)
            #expect(renamed.name == "새 이름")
            #expect(throws: LifTapError.self) { try store.rename(original.key, to: " \n ") }
            let saved = try store.latest()
            #expect(saved.id == original.id)
            #expect(saved.name == renamed.name)
            #expect(saved.tabs == original.tabs)
        }
    }

    @Test func firefoxRestoresSingleTabsAndGroupedSessionsWithDifferentArguments() {
        let addresses = [web.url, "https://example.test/other"]
        #expect(BrowserAutomation.firefoxArguments([addresses[0]], single: true) == ["--new-tab", addresses[0]])
        #expect(BrowserAutomation.firefoxArguments([addresses[0]], single: false) == ["--new-window", addresses[0]])
        #expect(BrowserAutomation.firefoxArguments(addresses, single: false) == addresses)
    }

    @Test func transferRequiresAWebSchemeAndHost() {
        let supported = ["https://example.test", "HTTP://localhost:8000/a"]
        let unsupported = ["chrome://settings/", "about:blank", "safari-extension://id/path",
                           "file:///tmp/report.pdf", "javascript:alert(1)", "https:///missing", ""]
        #expect(supported.allSatisfy { BrowserTab(title: "", url: $0).isTransferable })
        #expect(unsupported.allSatisfy { !BrowserTab(title: "", url: $0).isTransferable })
    }

    private func session(_ offset: Int, tabs: [BrowserTab]) throws -> TabSession {
        try TabSession(browser: .chrome,
                       createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(offset)), tabs: tabs)
    }

    private func withStore(_ body: (SessionStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(SessionStore(directory: directory))
    }
}
