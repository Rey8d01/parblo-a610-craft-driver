import ParbloA610Core
import SwiftUI

/// The pressure curve with a live test. You cannot pick it by eye without drawing,
/// so this view has both the curve and a place to draw a line with the pen at once.
struct PressureCurveView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pen: PenMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            curve
            sliders
            liveBar
        }
    }

    private var curve: some View {
        Canvas { context, size in
            let curve = model.curve
            let maxRaw = model.tablet.pressureMax

            // Grid.
            var grid = Path()
            for i in 1..<4 {
                let x = size.width * CGFloat(i) / 4
                let y = size.height * CGFloat(i) / 4
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)

            // Linear response, for comparison.
            var linear = Path()
            linear.move(to: CGPoint(x: 0, y: size.height))
            linear.addLine(to: CGPoint(x: size.width, y: 0))
            context.stroke(
                linear, with: .color(.secondary.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            // The curve itself.
            var path = Path()
            for step in 0...100 {
                let t = Double(step) / 100
                let out = curve.normalized(Int(t * Double(maxRaw)))
                let point = CGPoint(x: t * size.width, y: size.height * (1 - out))
                step == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 2)

            // Where the pen is now. The app sees pressure that is already
            // mapped, so we find the input with the inverse transform.
            if pen.pressure > 0 {
                let input = curve.inputFraction(forOutput: pen.pressure)
                let point = CGPoint(
                    x: input * size.width, y: size.height * (1 - pen.pressure))
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)),
                    with: .color(.red))
            }
        }
        .frame(height: 170)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var sliders: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            row(
                "Gamma", value: $model.config.pressure.gamma, range: 0.2...3,
                hint: "lower is softer, higher is harder")
            row(
                "Dead zone", value: $model.config.pressure.min, range: 0...0.4,
                hint: "a touch below this draws no line")
            row(
                "Saturation", value: $model.config.pressure.max, range: 0.5...1,
                hint: "above this the line is at full width")
        }
    }

    private func row(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, hint: String
    ) -> some View {
        GridRow {
            Text(title).gridColumnAlignment(.trailing)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
        }
        .help(hint)
    }

    private var liveBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Pressure now").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(pen.isLive ? String(format: "%.2f", pen.pressure) : "no pen events")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(pen.isLive ? .primary : .secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * pen.pressure)
                }
            }
            .frame(height: 8)
            Text("Move the pen over this window: the bar and the dot on the curve are live.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
