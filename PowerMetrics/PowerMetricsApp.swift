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
                    // Update interval display with fine decimal precision
                    Text("Update Interval: \(updateInterval, specifier: "%.2f")s")
                    Slider(value: $updateInterval, in: 0.25...5.0, step: 0.25)
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
            MonitorState.shared.updatePinning(window: window)
        }
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MonitorState.shared.stopPolling()
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
                    window.makeKeyAndOrderFront(nil)
                } else {
                    let originalBehavior = window.collectionBehavior
                    window.collectionBehavior = originalBehavior.union(.canJoinAllSpaces)
                    window.makeKeyAndOrderFront(nil)
                    
                    DispatchQueue.main.async {
                        window.collectionBehavior = originalBehavior
                    }
                }
            }
            return false
        }
        return true
    }
}
