import AppKit

/// Rozmova lives in the menu bar, but while one of its windows is open it behaves like a normal
/// app: Dock icon, Cmd+Tab, a main menu with Cmd+W. When the last such window closes it goes back
/// to the menu bar only. The "record?" prompt panel doesn't count: it must not pull the app forward.
@MainActor
enum DockPresence {
    private static var windows: [NSWindow] = []
    private static var observers: [NSObjectProtocol] = []

    /// Call right before showing a window that should bring the Dock icon.
    static func show(_ window: NSWindow) {
        if !windows.contains(where: { $0 === window }) {
            windows.append(window)
            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                // willClose fires before the window is hidden: decide once it is gone.
                DispatchQueue.main.async { MainActor.assumeIsolated { update() } }
            }
            observers.append(observer)
        }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Windows still open, minimized ones included.
    static var openWindows: [NSWindow] {
        windows.filter { $0.isVisible || $0.isMiniaturized }
    }

    private static func update() {
        if openWindows.isEmpty, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// The main menu shown while the app is in the Dock: app menu, Edit (copy, select all)
    /// and Window with Close (Cmd+W) and Minimize (Cmd+M).
    static func installMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Сховати Rozmova", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Сховати інші", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Показати всі", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Вийти з Rozmova", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "Rozmova", to: main)

        let edit = NSMenu(title: "Редагування")
        edit.addItem(withTitle: "Скасувати", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторити", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вирізати", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копіювати", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставити", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Виділити все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, title: "Редагування", to: main)

        let window = NSMenu(title: "Вікно")
        window.addItem(withTitle: "Закрити", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Згорнути", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Масштабувати", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, title: "Вікно", to: main)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private static func add(_ submenu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}
