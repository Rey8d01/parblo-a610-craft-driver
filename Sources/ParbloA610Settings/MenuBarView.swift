import ParbloA610Core
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var driver: DriverStatus
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(driver.state.isHealthy ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(driver.state.title)
                    .font(.headline)
            }

            Divider()

            Picker("Display", selection: displayBinding) {
                ForEach(model.displays) { display in
                    Text(display.title).tag(display.configValue)
                }
            }
            Picker("Rotation", selection: $model.config.orientation) {
                ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
            }

            Divider()

            Button("Settings and calibration…") { openWindow(id: "settings") }
            Button("Restart the driver") { driver.restart() }
            Button("Show the log in Finder") { revealLog() }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { driver.refresh() }
    }

    private var displayBinding: Binding<String> {
        Binding(
            get: { model.selectedDisplay?.configValue ?? "main" },
            set: { model.config.display = $0 })
    }

    private func revealLog() {
        let log = ConfigStore.url.deletingLastPathComponent()
            .appendingPathComponent("parblo-a610-craft-driver.log")
        NSWorkspace.shared.activateFileViewerSelecting([log])
    }
}
