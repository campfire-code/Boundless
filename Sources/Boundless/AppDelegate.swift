import AppKit
import BoundlessCore
import Carbon
import ServiceManagement

/// 带闭包的菜单项
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("不支持从 nib 创建") }

    @objc private func fire() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private var statusItem: NSStatusItem!
    private var server: ServerController?
    private var client: ClientController?
    private var arrangementWindow: ArrangementWindowController?
    /// 「把被控端窗口移过来」子菜单，收到窗口列表时就地刷新
    private let mirrorMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        mirrorMenu.delegate = self

        if settings.role == nil { askRole() }
        startRole()
        if UserDefaults.standard.bool(forKey: "showArrangement") { showArrangement() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        client?.stop()
    }

    // MARK: - 角色

    private func askRole() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "欢迎使用无界"
        alert.informativeText = "请选择这台 Mac 的角色：\n· 主控端：接着键盘鼠标，共享给另一台\n· 被控端：被另一台的键盘鼠标控制\n\n之后可在菜单栏图标里随时更改。"
        alert.addButton(withTitle: "主控端")
        alert.addButton(withTitle: "被控端")
        alert.addButton(withTitle: "稍后")
        switch alert.runModal() {
        case .alertFirstButtonReturn: settings.role = .server
        case .alertSecondButtonReturn: settings.role = .client
        default: break
        }
    }

    private func startRole() {
        server?.stop()
        client?.stop()
        server = nil
        client = nil
        arrangementWindow?.close()
        arrangementWindow = nil

        switch settings.role {
        case .server?:
            if !Permissions.accessibility { Permissions.requestAccessibility() }
            if !Permissions.inputMonitoring { Permissions.requestInputMonitoring() }
            let s = ServerController(settings: settings)
            s.onChange = { [weak self] in self?.refreshIcon() }
            s.onWindowList = { [weak self] in
                guard let self else { return }
                self.fillMirrorMenu(self.mirrorMenu)
            }
            s.start()
            server = s
        case .client?:
            if !Permissions.accessibility && !settings.dryRun { Permissions.requestAccessibility() }
            let c = ClientController(settings: settings)
            c.onChange = { [weak self] in self?.refreshIcon() }
            c.start()
            client = c
            if settings.clientCode == nil { promptClientCode() }
        case nil:
            break
        }
        refreshIcon()
    }

    // MARK: - 状态

    private var statusText: String {
        server?.statusText ?? client?.statusText ?? "未选择角色"
    }

    private func refreshIcon() {
        let remote = server?.isRemote ?? client?.isRemote ?? false
        let connected = server?.isConnected ?? client?.isConnected ?? false
        let symbol = remote ? "cursorarrow.rays" : connected ? "display.2" : "keyboard"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "无界")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "无界：\(statusText)"
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === mirrorMenu {
            fillMirrorMenu(menu)
            return
        }
        menu.removeAllItems()
        menu.addItem(info(statusText))
        menu.addItem(.separator())

        switch settings.role {
        case .server?: addServerItems(to: menu)
        case .client?: addClientItems(to: menu)
        case nil: menu.addItem(info("请先在下方选择这台 Mac 的角色"))
        }

        menu.addItem(ActionItem("切换时同步剪贴板", checked: settings.clipboardSync) { [weak self] in
            guard let self else { return }
            self.settings.clipboardSync.toggle()
        })
        menu.addItem(.separator())

        let roleMenu = NSMenu()
        roleMenu.addItem(ActionItem("主控端（共享本机键鼠）", checked: settings.role == .server) { [weak self] in
            self?.switchRole(.server)
        })
        roleMenu.addItem(ActionItem("被控端（被另一台控制）", checked: settings.role == .client) { [weak self] in
            self?.switchRole(.client)
        })
        menu.addItem(submenu("本机角色", roleMenu))

        addPermissionItems(to: menu)
        menu.addItem(ActionItem("登录时自动启动", checked: SMAppService.mainApp.status == .enabled) { [weak self] in
            self?.toggleLaunchAtLogin()
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("退出无界") { NSApp.terminate(nil) })
    }

    private func addServerItems(to menu: NSMenu) {
        let code = settings.serverCode
        menu.addItem(ActionItem("配对码：\(code)（点击复制）") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        })

        menu.addItem(ActionItem("屏幕排列…") { [weak self] in self?.showArrangement() })
        // 打开菜单时就去要窗口列表，展开子菜单时一般已经到了；晚到的会就地刷新
        server?.requestWindowList()
        let mirrorItem = submenu("把被控端窗口移过来", mirrorMenu)
        mirrorItem.isEnabled = server?.isConnected ?? false
        menu.addItem(mirrorItem)
        menu.addItem(ActionItem("重新生成配对码…") { [weak self] in self?.regenerateCode() })
        if let server, let side = server.arrangement?.side(relativeTo: server.desktop) {
            menu.addItem(info("快捷键：⌃⌥⌘\(side.arrowSymbol) 过去，⌃⌥⌘\(side.opposite.arrowSymbol) 回来"))
        } else {
            menu.addItem(info("被控端连上后即可排列屏幕、使用快捷键"))
        }
        if IsSecureEventInputEnabled() {
            menu.addItem(info("⚠️ 有应用开启了安全输入（如密码框），键盘暂时无法转发"))
        }
    }

    private func addClientItems(to menu: NSMenu) {
        menu.addItem(ActionItem(settings.clientCode == nil ? "输入配对码…" : "修改配对码…") { [weak self] in
            self?.promptClientCode()
        })

        let serverMenu = NSMenu()
        serverMenu.addItem(ActionItem("自动（只发现一台时）", checked: settings.preferredServer == nil) { [weak self] in
            self?.settings.preferredServer = nil
            self?.client?.reconnect()
        })
        let names = Set(client?.servers.keys.map { $0 } ?? []).union(settings.preferredServer.map { [$0] } ?? [])
        for name in names.sorted() {
            let online = client?.servers[name] != nil
            serverMenu.addItem(ActionItem(online ? name : "\(name)（离线）", checked: settings.preferredServer == name) { [weak self] in
                self?.settings.preferredServer = name
                self?.client?.reconnect()
            })
        }
        menu.addItem(submenu("连接的主控端", serverMenu))
        if settings.dryRun { menu.addItem(info("联调模式：只打印，不注入")) }
    }

    private func addPermissionItems(to menu: NSMenu) {
        guard settings.role != nil else { return }
        let ax = Permissions.accessibility
        menu.addItem(ActionItem(ax ? "✅ 辅助功能权限" : "⚠️ 辅助功能权限（点击授权）") {
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        })
        if settings.role == .client {
            let sr = Permissions.screenRecording
            menu.addItem(ActionItem(sr ? "✅ 屏幕录制权限（窗口移到主控端用）" : "⚠️ 屏幕录制权限（窗口移到主控端用，点击授权）") {
                Permissions.requestScreenRecording()
                Permissions.openScreenRecordingSettings()
            })
        }
        if settings.role == .server {
            let im = Permissions.inputMonitoring
            menu.addItem(ActionItem(im ? "✅ 输入监控权限" : "⚠️ 输入监控权限（点击授权）") {
                Permissions.requestInputMonitoring()
                Permissions.openInputMonitoringSettings()
            })
        }
    }

    private func fillMirrorMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let server, server.isConnected else {
            menu.addItem(info("被控端未连接"))
            return
        }
        if server.hasVirtualWindows {
            menu.addItem(ActionItem("全部移回被控端") { [weak server] in server?.recallWindows() })
            menu.addItem(.separator())
        }
        if server.remoteWindows.isEmpty {
            menu.addItem(info("没有可移过来的窗口（被控端需授予「屏幕录制」权限）"))
            return
        }
        for w in server.remoteWindows {
            let title = w.title.count > 60 ? String(w.title.prefix(60)) + "…" : w.title
            menu.addItem(ActionItem(title.isEmpty ? w.app : "\(w.app) — \(title)") { [weak server] in
                server?.moveToVirtual(w)
            })
        }
    }

    // MARK: - 操作

    private func showArrangement() {
        guard let server else { return }
        if arrangementWindow == nil {
            let window = ArrangementWindowController(server: server)
            server.onArrangementChange = { [weak window] in window?.reload() }
            arrangementWindow = window
        }
        arrangementWindow?.show()
    }

    private func switchRole(_ role: Role) {
        guard settings.role != role else { return }
        settings.role = role
        startRole()
    }

    private func regenerateCode() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "重新生成配对码？"
        alert.informativeText = "当前连接会断开，被控端需要输入新的配对码才能重新连接。"
        alert.addButton(withTitle: "重新生成")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.regenerateServerCode()
        server?.restartListener()
    }

    private func promptClientCode() {
        NSApp.activate(ignoringOtherApps: true)
        var message = "在主控端菜单栏的无界图标里可以看到配对码（格式如 ABCD-EFGH-JKMN）。"
        while true {
            let alert = NSAlert()
            alert.messageText = "输入配对码"
            alert.informativeText = message
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.placeholderString = "XXXX-XXXX-XXXX"
            field.stringValue = settings.clientCode ?? ""
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if let code = Pairing.normalize(field.stringValue) {
                settings.clientCode = code
                client?.reconnect()
                return
            }
            message = "配对码格式不对：应为 12 位字母数字（不含 I、L、O、0、1），请重新输入。"
        }
    }

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "无法设置登录时启动"
            alert.informativeText = "\(error.localizedDescription)\n请先把「无界」放进「应用程序」文件夹再试。"
            alert.runModal()
        }
    }

    // MARK: - 工具

    private func info(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

private extension Edge {
    var arrowSymbol: String {
        switch self {
        case .left: return "←"
        case .right: return "→"
        case .top: return "↑"
        case .bottom: return "↓"
        }
    }
}
