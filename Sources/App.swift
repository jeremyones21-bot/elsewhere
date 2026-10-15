import SwiftUI

@main
struct ElsewhereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Elsewhere", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Location") {
                Button("Change Location") { Task { await model.changeLocation() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.mode != .fixed || !model.deviceReady || model.pin == nil)
                Button("Reset Location") { Task { await model.resetLocation() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.deviceReady)
                Button("Keep After Unplugging…") { model.beginKeep() }
                    .disabled(!model.canKeep)
                Divider()
                Button("Static Mode") { model.setMode(.fixed) }.keyboardShortcut("1")
                Button("Route Mode") { model.setMode(.route) }.keyboardShortcut("2")
                Divider()
                Button("Bookmark") { model.addBookmark() }.keyboardShortcut("d")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Closing the helper's stdin makes it stop the simulation before it exits.
        MainActor.assumeIsolated { model?.helper.stop() }
    }
}
