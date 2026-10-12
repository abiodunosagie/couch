import SwiftUI

/// The round direction pad with its centre select button.
struct DPad: View {
    var finish: Finish
    var press: (RemoteKey) -> Void

    static let size: CGFloat = 196
    private static let centerSize: CGFloat = 76

    @State private var active: RemoteKey?
    @StateObject private var repeater = Repeater()

    var body: some View {
        ZStack {
            Circle()
                .fill(finish.face)
                .overlay(Circle().strokeBorder(finish.edge, lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)

            if let active, let angle = Self.angle(of: active) {
                Wedge(center: angle, inner: Self.centerSize / 2 + 4)
                    .fill(finish.edge.opacity(0.28))
            }

            Circle()
                .fill(active == .select ? finish.edge.opacity(0.35) : finish.face)
                .overlay(Circle().strokeBorder(finish.edge, lineWidth: 1))
                .frame(width: Self.centerSize, height: Self.centerSize)
                .scaleEffect(active == .select ? 0.95 : 1)
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard active == nil else { return }
                    let key = Self.key(at: value.startLocation)
                    active = key
                    if key.repeats {
                        repeater.start { press(key) }
                    } else {
                        press(key)
                    }
                }
                .onEnded { _ in release() }
        )
        // If the window hides mid-press the gesture may never end; drop the pressed state with the repeater.
        .onChange(of: repeater.running) { if !repeater.running && active?.repeats == true { active = nil } }
        .onDisappear(perform: release)
        .animation(.easeOut(duration: 0.08), value: active)
        .help("Arrow keys move, Return selects")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Direction pad")
        .accessibilityAction(named: "Up") { press(.up) }
        .accessibilityAction(named: "Down") { press(.down) }
        .accessibilityAction(named: "Left") { press(.left) }
        .accessibilityAction(named: "Right") { press(.right) }
        .accessibilityAction(named: "Select") { press(.select) }
    }

    private func release() {
        repeater.stop()
        active = nil
    }

    private static func key(at point: CGPoint) -> RemoteKey {
        let dx = point.x - size / 2
        let dy = point.y - size / 2
        if (dx * dx + dy * dy).squareRoot() <= centerSize / 2 { return .select }
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }

    /// Centre of the highlighted wedge in degrees, SwiftUI coordinates (0 is east, clockwise).
    private static func angle(of key: RemoteKey) -> Double? {
        switch key {
        case .right: 0
        case .down: 90
        case .left: 180
        case .up: 270
        default: nil
        }
    }
}

/// A 90 degree ring segment, used to show which side of the pad is pressed.
private struct Wedge: Shape {
    var center: Double
    var inner: CGFloat

    func path(in rect: CGRect) -> Path {
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 - 1
        var path = Path()
        path.addArc(center: mid, radius: outer, startAngle: .degrees(center - 45), endAngle: .degrees(center + 45), clockwise: false)
        path.addArc(center: mid, radius: inner, startAngle: .degrees(center + 45), endAngle: .degrees(center - 45), clockwise: true)
        path.closeSubpath()
        return path
    }
}
