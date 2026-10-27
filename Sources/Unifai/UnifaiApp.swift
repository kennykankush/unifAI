import SwiftUI
import AppKit
import Combine
import UnifaiCore

@main
struct UnifaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AppStore
    private let fixtureMode: Bool

    init() {
        let args = CommandLine.arguments
        // Build-time helper: render the app icon to a PNG for the .icns, then exit.
        if let index = args.firstIndex(of: "--export-icon"), args.indices.contains(index + 1) {
            guard let image = AppIconArtwork.render(), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  (try? png.write(to: URL(fileURLWithPath: args[index + 1]))) != nil else { exit(1) }
            exit(0)
        }
        // Channels keep the local development build apart from the official release:
        // separate data folder and Keychain service, so both can be installed side by side.
        let channel = Bundle.main.object(forInfoDictionaryKey: "UnifaiChannel") as? String ?? "release"
        fixtureMode = args.contains("--fixture-mode") || Bundle.main.object(forInfoDictionaryKey: "UnifaiFixtureMode") as? Bool == true
        let directory: URL
        if let index = args.firstIndex(of: "--data-directory"), args.indices.contains(index + 1), args[index + 1].hasPrefix("/") {
            directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else if fixtureMode, let path = Bundle.main.object(forInfoDictionaryKey: "UnifaiDataDirectory") as? String {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let folder = fixtureMode ? "Unifai Fixtures" : channel == "dev" ? "Unifai Dev" : "Unifai"
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(folder, isDirectory: true)
        }
        let repository = StateRepository(directory: directory)
        let model: AppStore
        if fixtureMode {
            let vault = MemoryVault()
            model = AppStore(repository: repository, vault: vault,
                             balances: FixtureWorkspace.balance, releases: FixtureWorkspace.releases, rates: FixtureWorkspace.rates,
                             status: FixtureWorkspace.status, posts: FixtureWorkspace.posts, feeds: FixtureWorkspace.feeds)
            if !args.contains("--fixture-empty"), Bundle.main.object(forInfoDictionaryKey: "UnifaiFixtureEmpty") as? Bool != true, model.loadFailure == nil {
                do { try FixtureWorkspace.prepare(model, vault: vault) }
                catch { model.notice = "Fixture setup failed: \(error.localizedDescription)" }
            }
            if Bundle.main.object(forInfoDictionaryKey: "UnifaiKeychainCheck") as? Bool == true {
                FixtureWorkspace.checkNativeKeychain(directory: directory)
            }
        } else if channel == "dev" {
            model = AppStore(repository: repository, vault: KeychainVault(service: "dev.unifai.dev.account-credentials.v1"))
        } else { model = AppStore(repository: repository) }
        AppRuntime.store = model
        AppRuntime.fixtureMode = fixtureMode
        AppRuntime.channel = fixtureMode ? "fixture" : channel
        // Demo and dev builds: open a specific screen for visual verification.
        if fixtureMode || channel == "dev", let index = args.firstIndex(of: "--destination"), args.indices.contains(index + 1) {
            AppRuntime.initialDestination = args[index + 1] == "Releases" ? .timeline : Destination(rawValue: args[index + 1])
        }
        // Visual checks: open the detail view of the first wallet of a service.
        if fixtureMode || channel == "dev", let index = args.firstIndex(of: "--test-wallet"), args.indices.contains(index + 1) {
            AppRuntime.initialWallet = model.state.accounts.first { $0.integrationID == args[index + 1] }?.id
        }
        // Visual checks: show a given billboard face first.
        if fixtureMode || channel == "dev", let index = args.firstIndex(of: "--test-board"), args.indices.contains(index + 1) {
            AppRuntime.initialBoard = Int(args[index + 1])
        }
        // Visual checks: open the first page scrolled to a fraction of its height.
        if fixtureMode || channel == "dev", let index = args.firstIndex(of: "--test-scroll"), args.indices.contains(index + 1), let fraction = Double(args[index + 1]) {
            AppRuntime.initialScroll = UnitPoint(x: 0, y: min(1, max(0, fraction)))
        }
        _store = StateObject(wrappedValue: model)
        // Visual checks: write a month's statement (YYYY-MM) as PDF and CSV, then exit.
        if fixtureMode || channel == "dev", let index = args.firstIndex(of: "--export-statement"), args.indices.contains(index + 2),
           let month = StatementMonth.parser.date(from: args[index + 1]) {
            let statement = MonthlyStatement(state: model.state, month: month, rates: model.rates)
            let directory = URL(fileURLWithPath: args[index + 2], isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? StatementPDF.render(statement).write(to: directory.appendingPathComponent(statement.fileName + ".pdf"))
            try? statement.csv.write(to: directory.appendingPathComponent(statement.fileName + ".csv"), atomically: true, encoding: .utf8)
            exit(0)
        }
        // Visual checks: render every widget size from this workspace's data to PNGs, then exit.
        if fixtureMode || channel == "dev", let index = args.firstIndex(of: "--export-widgets"), args.indices.contains(index + 1) {
            WidgetPreviews.export(WidgetPublisher.snapshot(model), to: URL(fileURLWithPath: args[index + 1], isDirectory: true))
            exit(0)
        }
    }
    var body: some Scene {
        Window("Unifai", id: "main") {
            MainView(fixtureMode: fixtureMode).environmentObject(store)
                .frame(minWidth: 1180, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 900)
        .commands { MainWindowCommands() }
    }
}

struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings...") { openWindow(id: "main"); AppRuntime.openSettings?() }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("Show Unifai") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("1", modifiers: .command)
            Button("Show Companion") { AppRuntime.showCompanion?() }.keyboardShortcut("m", modifiers: [.command, .shift])
        }
    }
}

