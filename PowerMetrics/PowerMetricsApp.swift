import SwiftUI

@main
struct PowerMetricsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) {} }
        
        Settings { SettingsView() }
    }
}

struct SettingsView: View {
    @AppStorage("updateInterval") private var updateInterval: Double = 1.0
    @AppStorage("chartCapacity") private var chartCapacity: Int = 180
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("Update Interval: \(updateInterval, specifier: "%.1f")s")
                    Slider(value: $updateInterval, in: 0.1...3.0, step: 0.1)
                }
                .padding(.bottom, 10)
                
                VStack(alignment: .leading) {
                    Text("Chart Capacity: \(chartCapacity) points")
                    Slider(value: Binding(get: { Double(chartCapacity) }, set: { chartCapacity = Int($0) }), in: 60...360, step: 10)
                }
            }
        }
        .padding(20)
        .frame(width: 350)
        .navigationTitle("Power Gadget Settings")
    }
}

// Intercepts close commands, manages window behaviors, space shifts, and pinning configurations
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { return false }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        if let window = NSApp.windows.first {
            window.delegate = self
            window.tabbingMode = .disallowed
            // Apply initial level/pinning configuration on startup
            MonitorState.shared.updatePinning(window: window)
        }
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MonitorState.shared.stopPolling()
        // Use orderOut to remove the window from view instead of hiding the entire application process.
        // This prevents macOS from associating the hidden window with any locked virtual desktop space.
        sender.orderOut(nil)
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MonitorState.shared.start()
        if !flag {
            if let window = sender.windows.first {
                window.delegate = self
                window.tabbingMode = .disallowed
                
                let isPinned = MonitorState.shared.isPinned
                if isPinned {
                    // Pinned windows are already globally configured to join all active spaces naturally
                    window.makeKeyAndOrderFront(nil)
                } else {
                    // Temporarily apply joint space behavior to draw the window onto your current Space,
                    // then immediately release it so it stays anchored to this space.
                    let originalBehavior = window.collectionBehavior
                    window.collectionBehavior = originalBehavior.union(.canJoinAllSpaces)
                    window.makeKeyAndOrderFront(nil)
                    
                    DispatchQueue.main.async {
                        window.collectionBehavior = originalBehavior
                    }
                }
            }
            // Return false here to tell SwiftUI we handled the action and to NOT spawn a new duplicate window.
            return false
        }
        return true
    }
}
