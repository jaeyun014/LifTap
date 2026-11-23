import AppKit

@MainActor
final class SessionPanel: NSPanel, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onRestore: ((String, Browser) -> Void)?
    var onClose: (() -> Void)?

    private let store: SessionStore
    private let browsers: [Browser]
    private let table = SessionTable()
    private let preview = NSTextView()
    private let previewScroll = NSScrollView()
    private let target = NSPopUpButton()
    private let openButton = NSButton(title: "새 창에 열기", target: nil, action: nil)
    private let previewButton = NSButton(title: "탭 미리보기", target: nil, action: nil)
    private let latestButton = NSButton(title: "최신으로", target: nil, action: nil)
    private let olderButton = NSButton(title: "이전 세션", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let emptyState = NSTextField(labelWithString: "세션을 불러오는 중…")
    private var sessions: [SessionSummary] = []
    private var cursor: String?
    private var nextCursor: String?
    private var isLoading = false
    private var reloadPending = false
    private var isBusy = false
    private var previewTask: Task<Void, Never>?

    init(store: SessionStore, defaultBrowser: Browser?) {
        self.store = store
        browsers = Browser.allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.rawValue) != nil
        }
        super.init(contentRect: NSRect(x: 0, y: 0, width: 568, height: 500),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        title = "LifTap 세션"
        delegate = self
        buildContent()
        prepareTarget(defaultBrowser)
        center()
        loadPage()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) {
        previewTask?.cancel()
        onClose?()
    }

    func prepareTarget(_ browser: Browser?) {
        target.selectItem(at: browser.flatMap { browsers.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        updateControls()
    }

    func show(chooseTarget: Bool) {
        makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if browsers.isEmpty {
            setStatus("사용할 수 있는 브라우저가 없어요. Chrome이나 Safari가 설치되어 있는지 확인해 주세요.",
                      isError: true)
        } else if chooseTarget {
            setStatus("대상 브라우저를 선택해 주세요.")
        }
        makeFirstResponder(chooseTarget && !browsers.isEmpty ? target : table)
    }

    func reload() {
        cursor = nil
        if isLoading {
            reloadPending = true
        } else {
            loadPage()
        }
    }

    func setBusy(_ value: Bool) {
        isBusy = value
        updateControls()
    }

    func setStatus(_ text: String, isError: Bool = false) {
        status.stringValue = text
        status.textColor = isError ? .systemRed : .secondaryLabelColor
        NSAccessibility.post(element: status, notification: .valueChanged)
    }

    private var selectedSession: SessionSummary? {
        let index = table.selectedRow
        return sessions.indices.contains(index) ? sessions[index] : nil
    }

    private func buildContent() {
        let content = NSView()
        contentView = content
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        content.addSubview(stack)

        let heading = NSTextField(labelWithString: "저장한 세션")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        latestButton.target = self
        latestButton.action = #selector(firstPage)
        olderButton.target = self
        olderButton.action = #selector(olderPage)
        stack.addArrangedSubview(row([heading, NSView(), latestButton, olderButton]))

        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        tableColumn.resizingMask = [.autoresizingMask]
        table.addTableColumn(tableColumn)
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .inset
        table.rowHeight = 44
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("저장한 세션")
        table.target = self
        table.doubleAction = #selector(doubleClickSession)
        table.onOpen = { [weak self] in self?.openSelection() }
        table.onPreview = { [weak self] show in self?.showPreview(show) }
        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .bezelBorder
        tableScroll.documentView = table
        let tableContainer = NSView()
        tableContainer.addSubview(tableScroll)
        tableContainer.addSubview(emptyState)
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.textColor = .secondaryLabelColor
        stack.addArrangedSubview(tableContainer)

        previewButton.target = self
        previewButton.action = #selector(togglePreview)
        let hint = NSTextField(labelWithString: "↑↓ 선택 · → 미리보기 · ↩ 열기 · Esc 닫기")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(row([previewButton, NSView(), hint]))

        preview.isEditable = false
        preview.isSelectable = true
        preview.isRichText = false
        preview.font = .systemFont(ofSize: 12)
        preview.textContainerInset = NSSize(width: 9, height: 8)
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        preview.setAccessibilityLabel("저장된 탭 제목과 주소")
        previewScroll.documentView = preview
        previewScroll.borderType = .bezelBorder
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        stack.addArrangedSubview(previewScroll)
        previewScroll.isHidden = true

        let label = NSTextField(labelWithString: "대상 브라우저")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        target.addItem(withTitle: "브라우저 선택")
        target.addItems(withTitles: browsers.map(\.name))
        target.setAccessibilityLabel("대상 브라우저")
        target.target = self
        target.action = #selector(changeTarget)
        openButton.target = self
        openButton.action = #selector(openSelection)
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        stack.addArrangedSubview(row([label, target, NSView(), openButton]))
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(status)

        let previewHeight = previewScroll.heightAnchor.constraint(equalToConstant: 126)
        previewHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 15),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            tableScroll.topAnchor.constraint(equalTo: tableContainer.topAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor),
            tableContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            emptyState.centerXAnchor.constraint(equalTo: tableContainer.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: tableContainer.centerYAnchor),
            previewHeight,
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 16)
        ])
        initialFirstResponder = table
        table.nextKeyView = previewButton
        previewButton.nextKeyView = preview
        preview.nextKeyView = target
        target.nextKeyView = openButton
        openButton.nextKeyView = latestButton
        latestButton.nextKeyView = olderButton
        olderButton.nextKeyView = table
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func loadPage() {
        guard !isLoading else { return }
        isLoading = true
        updateControls()
        let store = store
        let requestedCursor = cursor
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try store.page(before: requestedCursor) }
            }.value
            guard let self else { return }
            self.isLoading = false
            if self.reloadPending {
                self.reloadPending = false
                self.loadPage()
                return
            }
            switch result {
            case let .success(page):
                self.showPreview(false)
                self.sessions = page.sessions
                self.nextCursor = page.nextCursor
                self.table.reloadData()
                if !page.sessions.isEmpty {
                    self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self.table.scrollRowToVisible(0)
                }
                self.emptyState.isHidden = !page.sessions.isEmpty
                self.emptyState.stringValue = page.unreadableCount > 0
                    ? "이 페이지에는 읽을 수 있는 세션이 없어요."
                    : "저장된 세션이 없어요. 브라우저에서 ‘현재 창 담기’를 실행해 보세요."
                if page.unreadableCount > 0 {
                    self.setStatus("\(page.unreadableCount)개 세션 파일을 읽을 수 없어요.", isError: true)
                }
            case let .failure(error):
                self.cursor = nil
                self.nextCursor = nil
                self.showPreview(false)
                self.sessions = []
                self.table.reloadData()
                self.emptyState.isHidden = false
                self.emptyState.stringValue = "세션 목록을 읽을 수 없어요."
                self.setStatus(error.localizedDescription, isError: true)
            }
            self.updateControls()
        }
    }

    @objc private func firstPage() {
        cursor = nil
        loadPage()
    }

    @objc private func olderPage() {
        guard let nextCursor else { return }
        cursor = nextCursor
        loadPage()
    }

    private func updateControls() {
        latestButton.isEnabled = !isLoading && cursor != nil
        olderButton.isEnabled = !isLoading && nextCursor != nil
        previewButton.isEnabled = !isLoading && selectedSession != nil
        openButton.isEnabled = !isBusy && !isLoading && selectedSession != nil && target.indexOfSelectedItem > 0
    }

    @objc private func changeTarget() {
        if target.indexOfSelectedItem > 0 {
            if !isBusy { setStatus("") }
            makeFirstResponder(table)
        }
        updateControls()
    }

    @objc private func openSelection() {
        guard !isBusy, !isLoading, let session = selectedSession else { return }
        let index = target.indexOfSelectedItem - 1
        guard browsers.indices.contains(index) else {
            if !browsers.isEmpty {
                setStatus("대상 브라우저를 선택해 주세요.")
                makeFirstResponder(target)
            }
            return
        }
        onRestore?(session.key, browsers[index])
    }

    @objc private func doubleClickSession() {
        guard table.clickedRow >= 0 else { return }
        openSelection()
    }

    @objc private func togglePreview() {
        showPreview(previewScroll.isHidden)
    }

    private func showPreview(_ show: Bool) {
        if show && !previewScroll.isHidden { return }
        previewTask?.cancel()
        previewTask = nil
        previewScroll.isHidden = true
        preview.string = ""
        previewButton.title = "탭 미리보기"
        guard show, !isLoading, let key = selectedSession?.key else { return }

        preview.string = "탭을 불러오는 중…"
        previewScroll.isHidden = false
        previewButton.title = "미리보기 닫기"
        let store = store
        previewTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try store.load(key).tabs.reduce(into: "") { text, tab in
                        let title = tab.title.isEmpty ? "제목 없음" : tab.title
                        if !text.isEmpty { text += "\n\n" }
                        text += title + "\n" + tab.url
                    }
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            switch result {
            case let .success(text): self.preview.string = text
            case let .failure(error): self.preview.string = error.localizedDescription
            }
            self.preview.scrollToBeginningOfDocument(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sessions.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showPreview(false)
        updateControls()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SessionCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SessionCell ?? SessionCell()
        cell.identifier = identifier
        cell.show(sessions[row])
        return cell
    }
}

private final class SessionTable: NSTableView {
    var onOpen: (() -> Void)?
    var onPreview: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onOpen?() // Return or keypad Enter
        case 124: onPreview?(true) // Right
        case 123: onPreview?(false) // Left
        default: super.keyDown(with: event)
        }
    }
}

private final class SessionCell: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let metadata = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        metadata.font = .systemFont(ofSize: 11)
        metadata.textColor = .secondaryLabelColor
        for label in [name, metadata] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }
        textField = name
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            name.bottomAnchor.constraint(equalTo: centerYAnchor),
            metadata.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            metadata.topAnchor.constraint(equalTo: centerYAnchor, constant: 2)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            metadata.textColor = backgroundStyle == .emphasized
                ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }

    func show(_ session: SessionSummary) {
        name.stringValue = session.name
        metadata.stringValue = "\(session.tabCount)개 탭 · \(session.sourceBrowser.name) · "
            + session.createdAt.formatted(date: .abbreviated, time: .shortened)
        setAccessibilityLabel(name.stringValue + ", " + metadata.stringValue)
    }
}
