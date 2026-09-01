import ParbloA610Core
import SwiftUI

/// Active area: a rectangle you drag with the mouse, plus a live pen dot.
/// These two things are the reason the interface was made — picking the area
/// blind, with numbers in a file, is hard.
struct AreaMapperView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pen: PenMonitor

    @State private var dragStart: Config.Area?

    private let handle: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let size = model.mapper.orientedSize
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
            let board = CGSize(width: size.width * scale, height: size.height * scale)
            let origin = CGPoint(
                x: (geometry.size.width - board.width) / 2,
                y: (geometry.size.height - board.height) / 2)

            ZStack(alignment: .topLeading) {
                // The whole tablet.
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary))
                    .frame(width: board.width, height: board.height)
                    .offset(x: origin.x, y: origin.y)

                // What really reaches the screen, after the aspect ratio fit.
                let mapped = model.mapper.mappedArea
                Rectangle()
                    .strokeBorder(
                        Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .frame(width: mapped.width * scale, height: mapped.height * scale)
                    .offset(x: origin.x + mapped.minX * scale, y: origin.y + mapped.minY * scale)

                // The area that is set — this is the one you drag.
                let area = rect(for: model.config.activeArea, in: size)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.15))
                    .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .frame(width: area.width * scale, height: area.height * scale)
                    .offset(x: origin.x + area.minX * scale, y: origin.y + area.minY * scale)
                    .gesture(moveGesture(scale: scale, size: size))

                // Corner handle for resizing.
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor)
                    .frame(width: handle, height: handle)
                    .offset(
                        x: origin.x + area.maxX * scale - handle / 2,
                        y: origin.y + area.maxY * scale - handle / 2
                    )
                    .gesture(resizeGesture(scale: scale, size: size))

                // Live pen dot — you see at once how far the hand reaches.
                if let tabletPoint = pen.tabletPoint {
                    let p = model.mapper.orientedPoint(
                        x: Int(tabletPoint.x), y: Int(tabletPoint.y))
                    Circle()
                        .fill(pen.isDrawing ? Color.red : Color.orange)
                        .frame(width: 9, height: 9)
                        .offset(x: origin.x + p.x * scale - 4.5, y: origin.y + p.y * scale - 4.5)
                        .animation(.linear(duration: 0.05), value: tabletPoint)
                }
            }
        }
        .frame(height: 200)
    }

    private func rect(for area: Config.Area, in size: CGSize) -> CGRect {
        CGRect(
            x: area.x * size.width, y: area.y * size.height,
            width: area.width * size.width, height: area.height * size.height)
    }

    private func moveGesture(scale: CGFloat, size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? model.config.activeArea
                if dragStart == nil { dragStart = start }
                var area = start
                area.x = clamp(
                    start.x + value.translation.width / scale / size.width, max: 1 - start.width)
                area.y = clamp(
                    start.y + value.translation.height / scale / size.height, max: 1 - start.height)
                model.config.activeArea = area
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(scale: CGFloat, size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? model.config.activeArea
                if dragStart == nil { dragStart = start }
                var area = start
                area.width = clamp(
                    start.width + value.translation.width / scale / size.width,
                    min: 0.1, max: 1 - start.x)
                area.height = clamp(
                    start.height + value.translation.height / scale / size.height,
                    min: 0.1, max: 1 - start.y)
                model.config.activeArea = area
            }
            .onEnded { _ in dragStart = nil }
    }

    private func clamp(_ value: Double, min lower: Double = 0, max upper: Double) -> Double {
        Swift.min(Swift.max(value, lower), Swift.max(upper, lower))
    }
}
