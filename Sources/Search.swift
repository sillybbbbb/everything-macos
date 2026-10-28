import Cocoa
import Quartz
import Darwin
import Carbon

struct SearchEntry {
    let path: String
    let name: String
    let lowerName: String
    let parent: String
    let source: String
    let kind: SearchFileKind
    let modified: Double?
    let size: Double?
    init(path: String, metadata: [String: Any], source: String) {
        self.path = path
        name = (path as NSString).lastPathComponent
        lowerName = name.lowercased()
        parent = (path as NSString).deletingLastPathComponent
        self.source = source
        kind = SearchFileKind.classify(name: name, isDirectory: metadata["directory"] as? Bool == true)
        modified = (metadata["modified"] as? NSNumber)?.doubleValue
        size = (metadata["size"] as? NSNumber)?.doubleValue
    }
}

enum SearchFileKind: String, CaseIterable {
    case all, folder, word, spreadsheet, presentation, pdf, image, text, archive, audio, video, other
    var title: String {
        switch self {
        case .all: return "全部类型"
        case .folder: return "文件夹"
        case .word: return "Word / WPS 文字"
        case .spreadsheet: return "Excel / WPS 表格"
        case .presentation: return "PPT / WPS 演示"
        case .pdf: return "PDF"
        case .image: return "图片"
        case .text: return "文本"
        case .archive: return "压缩包"
        case .audio: return "音频"
        case .video: return "视频"
        case .other: return "其他文件"
        }
    }
    private static let extensions: [String: SearchFileKind] = {
        let groups: [(SearchFileKind, [String])] = [
            (.word, ["doc", "docx", "docm", "dot", "dotx", "dotm", "wps", "wpt", "rtf", "odt"]),
            (.spreadsheet, ["xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx", "xltm", "et", "ett", "csv", "ods"]),
            (.presentation, ["ppt", "pptx", "pptm", "pps", "ppsx", "ppsm", "pot", "potx", "potm", "dps", "dpt", "odp", "key"]),
            (.pdf, ["pdf"]),
            (.image, ["jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "heif", "webp", "svg", "ico", "icns", "avif", "raw", "dng", "psd"]),
            (.text, ["txt", "md", "markdown", "log", "json", "xml", "yaml", "yml", "toml", "ini", "conf", "html", "htm", "srt"]),
            (.archive, ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst"]),
            (.audio, ["mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "ogg", "opus", "wma"]),
            (.video, ["mp4", "mov", "m4v", "mkv", "avi", "wmv", "webm", "flv", "mpeg", "mpg", "ts"])
        ]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { kind, suffixes in suffixes.map { ($0, kind) } })
    }()
    static func classify(name: String, isDirectory: Bool) -> SearchFileKind {
        if isDirectory { return .folder }
        return extensions[(name as NSString).pathExtension.lowercased()] ?? .other
    }
}

struct SearchCriteria {
    let terms: [String]
    let scope: String
    let kind: SearchFileKind
    func includes(_ entry: SearchEntry) -> Bool {
        (scope.isEmpty || scope == entry.source) && (kind == .all || kind == entry.kind) && terms.allSatisfy { entry.lowerName.contains($0) }
    }
}

final class SearchCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
enum SearchAborted: Error { case cancelled }

enum ResultOrdering {
    static let titles = ["source": "来源", "name": "名称", "modified": "修改日期", "size": "文件大小", "path": "所在路径"]
    static func precedes(_ a: SearchEntry, _ b: SearchEntry, key: String, ascending: Bool) -> Bool {
        var order: ComparisonResult = .orderedSame
        if key == "modified" || key == "size" {
            let left = key == "size" ? a.size : a.modified
            let right = key == "size" ? b.size : b.modified
            if left == nil && right != nil { return false }
            if left != nil && right == nil { return true }
            if let left = left, let right = right {
                order = left < right ? .orderedAscending : (left > right ? .orderedDescending : .orderedSame)
            }
        } else {
            let left = key == "source" ? a.source : (key == "path" ? a.parent : a.name)
            let right = key == "source" ? b.source : (key == "path" ? b.parent : b.name)
            order = left.compare(right, options: [.numeric, .caseInsensitive, .widthInsensitive])
        }
        if order == .orderedSame { return a.path < b.path }
        return ascending ? order == .orderedAscending : order == .orderedDescending
    }
}

final class GlobalShortcut {
    var action: (() -> Void)?
    var keyCode: UInt32 = 49
    var modifiers: UInt32 = UInt32(controlKey | optionKey)
    var keyName = "空格"
    var active: EventHotKeyRef?
    var handler: EventHandlerRef?
    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "shortcutCode") != nil {
            keyCode = UInt32(defaults.integer(forKey: "shortcutCode"))
            modifiers = UInt32(defaults.integer(forKey: "shortcutModifiers"))
            keyName = defaults.string(forKey: "shortcutName") ?? "空格"
        }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context -> OSStatus in
            guard let context = context else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            shortcut.action?()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    var label: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + keyName
    }
    func pause() {
        if let active = active { UnregisterEventHotKey(active) }
        active = nil
    }
    @discardableResult func resume() -> OSStatus { register(keyCode, modifiers, keyName, save: false) }
    @discardableResult func register(_ code: UInt32, _ flags: UInt32, _ name: String, save: Bool = true) -> OSStatus {
        if active != nil && code == keyCode && flags == modifiers { return noErr }
        var newKey: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x45565259, id: 1)
        let result = RegisterEventHotKey(code, flags, identifier, GetApplicationEventTarget(), 0, &newKey)
        guard result == noErr else { return result }
        pause()
        active = newKey
        keyCode = code; modifiers = flags; keyName = name
        if save {
            let defaults = UserDefaults.standard
            defaults.set(Int(code), forKey: "shortcutCode")
            defaults.set(Int(flags), forKey: "shortcutModifiers")
            defaults.set(name, forKey: "shortcutName")
        }
        return noErr
    }
    deinit { pause(); if let handler = handler { RemoveEventHandler(handler) } }
}

final class SettingsRows: NSStackView { override var isFlipped: Bool { true } }

final class AppSettings: NSObject, NSWindowDelegate {
    let shortcut: GlobalShortcut
    let window: NSWindow
    let record = NSButton()
    let message = NSTextField(wrappingLabelWithString: "点击下方按钮，然后按下想使用的组合键。")
    var monitor: Any?
    var dataURL: URL!
    var saveOptions: ((Set<String>, Bool, Bool, Int, Int) -> String?)?
    let daily = NSButton(checkboxWithTitle: "每天自动刷新", target: nil, action: nil)
    let login = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    let hour = NSTextField()
    let minute = NSTextField()
    let shareRows = SettingsRows()
    var shareButtons = [NSButton]()
    var startingDisabled = Set<String>()
    var changed: (() -> Void)?
    init(shortcut: GlobalShortcut) {
        self.shortcut = shortcut
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 690), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "everything · 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let title = NSTextField(labelWithString: "全局唤出快捷键")
        title.font = .boldSystemFont(ofSize: 20)
        let help = NSTextField(wrappingLabelWithString: "在其他应用中也能打开搜索。请包含 Control、Option 或 Command；录入时按 Esc 取消。")
        help.textColor = .secondaryLabelColor
        record.title = shortcut.label
        record.bezelStyle = .rounded
        record.font = .systemFont(ofSize: 19, weight: .medium)
        record.target = self; record.action = #selector(startRecording)
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetShortcut))
        message.font = .systemFont(ofSize: 12)
        let view = window.contentView!
        for control in [title, help, record, reset, message] { control.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(control) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), title.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            help.leadingAnchor.constraint(equalTo: title.leadingAnchor), help.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), help.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            record.leadingAnchor.constraint(equalTo: title.leadingAnchor), record.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 18), record.widthAnchor.constraint(equalToConstant: 285), record.heightAnchor.constraint(equalToConstant: 42),
            reset.leadingAnchor.constraint(equalTo: record.trailingAnchor, constant: 16), reset.centerYAnchor.constraint(equalTo: record.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: title.leadingAnchor), message.trailingAnchor.constraint(equalTo: help.trailingAnchor), message.topAnchor.constraint(equalTo: record.bottomAnchor, constant: 15)
        ])
        let autoLabel = NSTextField(labelWithString: "自动刷新与启动")
        autoLabel.font = .boldSystemFont(ofSize: 16)
        let colon = NSTextField(labelWithString: ":")
        let shareLabel = NSTextField(labelWithString: "参与搜索的共享盘")
        shareLabel.font = .boldSystemFont(ofSize: 16)
        let shareHelp = NSTextField(wrappingLabelWithString: "按实际盘名勾选。个人文件夹始终参与搜索；新连接的共享盘默认启用。")
        shareHelp.textColor = .secondaryLabelColor
        let shareScroll = NSScrollView()
        shareScroll.hasVerticalScroller = true; shareScroll.borderType = .bezelBorder
        shareRows.orientation = .vertical; shareRows.alignment = .leading; shareRows.spacing = 10
        shareScroll.documentView = shareRows
        shareRows.translatesAutoresizingMaskIntoConstraints = false
        let reload = NSButton(title: "重新检测共享盘", target: self, action: #selector(reloadShares))
        let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
        for item in [autoLabel, daily, hour, colon, minute, login, shareLabel, shareHelp, shareScroll, reload, save] {
            item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            autoLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 250), autoLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            daily.topAnchor.constraint(equalTo: autoLabel.bottomAnchor, constant: 14), daily.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hour.leadingAnchor.constraint(equalTo: daily.trailingAnchor, constant: 16), hour.centerYAnchor.constraint(equalTo: daily.centerYAnchor), hour.widthAnchor.constraint(equalToConstant: 40),
            colon.leadingAnchor.constraint(equalTo: hour.trailingAnchor, constant: 5), colon.centerYAnchor.constraint(equalTo: daily.centerYAnchor),
            minute.leadingAnchor.constraint(equalTo: colon.trailingAnchor, constant: 5), minute.centerYAnchor.constraint(equalTo: daily.centerYAnchor), minute.widthAnchor.constraint(equalToConstant: 40),
            login.topAnchor.constraint(equalTo: daily.bottomAnchor, constant: 12), login.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            shareLabel.topAnchor.constraint(equalTo: login.bottomAnchor, constant: 26), shareLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            shareHelp.topAnchor.constraint(equalTo: shareLabel.bottomAnchor, constant: 8), shareHelp.leadingAnchor.constraint(equalTo: title.leadingAnchor), shareHelp.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            shareScroll.topAnchor.constraint(equalTo: shareHelp.bottomAnchor, constant: 12), shareScroll.leadingAnchor.constraint(equalTo: title.leadingAnchor), shareScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), shareScroll.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -16),
            shareRows.leadingAnchor.constraint(equalTo: shareScroll.contentView.leadingAnchor, constant: 10), shareRows.topAnchor.constraint(equalTo: shareScroll.contentView.topAnchor, constant: 10), shareRows.widthAnchor.constraint(equalTo: shareScroll.widthAnchor, constant: -35),
            save.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), save.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            reload.leadingAnchor.constraint(equalTo: title.leadingAnchor), reload.centerYAnchor.constraint(equalTo: save.centerYAnchor)
        ])
        window.center()
    }
    @objc func reloadShares() {
        var disabled = startingDisabled
        for button in shareButtons { if let id = button.identifier?.rawValue { if button.state == .on { disabled.remove(id) } else { disabled.insert(id) } } }
        shareButtons.removeAll()
        for view in shareRows.arrangedSubviews { shareRows.removeArrangedSubview(view); view.removeFromSuperview() }
        let shares = SharedSources.known(in: dataURL)
        if shares.isEmpty { shareRows.addArrangedSubview(NSTextField(wrappingLabelWithString: "尚未发现共享盘，请先在 Finder 中连接，再点重新检测。")) }
        for share in shares {
            let row = NSButton(checkboxWithTitle: share.name + (share.connected ? "（已连接）" : "（未连接，保留索引）"), target: nil, action: nil)
            row.identifier = NSUserInterfaceItemIdentifier(share.id)
            row.toolTip = share.root
            row.state = disabled.contains(share.id) ? .off : .on
            shareRows.addArrangedSubview(row); shareButtons.append(row)
        }
    }
    @objc func saveSettings() {
        guard let h = Int(hour.stringValue), (0...23).contains(h), let m = Int(minute.stringValue), (0...59).contains(m) else {
            message.textColor = .systemRed; message.stringValue = "请输入有效时间：小时 0–23，分钟 0–59。"; return
        }
        var disabled = startingDisabled
        for button in shareButtons { if let id = button.identifier?.rawValue { if button.state == .on { disabled.remove(id) } else { disabled.insert(id) } } }
        if let error = saveOptions?(disabled, daily.state == .on, login.state == .on, h, m) {
            message.textColor = .systemRed; message.stringValue = error
        } else {
            startingDisabled = disabled; message.textColor = .secondaryLabelColor; message.stringValue = "已保存，搜索范围立即生效。快捷键修改后会自动保存。"
        }
    }
    func show() {
        let defaults = UserDefaults.standard
        daily.state = defaults.bool(forKey: "autoRefresh") ? .on : .off
        login.state = defaults.bool(forKey: "startAtLogin") ? .on : .off
        hour.stringValue = String(format: "%02d", defaults.integer(forKey: "refreshHour"))
        minute.stringValue = String(format: "%02d", defaults.integer(forKey: "refreshMinute"))
        startingDisabled = SharedSources.readDisabled(in: dataURL)
        shareButtons.removeAll(); reloadShares()
        record.title = shortcut.label
        if shortcut.active == nil { message.stringValue = "当前快捷键未能注册，请设置其他组合键。"; message.textColor = .systemRed }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func startRecording() {
        if monitor != nil { finish(); return }
        shortcut.pause()
        record.title = "请按组合键…"
        message.textColor = .secondaryLabelColor
        message.stringValue = "例如 Control＋Option＋空格；Esc 取消。"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window.isKeyWindow else { return event }
            if event.keyCode == 53 { self.finish(); return nil }
            let modifiers = event.modifierFlags
            guard !modifiers.intersection([.command, .control, .option]).isEmpty else {
                self.message.stringValue = "请至少搭配 Control、Option 或 Command。"; return nil
            }
            var flags: UInt32 = 0
            if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
            if modifiers.contains(.control) { flags |= UInt32(controlKey) }
            if modifiers.contains(.option) { flags |= UInt32(optionKey) }
            if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
            let special: [UInt16:String] = [49:"空格",36:"Return",48:"Tab",51:"Delete",123:"←",124:"→",125:"↓",126:"↑"]
            let name = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "按键 \(event.keyCode)"
            let status = self.shortcut.register(UInt32(event.keyCode), flags, name)
            if status == noErr {
                self.finish(restore: false)
                self.message.textColor = .secondaryLabelColor
                self.message.stringValue = "已保存：\(self.shortcut.label)，关闭此窗口后即可使用。"
                self.changed?()
            } else {
                self.finish()
                self.message.textColor = .systemRed
                self.message.stringValue = "该组合键被系统或其他应用占用，请选择其他组合键。"
            }
            return nil
        }
    }
    func finish(restore: Bool = true) {
        if let monitor = monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if restore { shortcut.resume() }
        record.title = shortcut.label
    }
    @objc func resetShortcut() {
        finish()
        let result = shortcut.register(49, UInt32(controlKey | optionKey), "空格")
        record.title = shortcut.label
        message.textColor = result == noErr ? .secondaryLabelColor : .systemRed
        message.stringValue = result == noErr ? "已恢复默认：Control＋Option＋空格。" : "默认组合键已被占用，请设置其他组合键。"
        changed?()
    }
    func windowWillClose(_ notification: Notification) { if monitor != nil { finish() } }
    func windowDidResignKey(_ notification: Notification) { if monitor != nil { finish() } }
}

