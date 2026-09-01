import ParbloA610Core
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pen: PenMonitor
    @ObservedObject var driver: DriverStatus

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                status

                GroupBox("Display") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Map to", selection: displayBinding) {
                            ForEach(model.displays) { Text($0.title).tag($0.configValue) }
                        }
                        Picker("Tablet rotation", selection: $model.config.orientation) {
                            ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                        }
                        Toggle("Keep the aspect ratio", isOn: $model.config.lockAspectRatio)
                        Text(
                            "The tablet is 5:3, Mac displays about 1.54:1. Without the fit a circle comes out an ellipse."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("Active area") {
                    VStack(alignment: .leading, spacing: 8) {
                        AreaMapperView(model: model, pen: pen)
                        Text(
                            "The blue rectangle is dragged and resized by a corner. The dashed line is what reaches the screen after the aspect fit. The orange dot is the pen."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Button("Whole tablet") {
                            model.config.activeArea = Config.Area()
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                    .padding(6)
                }

                GroupBox("Pen buttons") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Lower", selection: $model.config.penButtons.barrel1) {
                            ForEach(Config.ButtonAction.allCases, id: \.self) {
                                Text($0.title).tag($0)
                            }
                        }
                        Picker("Upper", selection: $model.config.penButtons.barrel2) {
                            ForEach(Config.ButtonAction.allCases, id: \.self) {
                                Text($0.title).tag($0)
                            }
                        }
                        Text("Hold a barrel button and you draw with the button it is mapped to.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("Pressure") {
                    VStack(alignment: .leading, spacing: 14) {
                        PressureCurveView(model: model, pen: pen)
                        ScribbleView(pen: pen)
                    }
                    .padding(6)
                }

                footer
            }
            .padding(18)
        }
        .frame(minWidth: 560, minHeight: 600)
    }

    /// The status refreshes itself. A "Refresh" button next to the settings would
    /// read as "apply", and settings already apply through the file on their own.
    private var status: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(driver.state.isHealthy ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(driver.state.title)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restart the driver") { driver.restart() }
                .help("Stops the driver and starts it again. Drawing pauses for a second.")
        }
        .font(.callout)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in driver.refresh() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            driver.refresh()
        }
    }

    private var hint: String {
        switch driver.state {
        case .running where pen.isLive:
            return "the pen answers, settings apply at once"
        case .running:
            if let seconds = pen.secondsSinceEvent {
                return "no pen events for \(seconds) s"
            }
            return "move the pen over this window to check the pressure"
        case .stopped(let code) where code == 1:
            return "Input Monitoring and Accessibility are not granted"
        case .stopped:
            return "press “Restart the driver”"
        case .notInstalled:
            return "the agent is not registered — run the installer again"
        }
    }

    private var footer: some View {
        HStack {
            Button("Reset everything") { model.resetToDefaults() }
            Spacer()
            if let error = model.saveError {
                Text("not saved: \(error)").foregroundStyle(.red)
            } else if model.savedAt != nil {
                Text("saved — the driver picks it up")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var displayBinding: Binding<String> {
        Binding(
            get: { model.selectedDisplay?.configValue ?? "main" },
            set: { model.config.display = $0 })
    }
}
