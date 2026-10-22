import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var store: TunnelStore!
    private var managerWindow: NSWindow?
    private var logWindow: NSWindow?
    private var logFilter = LogFilter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        store = TunnelStore()
        store.onChange = { [weak self] in self?.updateIcon() }
        store.openLog = { [weak self] filter in self?.showLog(filter: filter) }
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
    }

    // MARK: Значок и меню в трее

    private func updateIcon() {
        let anyUp = store.anyUp
        let image = NSImage(systemSymbolName: anyUp ? "network.badge.shield.half.filled" : "network",
                            accessibilityDescription: "WireGuard")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !anyUp
        let up = store.tunnels.filter(\.up).map(\.name)
        statusItem.button?.toolTip = up.isEmpty ? "WireGuard: всё выключено" : "WireGuard: " + up.joined(separator: ", ")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        store.reload()
        menu.removeAllItems()

        if let err = store.listError {
            let item = NSMenuItem(title: "Нет доступа к помощнику", action: nil, keyEquivalent: "")
            item.toolTip = err
            menu.addItem(item)
        } else if store.tunnels.isEmpty {
            menu.addItem(NSMenuItem(title: "Нет конфигов в /etc/wireguard", action: nil, keyEquivalent: ""))
        }

        for t in store.tunnels {
            let busy = store.busy.contains(t.name)
            let item = NSMenuItem(title: busy ? "\(t.name) …" : t.name, action: #selector(toggle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = t.name
            item.state = t.up ? .on : .off
            item.isEnabled = !busy
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(item("Управление туннелями…", #selector(showManager), "m"))
        menu.addItem(item("Журнал…", #selector(showLogAll), "l"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let up = store.isUp(name)
        Task {
            if let err = await store.setActive(name, !up) {
                showError("Не удалось \(up ? "выключить" : "включить") \(name)", err)
            }
        }
    }

    private func showError(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Окна

    @objc func showManager() {
        if managerWindow == nil {
            let host = NSHostingController(rootView: ManagerView().environmentObject(store))
            managerWindow = makeWindow(host, title: "WireGuard — туннели", autosave: "WGMenuManager", size: NSSize(width: 860, height: 580))
        }
        present(managerWindow!)
    }

    @objc private func showLogAll() { showLog(filter: "") }

    func showLog(filter: String) {
        logFilter.text = filter
        if logWindow == nil {
            let host = NSHostingController(rootView: LogContainer(filter: logFilter).environmentObject(store))
            logWindow = makeWindow(host, title: "WireGuard — журнал", autosave: "WGMenuLog", size: NSSize(width: 760, height: 480))
        }
        present(logWindow!)
    }

    private func makeWindow(_ host: NSViewController, title: String, autosave: String, size: NSSize) -> NSWindow {
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(size)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.setFrameAutosaveName(autosave)
        return w
    }

    /// Пока открыто окно, приложение видно в Dock и ⌘Tab; без окон — только значок в трее.
    private func present(_ w: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            let visible = [self.managerWindow, self.logWindow].contains { $0?.isVisible == true }
            if !visible { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showManager() }
        return true
    }

    // MARK: Главное меню — нужно, чтобы в редакторе работали ⌘C/⌘V/⌘Z/⌘A

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(NSMenuItem(title: "Скрыть WGMenu", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Выйти из WGMenu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenu(app, "WGMenu"))

        let edit = NSMenu(title: "Правка")
        edit.addItem(NSMenuItem(title: "Отменить", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Найти…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f"))
        edit.items.last?.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        main.addItem(submenu(edit, "Правка"))

        let window = NSMenu(title: "Окно")
        window.addItem(NSMenuItem(title: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(.separator())
        let tunnels = NSMenuItem(title: "Туннели", action: #selector(showManager), keyEquivalent: "1")
        tunnels.target = self
        window.addItem(tunnels)
        let log = NSMenuItem(title: "Журнал", action: #selector(showLogAll), keyEquivalent: "2")
        log.target = self
        window.addItem(log)
        main.addItem(submenu(window, "Окно"))
        NSApp.windowsMenu = window
        return main
    }

    private func submenu(_ menu: NSMenu, _ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Общий фильтр журнала, чтобы «Журнал» из карточки туннеля открывал окно уже отфильтрованным.
final class LogFilter: ObservableObject {
    @Published var text = ""
}

struct LogContainer: View {
    @ObservedObject var filter: LogFilter
    var body: some View { LogView(filter: $filter.text) }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