@MainActor enum AppRuntime {
    static var store: AppStore?
    static var fixtureMode = false
    static var channel = "release"
    static var initialDestination: Destination?
    static var initialScroll: UnitPoint?
    static var initialWallet: UUID?
    static var initialBoard: Int?

    /// Development and demo builds only: `--test-click x,y` sends a click to the main window at a
    /// point measured from its top-left corner, through normal AppKit hit-testing, without moving
    /// the pointer or touching other apps. Used to verify that controls actually receive clicks.
    static func scheduleTestClick() {
        guard channel != "release", let index = CommandLine.arguments.firstIndex(of: "--test-click"),
              CommandLine.arguments.indices.contains(index + 1) else { return }
        let parts = CommandLine.arguments[index + 1].split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        // Optional --test-window WxH fixes the window size first, so click coordinates are deterministic.
        if let sizeIndex = CommandLine.arguments.firstIndex(of: "--test-window"), CommandLine.arguments.indices.contains(sizeIndex + 1) {
            let size = CommandLine.arguments[sizeIndex + 1].split(separator: "x").compactMap { Double($0) }
            DispatchQueue.main.async {
                if size.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Unifai" }) {
                    window.setFrame(NSRect(x: 100, y: 100, width: size[0], height: size[1]), display: true)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Unifai" }) ?? NSApp.windows.first(where: \.isVisible) else { return }
            let point = NSPoint(x: parts[0], y: window.frame.height - parts[1])
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            // Queue the mouse-up first: AppKit controls track the press in a loop that reads it from the queue.
            if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
            if let down = event(.leftMouseDown) { window.sendEvent(down) }
        }
    }
    static var showCompanion: (() -> Void)?
    static var openMain: (() -> Void)?
    static var openSettings: (() -> Void)?
    static var navigate: ((Destination) -> Void)?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var companion: MenuBarController?
    private var widgets: WidgetPublisher?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let icon = AppIconArtwork.render() { NSApp.applicationIconImage = icon }
        Notifier.shared.start()
        if let store = AppRuntime.store {
            companion = MenuBarController(store: store, fixtureMode: AppRuntime.fixtureMode)
            widgets = WidgetPublisher(store: store)
            AppRuntime.showCompanion = { [weak self] in self?.companion?.toggle() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Widget taps open unifai://<page> (unifai-dev:// for the dev build).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let host = urls.first?.host?.lowercased() else { return }
        let destination: Destination? = ["payments": .payments, "wallets": .accounts, "timeline": .timeline, "subscriptions": .subscriptions, "overview": .today][host]
        AppRuntime.openMain?()
        if let destination { AppRuntime.navigate?(destination) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppRuntime.openMain?() }
        return true
    }
}

struct MenuPanel: View {
    @EnvironmentObject private var store: AppStore
    let fixtureMode: Bool
    var body: some View {
        let combined = store.state.displayCurrency.flatMap { target in store.rates.map { Ledger.paidTotals(store.state.payments(in: target, rates: $0).converted) } }
        let totals = combined ?? Ledger.paidTotals(store.state.payments)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AppMark(size: 24)
                Text("Unifai").font(.system(size: 14, weight: .bold))
                Spacer()
                if fixtureMode { Chip(text: "Demo", tint: Palette.warning, symbol: "testtube.2") }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = store.loadFailure { InlineNotice(text: error) }
                    ZStack(alignment: .topLeading) {
                        MeshBackdrop(colors: Palette.hero)
                        VStack(alignment: .leading, spacing: 6) {
                            if let currency = store.state.monthlyBudget?.currency ?? store.state.displayCurrency {
                                let month = store.state.monthToDateSpend(in: currency, rates: store.rates, includeAccruing: true).spent
                                Text("This month, including usage so far").font(.system(size: 11, weight: .semibold)).opacity(0.85)
                                MoneyText(money: month, size: 22, weight: .heavy)
                                if let budget = store.state.monthlyBudget {
                                    UsageMeter(used: budget.amount > 0 ? NSDecimalNumber(decimal: month.amount / budget.amount).doubleValue : 0, tint: Palette.lime)
                                    Text("of \(budget.amountText) \(budget.currency) budget").font(.system(size: 10, weight: .medium)).opacity(0.75)
                                }
                                Divider().overlay(Color.white.opacity(0.3))
                            }
                            Text("Total paid for AI").font(.system(size: 12, weight: .semibold)).opacity(0.85)
                            if totals.isEmpty { Text("Nothing yet").font(.system(size: 24, weight: .heavy)) }
                            ForEach(totals) { MoneyText(money: $0, size: totals.count > 1 ? 22 : 28, weight: .heavy) }
                            Text(store.state.coverageDescription).font(.system(size: 10, weight: .medium)).opacity(0.75)
                        }
                        .padding(16)
                    }
                    .foregroundStyle(.white)
                    .frame(height: (totals.count > 1 ? 136 : 112) + (store.state.monthlyBudget != nil ? 90 : store.state.displayCurrency != nil ? 62 : 0))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text("Wallets").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                    if store.state.accounts.isEmpty { Text("No accounts connected").font(.system(size: 12)).foregroundStyle(.secondary) }
                    ForEach(store.state.accounts) { account in
                        HStack(spacing: 10) {
                            LogoCircle(integrationID: account.integrationID, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Catalogue.integration(account.integrationID)?.name ?? account.integrationID).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(account.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                if let snapshot = account.snapshot {
                                    ForEach(snapshot.balances) { MoneyText(money: $0, size: 13) }
                                    if snapshot.balances.isEmpty, let spent = snapshot.reportedConsumption.first { MoneyText(money: spent, size: 13) }
                                    if snapshot.balances.isEmpty, snapshot.reportedConsumption.isEmpty, let plan = snapshot.plan { Text(plan).font(.system(size: 12, weight: .semibold)) }
                                    if let windows = snapshot.allowances, !windows.isEmpty {
                                        Text(windows.map { "\(WalletCard.shortName($0)) \($0.usedPercent)%" }.joined(separator: " · "))
                                            .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                            .foregroundStyle(snapshot.limitReached == true ? Palette.negative : .secondary)
                                    }
                                    if account.lastError != nil || snapshot.isStale() { Chip(text: "Needs attention", tint: Palette.warning) }
                                } else { Text(account.mode == .manual ? "Manual" : "Not refreshed").font(.system(size: 11)).foregroundStyle(.tertiary) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack {
                Button("Open Unifai") { AppRuntime.openMain?() }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(PillButtonStyle(compact: true)).accessibilityLabel("Quit Unifai").keyboardShortcut("q")
            }.padding(12)
        }
        .frame(width: 340, height: 500)
        .background(Palette.canvas)
    }
}

@MainActor final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var observation: AnyCancellable?
    private weak var store: AppStore?
    init(store: AppStore, fixtureMode: Bool) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.store = store
        super.init()
        observation = store.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateTitle() } }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 500)
        popover.contentViewController = NSHostingController(rootView: MenuPanel(fixtureMode: fixtureMode).environmentObject(store))
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Unifai")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Unifai"
            button.setAccessibilityLabel("Unifai")
            button.target = self; button.action = #selector(toggle)
            button.imagePosition = .imageLeading
        }
        updateTitle()
    }

    /// Menu bar text: this month's spend (with pay-as-you-go usage) and Codex's weekly usage when connected.
    private func updateTitle() {
        guard let store, let button = statusItem.button else { return }
        let currency = store.state.monthlyBudget?.currency ?? store.state.displayCurrency ?? SpendSeries.currencies(store.state.payments).first
        var parts: [String] = []
        if let currency {
            let spent = store.state.monthToDateSpend(in: currency, rates: store.rates, includeAccruing: true).spent
            parts.append("\(currency) \(Int(NSDecimalNumber(decimal: spent.amount).doubleValue.rounded()))")
        }
        if let weekly = store.state.accounts.first(where: { $0.integrationID == "codex" })?.snapshot?.allowances?.first(where: { $0.windowMinutes == 10080 }) {
            parts.append("Codex \(weekly.usedPercent)%")
        }
        button.attributedTitle = NSAttributedString(string: parts.isEmpty ? "" : " " + parts.joined(separator: " · "),
                                                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

private enum StatementMonth {
    /// Parses YYYY-MM in local time.
    static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM"
        return formatter
    }()
}
