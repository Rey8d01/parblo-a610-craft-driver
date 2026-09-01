import ParbloA610Core
import SwiftUI

@main
struct ParbloA610SettingsApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var pen = PenMonitor()
    @StateObject private var driver = DriverStatus()

    var body: some Scene {
        MenuBarExtra("Parblo A610", systemImage: "applepencil.tip") {
            MenuBarView(model: model, driver: driver)
        }
        .menuBarExtraStyle(.window)

        Window("Parblo A610", id: "settings") {
            SettingsView(model: model, pen: pen, driver: driver)
                .onAppear {
                    pen.start()
                    driver.refresh()
                }
                // The window closes, the app stays in the menu bar. Without this
                // the local event monitor and the one second ticker would run for
                // the rest of the session with nobody to show them to.
                .onDisappear { pen.stop() }
        }
        .defaultSize(width: 620, height: 780)
        .windowResizability(.contentMinSize)
    }
}
