import SwiftUI

/// A place to draw a line with the pen and see the width follow the pressure.
/// You cannot set the curve blind with sliders — you need a test.
struct ScribbleView: View {
    @ObservedObject var pen: PenMonitor
    @State private var strokes: [[Sample]] = []
    @State private var current: [Sample] = []

    struct Sample {
        let point: CGPoint
        let width: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pen test").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    strokes = []
                    current = []
                }
                .buttonStyle(.link).font(.caption)
            }
            Canvas { context, _ in
                for stroke in strokes + [current] where stroke.count > 1 {
                    for i in 1..<stroke.count {
                        var segment = Path()
                        segment.move(to: stroke[i - 1].point)
                        segment.addLine(to: stroke[i].point)
                        context.stroke(
                            segment, with: .color(.primary),
                            style: StrokeStyle(
                                lineWidth: 1 + stroke[i].width * 22,
                                lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(height: 150)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4)))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // The point comes from the gesture, the width from the
                        // last tablet event. They arrive about 130 times per
                        // second, so the value is always fresh.
                        current.append(Sample(point: value.location, width: pen.pressure))
                    }
                    .onEnded { _ in
                        if current.count > 1 { strokes.append(current) }
                        current = []
                    }
            )
        }
    }
}
