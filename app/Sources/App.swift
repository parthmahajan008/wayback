// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Parth Mahajan

import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct WaybackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Wayback", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 600)
                .task { await model.start() }
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Find") { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                    .keyboardShortcut("f")
                Button("Search Mode") { model.mode = .search }.keyboardShortcut("1")
                Button("Ask Mode") { model.mode = .ask }.keyboardShortcut("2")
                Divider()
                Button("Reindex Now") { model.reindex() }.keyboardShortcut("r")
            }
            // ⌘W minimises instead of closing, so the window keeps its state.
            CommandGroup(replacing: .saveItem) {
                Button("Minimize Window") {
                    AppDelegate.mainWindow?.miniaturize(nil)
                }
                .keyboardShortcut("w")
            }
        }

        MenuBarExtra("Wayback", systemImage: "text.magnifyingglass") {
            MenuSearchView().environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerHotKey()
    }

    // Keep running (and indexing) in the menu bar when the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.showMain() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Self.showMain()
        // Give a freshly opened window time to subscribe before posting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .openQueryURL, object: url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Backend.shared.stop()
    }

    /// The main window (the menu bar popover is also titled "Wayback" but can't be minimised).
    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.miniaturizable) && $0.title == "Wayback" }
    }

    static func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindow, w.isVisible || w.isMiniaturized {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            WindowOpener.shared.open?()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .focusSearch, object: nil)
        }
    }

    /// Global ⌥⇧Space hotkey via Carbon (no accessibility permission needed).
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { AppDelegate.showMain() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5353_4348), id: 1)  // 'SSCH'
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | shiftKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
