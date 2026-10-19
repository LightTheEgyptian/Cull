import SwiftUI
import AppKit

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1"
    static let repo = URL(string: "https://github.com/LightTheEgyptian/Cull")!
    static let issues = URL(string: "https://github.com/LightTheEgyptian/Cull/issues")!

    /// The standard Mac About window, with who made it and how it can be used.
    static func showAbout() {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 6
        func line(_ s: String, size: CGFloat = 11, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSAttributedString {
            NSAttributedString(string: s + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: para,
            ])
        }
        let credits = NSMutableAttributedString()
        credits.append(line("Made by Nur Elmasri", size: 12, weight: .semibold))
        credits.append(line("A fast, private way to cull a photo shoot: keep, reject, star and export, with your Mac checking focus and eyes for you.", color: .secondaryLabelColor))
        credits.append(line("Free and open source under the MIT License. Anyone can use it, change it and share it.", color: .secondaryLabelColor))
        credits.append(line("Everything runs on your Mac. Cull never uploads your photos.", color: .secondaryLabelColor))
        let link = NSMutableAttributedString(string: "github.com/LightTheEgyptian/Cull", attributes: [
            .link: repo, .font: NSFont.systemFont(ofSize: 11, weight: .medium), .paragraphStyle: para,
        ])
        credits.append(link)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Cull",
            .applicationVersion: version,
            .version: "",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Nur Elmasri · MIT License",
        ])
    }
}

@main
struct CullApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        Window("Cull", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Cull") { AppInfo.showAbout() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { store.openPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo)
            }
            CommandGroup(after: .importExport) {
                Button("Export for Clients…") { store.showExport = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.folder == nil)
            }
            CommandMenu("Photo") {
                // single-key shortcuts pause while the export sheet is open, so typing a watermark works
                Group {
                Button("Next Photo") { store.step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("Previous Photo") { store.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Divider()
                Button("Keep") { store.mark(.keep) }.keyboardShortcut("p", modifiers: [])
                Button("Reject") { store.mark(.reject) }.keyboardShortcut("x", modifiers: [])
                Button("Clear Mark and Stars") { store.clearMark() }.keyboardShortcut("u", modifiers: [])
                Menu("Rating") {
                    ForEach(1...5, id: \.self) { n in
                        Button(String(repeating: "★", count: n)) { store.rate(n) }
                            .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
                    }
                }
                Divider()
                Button("Keep Best of Burst") { store.keepBestOfBurst() }.keyboardShortcut("b", modifiers: [])
                Button(store.comparing ? "Stop Comparing" : "Compare") { store.toggleCompare() }.keyboardShortcut("c", modifiers: [])
                Divider()
                Button(store.faceZoom ? "Show Whole Photo" : "Zoom to Faces") { store.toggleFaceZoom() }.keyboardShortcut("f", modifiers: [])
                Button(store.zoomed ? "Fit to Window" : "Zoom to 100%") { store.toggleZoom() }.keyboardShortcut("z", modifiers: [])
                Button(store.showInfo ? "Hide Camera Info" : "Show Camera Info") { store.toggleInfo() }.keyboardShortcut("i", modifiers: [])
                }
                .disabled(store.showExport)
                Divider()
                Toggle("Go to Next After Marking", isOn: $store.autoAdvance)
                Toggle("Save Ratings for Lightroom (XMP)", isOn: $store.writeXMP)
                Divider()
                Button("Reject Flagged Photos") { store.rejectFlagged() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Move Keepers and Rejects") { store.apply() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Undo Move") { store.undoMove() }
                    .disabled(!store.canUndoMove)
            }
            CommandGroup(after: .toolbar) {
                ForEach(Array(Filter.allCases.enumerated()), id: \.element) { i, f in
                    Button("Show \(f.title)") { store.setFilter(f) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { store.showShortcuts = true }.keyboardShortcut("/", modifiers: .command)
                Divider()
                Button("Cull on GitHub") { NSWorkspace.shared.open(AppInfo.repo) }
                Button("Report a Problem…") { NSWorkspace.shared.open(AppInfo.issues) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        if let u = urls.first { Task { @MainActor in Store.shared.open(u) } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
