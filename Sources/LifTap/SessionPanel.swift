import AppKit
import UniformTypeIdentifiers

@MainActor
final class SessionPanel: NSPanel, NSWindowDelegate, NSOpenSavePanelDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onRestore: ((String, BrowserDestination) -> Void)?
    var onClose: (() -> Void)?

    private let store: SessionStore
    private var browsers: [BrowserDestination]
    private var selectedBrowser: BrowserDestination?
    private let table = SessionTable()
    private let preview = NSTextView()
    private let previewScroll = NSScrollView()
    private let target = NSPopUpButton()
    private let openButton = NSButton(title: "새 창에 열기", target: nil, action: nil)
    private let previewButton = NSButton(title: "탭 미리보기", target: nil, action: nil)
    private let deleteButton = NSButton(title: "세션 삭제…", target: nil, action: nil)
    private let latestButton = NSButton(title: "최신으로", target: nil, action: nil)
    private let olderButton = NSButton(title: "이전 세션", target: nil, action: nil)
    private let groupedButton = NSButton(title: "저장한 세션", target: nil, action: nil)
    private let singleButton = NSButton(title: "단일 세션", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let emptyState = NSTextField(labelWithString: "세션을 불러오는 중…")
    private var sessions: [SessionSummary] = []
    private var section: SessionSection = .grouped
    private var selectLatestSection = false
    private var cursor: String?
    private var nextCursor: String?
    private var isLoading = false
    private var reloadPending = false
    private var isBusy = false
    private var isDeleting = false
    private var nameEdit: (session: SessionSummary, field: NSTextField)?
    private var isSavingName = false
    private var previewTask: Task<Void, Never>?

    init(store: SessionStore, defaultBrowser: Browser?, chooseLatest: Bool = false) {
        self.store = store
        selectLatestSection = chooseLatest
        browsers = BrowserDestination.installed()
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
        selectedBrowser = browser.flatMap { browser in browsers.first { $0.browser == browser } }
        selectCurrentTarget()
        updateControls()
    }

    func show(chooseTarget: Bool) {
        makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if chooseTarget {
            setStatus("대상 브라우저를 선택해 주세요.")
        }
        makeFirstResponder(chooseTarget ? target : table)
    }

    func reload(selectingLatest: Bool = false) {
        if selectingLatest { selectLatestSection = true }
        cursor = nil
        if isLoading || nameEdit != nil || isSavingName {
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

        for button in [groupedButton, singleButton] {
            button.isBordered = false
            button.setButtonType(.onOff)
            button.target = self
            button.action = #selector(changeSection(_:))
        }
        let divider = NSTextField(labelWithString: "/")
        divider.font = .systemFont(ofSize: 23, weight: .light)
        divider.textColor = .secondaryLabelColor
        divider.setAccessibilityElement(false)
        latestButton.target = self
        latestButton.action = #selector(firstPage)
        olderButton.target = self
        olderButton.action = #selector(olderPage)
        stack.addArrangedSubview(row([groupedButton, divider, singleButton, NSView(), latestButton, olderButton]))

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
        table.onDelete = { [weak self] in self?.confirmDeletion() }
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
        deleteButton.target = self
        deleteButton.action = #selector(confirmDeletion)
        let hint = NSTextField(labelWithString: "↑↓ 선택 · → 미리보기 · ⌫ 삭제 · ↩ 열기 · Esc 닫기")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(row([previewButton, deleteButton, NSView(), hint]))

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
        rebuildTargets()
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
        previewButton.nextKeyView = deleteButton
        deleteButton.nextKeyView = preview
        preview.nextKeyView = target
        target.nextKeyView = openButton
        openButton.nextKeyView = groupedButton
        groupedButton.nextKeyView = singleButton
        singleButton.nextKeyView = latestButton
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
        let requestedSection = section
        let chooseLatest = selectLatestSection
        selectLatestSection = false
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let resolvedSection: SessionSection
                    if chooseLatest, let latest = try? store.latest() {
                        resolvedSection = SessionSection(tabCount: latest.tabs.count)
                    } else {
                        resolvedSection = requestedSection
                    }
                    return (resolvedSection, try store.page(before: requestedCursor, section: resolvedSection))
                }
            }.value
            guard let self else { return }
            self.isLoading = false
            if self.reloadPending {
                self.reloadPending = false
                self.loadPage()
                return
            }
            switch result {
            case let .success((resolvedSection, page)):
                self.section = resolvedSection
                if requestedCursor != nil, page.sessions.isEmpty,
                   page.nextCursor == nil, page.unreadableCount == 0 {
                    self.firstPage()
                    return
                }
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
                    : self.section == .single
                        ? "단일 세션이 없어요. 브라우저에서 ⌥C로 현재 탭을 담아 보세요."
                        : "저장된 탭 묶음이 없어요. 여러 탭이 열린 창에서 ⌃⌥C로 담아 보세요."
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

    @objc private func changeSection(_ sender: NSButton) {
        let next: SessionSection = sender === singleButton ? .single : .grouped
        guard section != next else {
            updateControls()
            return
        }
        section = next
        showPreview(false)
        sessions.removeAll()
        nextCursor = nil
        table.reloadData()
        emptyState.stringValue = "세션을 불러오는 중…"
        emptyState.isHidden = false
        setStatus("")
        reload()
        makeFirstResponder(table)
    }

    @objc private func olderPage() {
        guard let nextCursor else { return }
        cursor = nextCursor
        loadPage()
    }

    private func updateControls() {
        let canBrowse = !isLoading && !isDeleting && nameEdit == nil && !isSavingName
        for (button, selected) in [(groupedButton, section == .grouped), (singleButton, section == .single)] {
            button.state = selected ? .on : .off
            button.isEnabled = canBrowse
            button.font = .systemFont(ofSize: selected ? 20 : 15, weight: selected ? .semibold : .regular)
            button.contentTintColor = selected ? .labelColor : .secondaryLabelColor
        }
        table.setAccessibilityLabel(section == .single ? singleButton.title : groupedButton.title)
        latestButton.isEnabled = canBrowse && cursor != nil
        olderButton.isEnabled = canBrowse && nextCursor != nil
        previewButton.isEnabled = canBrowse && selectedSession != nil
        deleteButton.isEnabled = canBrowse && !isBusy && selectedSession != nil
        openButton.isEnabled = deleteButton.isEnabled && selectedBrowser != nil
    }

    @objc private func confirmDeletion() {
        guard deleteButton.isEnabled, attachedSheet == nil, let session = selectedSession else { return }
        let alert = NSAlert()
        alert.messageText = "‘\(session.name)’ 세션을 삭제할까요?"
        alert.informativeText = "저장된 세션이 삭제됩니다. 현재 브라우저에 열린 탭은 그대로 유지됩니다."
        let confirm = alert.addButton(withTitle: "삭제")
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: self) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.deleteSession(session.key)
        }
        // AppKit clears the default shortcut for a destructive button when presenting the sheet.
        confirm.keyEquivalent = "\r"
    }

    private func deleteSession(_ key: String) {
        isDeleting = true
        updateControls()
        let store = store
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try store.delete(key) }
            }.value
            guard let self else { return }
            self.isDeleting = false
            switch result {
            case .success:
                self.setStatus("세션을 삭제했어요.")
                if self.isLoading {
                    self.reloadPending = true
                } else {
                    self.loadPage()
                }
            case let .failure(error):
                self.setStatus(error.localizedDescription, isError: true)
                self.updateControls()
            }
        }
    }

    private func rebuildTargets() {
        target.removeAllItems()
        target.addItem(withTitle: "브라우저 선택")
        for (index, browser) in browsers.enumerated() {
            let item = NSMenuItem(title: browser.name, action: nil, keyEquivalent: "")
            item.tag = index + 1
            let icon = NSWorkspace.shared.icon(forFile: browser.url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            target.menu?.addItem(item)
        }
        target.menu?.addItem(.separator())
        let other = NSMenuItem(title: "다른 브라우저 선택…", action: nil, keyEquivalent: "")
        other.tag = -1
        target.menu?.addItem(other)
        selectCurrentTarget()
    }

    private func selectCurrentTarget() {
        let index = selectedBrowser.flatMap { selected in browsers.firstIndex { $0.url == selected.url } }
        target.selectItem(withTag: index.map { $0 + 1 } ?? 0)
    }

    @objc private func changeTarget() {
        let tag = target.selectedTag()
        if tag == -1 {
            selectCurrentTarget()
            chooseOtherBrowser()
        } else {
            selectedBrowser = tag > 0 && browsers.indices.contains(tag - 1) ? browsers[tag - 1] : nil
            updateTargetStatus()
        }
    }

    private func chooseOtherBrowser() {
        guard attachedSheet == nil else { return }
        let picker = NSOpenPanel()
        picker.delegate = self
        picker.allowedContentTypes = [.application]
        picker.treatsFilePackagesAsDirectories = false
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        picker.message = "세션을 새 창으로 열 수 있는 브라우저를 선택해 주세요."
        picker.prompt = "선택"
        picker.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let self, let url = picker.url else { return }
            guard let browser = BrowserDestination(url: url) else {
                self.setStatus("새 창으로 열 수 있는 브라우저를 선택해 주세요.", isError: true)
                return
            }
            if !self.browsers.contains(where: { $0.url == url }) { self.browsers.append(browser) }
            self.selectedBrowser = browser
            self.rebuildTargets()
            self.updateTargetStatus()
        }
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if url.pathExtension.lowercased() == "app" {
            return BrowserDestination(url: url) != nil
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage == false
    }

    private func updateTargetStatus() {
        if !isBusy { setStatus("") }
        if selectedBrowser != nil { makeFirstResponder(table) }
        updateControls()
    }

    @objc private func openSelection() {
        guard !isBusy, !isLoading, !isDeleting, nameEdit == nil, !isSavingName,
              let session = selectedSession else { return }
        guard let selectedBrowser else {
            setStatus("대상 브라우저를 선택해 주세요.")
            makeFirstResponder(target)
            return
        }
        onRestore?(session.key, selectedBrowser)
    }

    @objc private func doubleClickSession() {
        let row = table.clickedRow
        guard sessions.indices.contains(row),
              let field = (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionCell)?.textField else { return }
        if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp,
           !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
            openSelection()
            return
        }
        beginNameEdit(for: sessions[row], field: field)
    }

    private func beginNameEdit(for session: SessionSummary, field: NSTextField) {
        guard deleteButton.isEnabled else { return }
        nameEdit = (session, field)
        field.delegate = self
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .textColor
        updateControls()
        field.selectText(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard nameEdit?.field === control else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            finishNameEdit(proposedName: nil)
        case #selector(NSResponder.insertNewline(_:)):
            finishNameEdit(proposedName: textView.string)
        default:
            return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let edit = nameEdit, notification.object as? NSTextField === edit.field else { return }
        finishNameEdit(proposedName: edit.field.stringValue)
    }

    private func finishNameEdit(proposedName: String?) {
        guard let edit = nameEdit else { return }
        nameEdit = nil
        edit.field.delegate = nil
        if firstResponder === edit.field.currentEditor() { makeFirstResponder(table) }
        edit.field.isEditable = false
        edit.field.isSelectable = false
        edit.field.drawsBackground = false
        edit.field.textColor = .labelColor
        edit.field.stringValue = edit.session.name
        guard let proposedName, proposedName != edit.session.name else {
            finishSavingName()
            return
        }
        isSavingName = true
        updateControls()
        let store = store
        let key = edit.session.key
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try store.rename(key, to: proposedName) }
            }.value
            guard let self else { return }
            switch result {
            case let .success(summary):
                if let row = self.sessions.firstIndex(where: { $0.key == key }) {
                    self.sessions[row] = summary
                    (self.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionCell)?.show(summary)
                }
                self.setStatus("세션 이름을 저장했어요.")
            case let .failure(error):
                self.setStatus(error.localizedDescription, isError: true)
            }
            self.finishSavingName()
        }
    }

    private func finishSavingName() {
        isSavingName = false
        if reloadPending {
            reloadPending = false
            loadPage()
        } else {
            updateControls()
        }
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
    var onDelete: (() -> Void)?
    var onPreview: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onOpen?() // Return or keypad Enter
        case 51 where event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty:
            if !event.isARepeat { onDelete?() } // Backspace (Delete on Mac keyboards)
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
