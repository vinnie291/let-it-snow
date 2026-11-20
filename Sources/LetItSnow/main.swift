import Cocoa
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = SnowSettings.shared
    private var overlayController: OverlayController?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var toggleSnowItem: NSMenuItem?
    private var dismissStormItem: NSMenuItem?
    private var presetsSubmenu: NSMenu?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        overlayController = OverlayController(settings: settings)
        setupMenuBar()
        openSettingsWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = item.button {
            let img = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Let It Snow")
            img?.isTemplate = true
            btn.image = img
            btn.toolTip = "Let It Snow"
        }

        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        openItem.target = self
        menu.addItem(openItem)

        let toggleItem = NSMenuItem(
            title: settings.isSnowing ? "Pause Snow" : "Resume Snow",
            action: #selector(toggleSnowAction),
            keyEquivalent: "p"
        )
        toggleItem.target = self
        menu.addItem(toggleItem)
        self.toggleSnowItem = toggleItem

        menu.addItem(.separator())

        let gustItem = NSMenuItem(title: "Trigger Wind Gust", action: #selector(triggerGustAction), keyEquivalent: "g")
        gustItem.target = self
        menu.addItem(gustItem)

        let shakeItem = NSMenuItem(title: "Shake Icons & Dock", action: #selector(shakeAction), keyEquivalent: "s")
        shakeItem.target = self
        menu.addItem(shakeItem)

        let waveItem = NSMenuItem(title: "Spawn Snowcraft Dudes", action: #selector(spawnWaveAction), keyEquivalent: "w")
        waveItem.target = self
        menu.addItem(waveItem)

        let clearItem = NSMenuItem(title: "Clear All Snow", action: #selector(clearSnowAction), keyEquivalent: "k")
        clearItem.target = self
        menu.addItem(clearItem)

        let dismissItem = NSMenuItem(title: "Dismiss Active Storm", action: #selector(dismissStormAction), keyEquivalent: "")
        dismissItem.target = self
        dismissItem.isHidden = !settings.isWeatherStormActive
        menu.addItem(dismissItem)
        self.dismissStormItem = dismissItem

        // Presets submenu (built-in + custom saved presets)
        let presetsMenu = NSMenu()
        self.presetsSubmenu = presetsMenu
        rebuildPresetsSubmenu()
        let presetsRoot = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        presetsRoot.submenu = presetsMenu
        menu.addItem(.separator())
        menu.addItem(presetsRoot)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Let It Snow", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item

        settings.$isSnowing
            .sink { [weak self] snowing in
                self?.toggleSnowItem?.title = snowing ? "Pause Snow" : "Resume Snow"
            }
            .store(in: &cancellables)

        settings.$isWeatherStormActive
            .sink { [weak self] active in
                self?.dismissStormItem?.isHidden = !active
            }
            .store(in: &cancellables)

        settings.onCustomPresetsChanged = { [weak self] in
            self?.rebuildPresetsSubmenu()
        }
    }

    private func rebuildPresetsSubmenu() {
        guard let presetsMenu = presetsSubmenu else { return }
        presetsMenu.removeAllItems()
        for preset in SnowPreset.allCases {
            let pItem = NSMenuItem(title: preset.rawValue, action: #selector(selectPresetAction(_:)), keyEquivalent: "")
            pItem.target = self
            pItem.representedObject = preset.rawValue
            presetsMenu.addItem(pItem)
        }
        if !settings.customPresets.isEmpty {
            presetsMenu.addItem(.separator())
            for custom in settings.customPresets {
                let cItem = NSMenuItem(title: "★ \(custom.name)", action: #selector(selectCustomPresetAction(_:)), keyEquivalent: "")
                cItem.target = self
                cItem.representedObject = custom.id.uuidString
                presetsMenu.addItem(cItem)
            }
        }
    }

    @objc private func openSettingsAction() {
        openSettingsWindow()
    }

    @objc private func toggleSnowAction() {
        settings.isSnowing.toggle()
    }

    @objc private func triggerGustAction() {
        settings.onTriggerGust?()
    }

    @objc private func shakeAction() {
        settings.onShakeSurfaces?()
    }

    @objc private func spawnWaveAction() {
        settings.snowcraftGameEnabled = true
        settings.onSpawnSnowcraftWave?()
    }

    @objc private func clearSnowAction() {
        settings.onClearSnow?()
    }

    @objc private func dismissStormAction() {
        settings.onDismissStorm?()
    }

    @objc private func selectPresetAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = SnowPreset(rawValue: raw) else { return }
        settings.applyPreset(preset)
    }

    @objc private func selectCustomPresetAction(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let uuid = UUID(uuidString: idStr),
              let custom = settings.customPresets.first(where: { $0.id == uuid }) else { return }
        settings.applyCustomPreset(custom)
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    private func openSettingsWindow() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(settings: settings))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Let It Snow — Settings"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = win
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