final class SearchTable: NSTableView, NSMenuItemValidation {
    var previewAction: (() -> Void)?
    var copyAction: (() -> Void)?
    @objc func copy(_ sender: Any?) { copyAction?() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(copy(_:)) || !selectedRowIndexes.isEmpty
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        guard clickedRow >= 0 else { return nil }
        if !selectedRowIndexes.contains(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if !event.isARepeat { previewAction?() }
            return
        }
        super.keyDown(with: event)
    }
}

final class SearchWindow: NSWindow {
    weak var previewOwner: App?
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = previewOwner
        panel.delegate = previewOwner
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

final class App: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var window: NSWindow!
    let search = NSSearchField()
    let scopeControl = NSPopUpButton(frame: .zero, pullsDown: false)
    let kindControl = NSPopUpButton(frame: .zero, pullsDown: false)
    let table = SearchTable()
    var isDraggingResults = false
    var filterAfterDrag = false
    var previewURL: NSURL?
    let info = NSTextField(labelWithString: "正在载入本地索引…")
    let progress = NSTextField(labelWithString: "")
    var paths = [String]()
    var entries = [SearchEntry]()
    var activeSearch: SearchCancellation?
    var metadata = [String: [String: Any]]()
    var sourceByPath = [String: String]()
    let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
    var matches = [String]()
    var stamp = ""
    var loading = false
    var generation = 0
    var timer: Timer?
    var process: Process?
    var shortcut: GlobalShortcut?
    var shortcutSettings: AppSettings?
    var statusItem: NSStatusItem?
    var instanceLock: Int32 = -1
    var showObserver: NSObjectProtocol?
    let queue = DispatchQueue(label: "local.search", qos: .userInitiated)
    var base: URL { Bundle.main.bundleURL.deletingLastPathComponent() }
    var data: URL {
        #if TESTING_UI
        return URL(fileURLWithPath: ProcessInfo.processInfo.environment["EVERYTHING_TEST_DATA"]!)
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/EverythingMac")
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--refresh-only") {
            NSApp.setActivationPolicy(.prohibited)
            let p = Process()
            p.executableURL = Bundle.main.resourceURL!.appendingPathComponent("Indexer")
            p.terminationHandler = { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
            process = p
            do { try p.run() } catch { NSApp.terminate(nil) }
            return
        }
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        instanceLock = Darwin.open(data.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if instanceLock < 0 || flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {
            if !CommandLine.arguments.contains("--background-agent") {
                DistributedNotificationCenter.default().postNotificationName(Notification.Name("org.everythingmac.show"), object: nil, userInfo: nil, deliverImmediately: true)
            }
            NSApp.terminate(nil)
            return
        }
        showObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("org.everythingmac.show"), object: nil, queue: .main) { [weak self] _ in self?.showSearch() }
        if let url = Bundle.main.url(forResource: "EverythingIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "everything")
        appMenu.addItem(withTitle: "打开搜索", action: #selector(showSearch), keyEquivalent: "")
        let settingsItem = appMenu.addItem(withTitle: "设置…", action: #selector(showAppSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(withTitle: "隐藏everything", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出everything", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
        window = SearchWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        (window as? SearchWindow)?.previewOwner = self
        window.isReleasedWhenClosed = false
        window.title = "everything · 本地与共享盘"
        window.minSize = NSSize(width: 700, height: 420)
        let view = window.contentView!
        let title = NSTextField(labelWithString: "everything")
        title.font = .boldSystemFont(ofSize: 24)
        let help = NSTextField(wrappingLabelWithString: "仅匹配名称；空格预览，双击打开，⌘C 复制，也可直接拖出文件。支持多选。")
        help.textColor = .secondaryLabelColor
        search.placeholderString = "例如：工作 报告，或 计划 .docx"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        scopeControl.addItem(withTitle: "全部")
        scopeControl.target = self
        scopeControl.action = #selector(filtersChanged)
        scopeControl.setAccessibilityLabel("搜索范围")
        scopeControl.toolTip = "按位置筛选，可与关键词和文件类型组合使用"
        let kindLabel = NSTextField(labelWithString: "类型")
        kindLabel.textColor = .secondaryLabelColor
        kindControl.addItems(withTitles: SearchFileKind.allCases.map(\.title))
        kindControl.target = self
        kindControl.action = #selector(filtersChanged)
        kindControl.setAccessibilityLabel("文件类型")
        kindControl.toolTip = "按文件扩展名筛选；文件夹单独分类"
        let savedKind = SearchFileKind(rawValue: UserDefaults.standard.string(forKey: "searchFileKind") ?? "") ?? .all
        kindControl.selectItem(at: SearchFileKind.allCases.firstIndex(of: savedKind) ?? 0)
        let refresh = NSButton(title: "刷新索引", target: self, action: #selector(refreshIndex))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        for (id, label, width) in [("source", "来源", 80.0), ("name", "文件 / 文件夹名称", 300.0), ("modified", "修改日期", 150.0), ("size", "文件大小", 95.0), ("path", "所在路径", 470.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = label
            col.width = width
            col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id != "modified" && id != "size")
            table.addTableColumn(col)
        }
        table.delegate = self
        table.dataSource = self
        if let key = UserDefaults.standard.string(forKey: "sortColumn"), ["source", "name", "modified", "size", "path"].contains(key) {
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: UserDefaults.standard.bool(forKey: "sortAscending"))]
        }
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.rowHeight = 30
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.previewAction = { [weak self] in self?.togglePreview() }
        table.copyAction = { [weak self] in self?.copySelectedFiles() }
        let resultMenu = NSMenu()
        let copyItem = resultMenu.addItem(withTitle: "拷贝", action: #selector(SearchTable.copy(_:)), keyEquivalent: "")
        copyItem.target = table
        resultMenu.addItem(.separator())
        let revealItem = resultMenu.addItem(withTitle: "在 Finder 中定位", action: #selector(revealSelected), keyEquivalent: "")
        revealItem.target = self
        let pathItem = resultMenu.addItem(withTitle: "拷贝路径", action: #selector(copySelectedPath), keyEquivalent: "")
        pathItem.target = self
        table.menu = resultMenu
        scroll.documentView = table
        info.font = .systemFont(ofSize: 12)
        progress.font = .systemFont(ofSize: 12)
        progress.textColor = .secondaryLabelColor
        for item in [title, help, search, refresh, scopeControl, kindLabel, kindControl, scroll, info, progress] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), title.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            help.leadingAnchor.constraint(equalTo: title.leadingAnchor), help.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            help.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            search.leadingAnchor.constraint(equalTo: title.leadingAnchor), search.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 20), search.heightAnchor.constraint(equalToConstant: 32),
            refresh.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 12), refresh.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), refresh.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            scopeControl.leadingAnchor.constraint(equalTo: title.leadingAnchor), scopeControl.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12), scopeControl.heightAnchor.constraint(equalToConstant: 28),
            kindLabel.leadingAnchor.constraint(equalTo: scopeControl.trailingAnchor, constant: 20), kindLabel.centerYAnchor.constraint(equalTo: scopeControl.centerYAnchor),
            kindControl.leadingAnchor.constraint(equalTo: kindLabel.trailingAnchor, constant: 8), kindControl.centerYAnchor.constraint(equalTo: scopeControl.centerYAnchor), kindControl.widthAnchor.constraint(equalToConstant: 205), kindControl.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: scopeControl.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), scroll.bottomAnchor.constraint(equalTo: info.topAnchor, constant: -14),
            info.leadingAnchor.constraint(equalTo: title.leadingAnchor), info.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), info.bottomAnchor.constraint(equalTo: progress.topAnchor, constant: -8),
            progress.leadingAnchor.constraint(equalTo: title.leadingAnchor), progress.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), progress.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
        window.center()
        installBackgroundControls()
        if UserDefaults.standard.object(forKey: "scheduleInitialized") == nil {
            UserDefaults.standard.set(true, forKey: "autoRefresh")
            UserDefaults.standard.set(true, forKey: "startAtLogin")
            UserDefaults.standard.set(12, forKey: "refreshHour")
            UserDefaults.standard.set(30, forKey: "refreshMinute")
            UserDefaults.standard.set(true, forKey: "scheduleInitialized")
        }
        #if !TESTING_UI
        configureAgents()
        #endif
        if CommandLine.arguments.contains("--background-agent") {
            NSApp.setActivationPolicy(.accessory)
        } else { showSearch() }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        let index = data.appendingPathComponent("index.json")
        let modified = (try? index.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        #if !TESTING_UI
        if modified == nil || Date().timeIntervalSince(modified!) > 86400 { refreshIndex() }
        #endif
    }
    @discardableResult func configureAgents() -> Bool {
        let defaults = UserDefaults.standard
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return false }
        let definitions: [(String, Bool, [String: Any])] = [
            ("org.everythingmac.refresh", defaults.bool(forKey: "autoRefresh"), ["ProgramArguments": [Bundle.main.resourceURL!.appendingPathComponent("Indexer").path], "StartCalendarInterval": ["Hour": defaults.integer(forKey: "refreshHour"), "Minute": defaults.integer(forKey: "refreshMinute")]]),
            ("org.everythingmac.login", defaults.bool(forKey: "startAtLogin"), ["ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath, "--args", "--background-agent"], "RunAtLoad": true])
        ]
        var success = true
        func launchctl(_ arguments: [String]) -> Bool {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
        }
        for (label, enabled, definition) in definitions {
            let file = directory.appendingPathComponent(label + ".plist")
            var content = definition; content["Label"] = label
            guard let plist = try? PropertyListSerialization.data(fromPropertyList: content, format: .xml, options: 0) else { success = false; continue }
            let previous = try? Data(contentsOf: file)
            if enabled, let previous = previous,
               let prior = try? PropertyListSerialization.propertyList(from: previous, options: [], format: nil) as? NSDictionary,
               prior.isEqual(to: content), launchctl(["print", "gui/\(getuid())/\(label)"]) { continue }
            if previous != nil { _ = launchctl(["bootout", "gui/\(getuid())", file.path]); try? FileManager.default.removeItem(at: file) }
            if enabled {
                do {
                    try plist.write(to: file, options: .atomic)
                    if !launchctl(["bootstrap", "gui/\(getuid())", file.path]) { success = false; try? FileManager.default.removeItem(at: file) }
                } catch { success = false }
            }
        }
        return success
    }
    func installBackgroundControls() {
        let shortcut = GlobalShortcut()
        shortcut.action = { [weak self] in self?.showSearch() }
        self.shortcut = shortcut
        #if !TESTING_UI
        shortcut.resume()
        #endif
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "everything")?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedRed: 1.0, green: 0.52, blue: 0.08, alpha: 1)]))
        icon?.isTemplate = false
        statusItem?.button?.image = icon
        statusItem?.button?.toolTip = "everything · " + shortcut.label
        let menu = NSMenu()
        let show = NSMenuItem(title: "打开 everything", action: #selector(showSearch), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let settings = NSMenuItem(title: "设置…", action: #selector(showAppSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 everything", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statusItem?.menu = menu
    }
    @objc func showAppSettings() {
        guard let shortcut = shortcut else { return }
        if shortcutSettings == nil {
            shortcutSettings = AppSettings(shortcut: shortcut)
            shortcutSettings?.dataURL = data
            shortcutSettings?.saveOptions = { [weak self] disabled, daily, login, hour, minute in
                guard let self = self else { return "设置窗口已失效，请重新打开。" }
                let changed = SharedSources.readDisabled(in: self.data) != disabled
                do { try SharedSources.saveDisabled(disabled, in: self.data) } catch { return "共享盘选择保存失败：" + error.localizedDescription }
                let defaults = UserDefaults.standard
                defaults.set(daily, forKey: "autoRefresh"); defaults.set(login, forKey: "startAtLogin")
                defaults.set(hour, forKey: "refreshHour"); defaults.set(minute, forKey: "refreshMinute")
                self.lastKey = ""; self.poll()
                #if !TESTING_UI
                if !self.configureAgents() { return "设置已保存，但自动任务启用失败，请检查登录项权限。" }
                if changed { self.refreshIndex() }
                #endif
                return nil
            }
            shortcutSettings?.changed = { [weak self] in
                guard let self = self else { return }
                self.statusItem?.button?.toolTip = "everything · " + (self.shortcut?.label ?? "")
            }
        }
        shortcutSettings?.show()
    }
    @objc func showSearch() {
        guard window != nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSearch(); return true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard matches.indices.contains(row) else { return nil }
        return NSURL(fileURLWithPath: matches[row])
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        isDraggingResults = true
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingResults = false
        if filterAfterDrag {
            filterAfterDrag = false
            filter()
        }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = matches[row]
        let source = sourceByPath[p] ?? "本地"
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "source": value = source
        case "name": value = (p as NSString).lastPathComponent
        case "modified":
            if let timestamp = metadata[p]?["modified"] as? Double {
                value = dateFormat.string(from: Date(timeIntervalSince1970: timestamp))
            } else { value = "待刷新" }
        case "size":
            if metadata[p]?["directory"] as? Bool == true { value = "—" }
            else if let bytes = metadata[p]?["size"] as? NSNumber {
                value = ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
            } else { value = "待刷新" }
        default: value = (p as NSString).deletingLastPathComponent
        }
        let text = NSTextField(labelWithString: value)
        text.lineBreakMode = .byTruncatingMiddle
        text.toolTip = p
        return text
    }
    func controlTextDidChange(_ obj: Notification) { filter() }
    var selectedScope: String { scopeControl.indexOfSelectedItem <= 0 ? "" : (scopeControl.titleOfSelectedItem ?? "") }
    var selectedKind: SearchFileKind {
        let index = kindControl.indexOfSelectedItem
        return SearchFileKind.allCases.indices.contains(index) ? SearchFileKind.allCases[index] : .all
    }
    @objc func filtersChanged() {
        UserDefaults.standard.set(selectedScope, forKey: "searchScope")
        UserDefaults.standard.set(selectedKind.rawValue, forKey: "searchFileKind")
        filter()
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if let descriptor = tableView.sortDescriptors.first {
            UserDefaults.standard.set(descriptor.key, forKey: "sortColumn")
            UserDefaults.standard.set(descriptor.ascending, forKey: "sortAscending")
        }
        filter()
    }
    func selectedPreviewURL() -> NSURL? {
        let row = table.selectedRow
        return row >= 0 && row < matches.count ? NSURL(fileURLWithPath: matches[row]) : nil
    }
    func togglePreview() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            window.makeFirstResponder(table)
            return
        }
        guard let url = selectedPreviewURL() else { return }
        previewURL = url
        QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURL }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        previewURL = selectedPreviewURL()
        if previewURL == nil { panel.orderOut(nil) }
        else { panel.reloadData() }
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 49 || event.keyCode == 53 {
            panel.orderOut(nil)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(table)
            return true
        }
        if event.keyCode == 125 || event.keyCode == 126 {
            table.keyDown(with: event)
            return true
        }
        return false
    }
    func filter() {
        if isDraggingResults { filterAfterDrag = true; return }
        generation += 1
        let current = generation
        activeSearch?.cancel()
        let cancellation = SearchCancellation()
        activeSearch = cancellation
        let criteria = SearchCriteria(terms: search.stringValue.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init), scope: selectedScope, kind: selectedKind)
        let filterLabel = [criteria.scope.isEmpty ? nil : criteria.scope, criteria.kind == .all ? nil : criteria.kind.title].compactMap { $0 }.joined(separator: " / ")
        let snapshot = entries
        let sorting = table.sortDescriptors.first
        let sortKey = sorting?.key
        let ascending = sorting?.ascending ?? true
        let selected = Set(selectedPaths)
        let date = stamp
        let sortLabel = sortKey.map { (ResultOrdering.titles[$0] ?? $0) + (ascending ? " ↑" : " ↓") } ?? ""
        info.stringValue = sortLabel.isEmpty ? "正在搜索…" : "正在排序：" + sortLabel
        queue.async {
            guard !cancellation.isCancelled else { return }
            var found = [SearchEntry]()
            for (index, entry) in snapshot.enumerated() {
                if index % 512 == 0 && cancellation.isCancelled { return }
                if criteria.includes(entry) { found.append(entry) }
            }
            if let key = sortKey {
                var comparisons = 0
                do {
                    try found.sort {
                        comparisons += 1
                        if comparisons % 1024 == 0 && cancellation.isCancelled { throw SearchAborted.cancelled }
                        return ResultOrdering.precedes($0, $1, key: key, ascending: ascending)
                    }
                } catch { return }
            }
            guard !cancellation.isCancelled else { return }
            let results = found.prefix(500).map(\.path)
            let count = found.count
            DispatchQueue.main.async {
                guard current == self.generation else { return }
                if self.isDraggingResults { self.filterAfterDrag = true; return }
                self.matches = results
                self.table.reloadData()
                let selectedRows = IndexSet(results.indices.filter { selected.contains(results[$0]) })
                self.table.selectRowIndexes(selectedRows, byExtendingSelection: false)
                if !results.isEmpty { self.table.scrollRowToVisible(0) }
                self.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
                let labels = [filterLabel, sortLabel].filter { !$0.isEmpty }.joined(separator: " · ")
                self.info.stringValue = "匹配 \(count) 项\(count > 500 ? "（显示前 500 项）" : "")\(labels.isEmpty ? "" : " · " + labels) · 索引 \(snapshot.count) 项 · \(date)"
                self.info.toolTip = self.info.stringValue
            }
        }
    }
    func poll() {
        if let raw = try? Data(contentsOf: data.appendingPathComponent("status.json")), let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
            var message = obj["message"] as? String ?? ""
            if obj["state"] as? String == "running" {
                message += " 已收录 \(obj["count"] as? Int ?? 0) 项。"
                if Date().timeIntervalSince1970 - (obj["updated"] as? Double ?? 0) > 120 { message += " 暂无新进度，可能正在等待网络。" }
            }
            progress.stringValue = message
        }
        guard !loading else { return }
        let url = data.appendingPathComponent("index.json")
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let date = modified else { info.stringValue = "尚无索引，请点击刷新索引。共享盘需先连接。"; return }
        let key = String(date.timeIntervalSince1970)
        if lastKey == key { return }
        loading = true
        queue.async {
            var result: [String: Any]?
            if let raw = try? Data(contentsOf: url) { result = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] }
            let obj = result
            let allPaths = obj?["paths"] as? [String] ?? []
            let attributes = obj?["metadata"] as? [String: [String: Any]] ?? [:]
            let sources = obj?["sources"] as? [[String: Any]] ?? []
            var sourceMap = [String: String]()
            let disabled = SharedSources.readDisabled(in: self.data)
            var allowed = Set<String>()
            for source in sources where !disabled.contains(source["id"] as? String ?? "") {
                let name = source["name"] as? String ?? "本地"
                for path in source["paths"] as? [String] ?? [] { sourceMap[path] = name; allowed.insert(path) }
            }
            let list = allPaths.filter { allowed.contains($0) }
            let prepared = list.map { SearchEntry(path: $0, metadata: attributes[$0] ?? [:], source: sourceMap[$0] ?? "本地") }
            DispatchQueue.main.async {
                self.loading = false
                guard disabled == SharedSources.readDisabled(in: self.data) else { self.lastKey = ""; self.poll(); return }
                if let obj = obj {
                    self.paths = list
                    self.entries = prepared
                    self.metadata = attributes
                    self.sourceByPath = sourceMap
                    let selected = self.selectedScope.isEmpty ? (UserDefaults.standard.string(forKey: "searchScope") ?? "") : self.selectedScope
                    let names = Array(Set(sourceMap.values)).sorted()
                    self.scopeControl.removeAllItems()
                    self.scopeControl.addItems(withTitles: ["全部"] + names)
                    self.scopeControl.selectItem(withTitle: selected.isEmpty ? "全部" : selected)
                    if self.scopeControl.indexOfSelectedItem < 0 { self.scopeControl.selectItem(at: 0) }
                    self.stamp = obj["updated"] as? String ?? ""
                    self.lastKey = key
                    self.filter()
                }
            }
        }
    }
    var lastKey = ""
    @objc func refreshIndex() {
        if process?.isRunning == true { return }
        let p = Process()
        p.executableURL = Bundle.main.resourceURL!.appendingPathComponent("Indexer")
        do { try p.run(); process = p; progress.stringValue = "已请求刷新；若已有扫描正在进行，将继续使用该扫描。" }
        catch { progress.stringValue = "无法启动刷新：\(error.localizedDescription)" }
    }
    @objc func openSelected() { accessSelected(reveal: false) }
    @objc func revealSelected() {
        let selected = selectedPaths
        if selected.count > 1 {
            NSWorkspace.shared.activateFileViewerSelecting(selected.map { URL(fileURLWithPath: $0) })
        } else { accessSelected(reveal: true) }
    }
    var selectedPaths: [String] {
        table.selectedRowIndexes.compactMap { $0 < matches.count ? matches[$0] : nil }
    }
    @objc func copySelectedFiles() {
        let selected = selectedPaths
        guard !selected.isEmpty else { return }
        // File URLs let Finder perform its standard copy when the user pastes.
        // Do not read file contents or traverse SMB folders while copying references.
        let items = selected.map { path -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
            return item
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.writeObjects(items) { NSSound.beep() }
    }
    @objc func copySelectedPath() {
        let selected = selectedPaths
        guard !selected.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.setString(selected.joined(separator: "\n"), forType: .string) { NSSound.beep() }
    }
    func openWithApplication(_ url: URL, application: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "无法打开这个文件或文件夹"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
    func accessSelected(reveal: Bool) {
        let row = table.selectedRow
        guard row >= 0, row < matches.count else { return }
        let path = matches[row]
        DispatchQueue.global(qos: .userInitiated).async {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            let directory = isDirectory.boolValue
            DispatchQueue.main.async {
                if exists {
                    let url = URL(fileURLWithPath: path)
                    if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    else if directory {
                        self.openWithApplication(url, application: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
                    }
                    else if Set(["doc", "docx", "docm", "dot", "dotx", "dotm", "wps", "wpt", "rtf", "txt", "xls", "xlsx", "xlsm", "xlt", "xltx", "xltm", "et", "ett", "csv", "ppt", "pptx", "pptm", "pps", "ppsx", "ppsm", "pot", "potx", "potm", "dps", "dpt", "pdf", "ofd"]).contains(url.pathExtension.lowercased()) {
                        if let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.kingsoft.wpsoffice.mac") { self.openWithApplication(url, application: application) }
                        else if !NSWorkspace.shared.open(url) { NSSound.beep() }
                    }
                    else if !NSWorkspace.shared.open(url) {
                        let alert = NSAlert()
                        alert.messageText = "无法打开这个文件"
                        alert.informativeText = "请确认已安装支持该格式的应用。也可以使用“在 Finder 中定位”选择打开方式。"
                        alert.runModal()
                    }
                }
                else {
                    let alert = NSAlert()
                    alert.messageText = "暂时无法访问这个文件"
                    alert.informativeText = "共享盘文件请确认对应共享盘已连接。文件也可能已被移动或删除，可刷新索引后重新搜索。"
                    alert.runModal()
                }
            }
        }
    }
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
