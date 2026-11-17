import SwiftUI

/// Colores de la consola.
enum Skin {
    static let accent = Color(red: 0.96, green: 0.65, blue: 0.14)
    static let green = Color(red: 0.21, green: 0.88, blue: 0.42)
    static let blue = Color(red: 0.29, green: 0.56, blue: 1.0)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let white = Color(white: 0.95)
    static let label = Color(white: 0.78)
}

/// Perilla giratoria: arrastrar hacia arriba/abajo; doble toque para restablecer.
struct Knob: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var defaultValue: Float = 0
    var size: CGFloat = 60
    var enabled: Bool = true

    @State private var dragStart: Float?
    @State private var dragOrigin: CGPoint?

    private var position: CGFloat {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? CGFloat((value - range.lowerBound) / span) : 0
    }

    var body: some View {
        let stroke = StrokeStyle(lineWidth: 3, lineCap: .round)
        return ZStack {
            // Recorrido de 270°, desde las 7:30 hasta las 4:30.
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color(white: 0.22), style: stroke)
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * position)
                .stroke(Skin.accent, style: stroke)
                .rotationEffect(.degrees(135))
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.29), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().stroke(Color(white: 0.38), lineWidth: 1.2))
                .padding(7)
            Capsule()
                .fill(Skin.accent)
                .frame(width: max(2.5, size / 18), height: size * 0.2)
                .offset(y: -size * 0.24)
                .rotationEffect(.degrees(-135 + 270 * Double(position)))
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { g in
                    // Un gesto cancelado por el sistema no pasa por onEnded: se detecta el arrastre nuevo por su origen.
                    if dragStart == nil || dragOrigin != g.startLocation {
                        dragStart = value
                        dragOrigin = g.startLocation
                    }
                    let span = range.upperBound - range.lowerBound
                    let v = (dragStart ?? value) + Float(-g.translation.height / 160) * span
                    value = min(range.upperBound, max(range.lowerBound, v))
                }
                .onEnded { _ in dragStart = nil; dragOrigin = nil }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = defaultValue })
        .opacity(enabled ? 1 : 0.35)
        .allowsHitTesting(enabled)
    }
}

/// Perilla pequeña con su rótulo debajo.
struct LabeledKnob: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var defaultValue: Float = 0
    var enabled: Bool = true

    var body: some View {
        VStack(spacing: 2) {
            Knob(value: $value, range: range, defaultValue: defaultValue, size: 60, enabled: enabled)
            ConsoleLabel(title)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Fader vertical con escala 0–10.
struct Fader: View {
    @Binding var value: Float
    var defaultValue: Float = 0.8
    var enabled: Bool = true

    private let inset: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.height - 2 * inset
            let slotX = geo.size.width * 0.62
            let capY = inset + travel * CGFloat(1 - value)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(white: 0.03))
                    .frame(width: 6, height: travel + 8)
                    .position(x: slotX, y: geo.size.height / 2)
                ForEach(0..<11, id: \.self) { i in
                    let y = inset + travel * (1 - CGFloat(i) / 10)
                    Rectangle()
                        .fill(Color(white: 0.6))
                        .frame(width: i % 2 == 0 ? 9 : 5, height: 1)
                        .position(x: slotX - 12, y: y)
                    if i % 2 == 0 {
                        Text("\(i)")
                            .font(.system(size: 9))
                            .foregroundColor(Color(white: 0.6))
                            .position(x: slotX - 28, y: y)
                    }
                }
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Color(white: 0.35), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.44), lineWidth: 1))
                    .overlay(Rectangle().fill(Skin.accent).frame(height: 2).padding(.horizontal, 3))
                    .frame(width: 30, height: 28)
                    .position(x: slotX, y: capY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard travel > 0 else { return }
                        let t = 1 - (g.location.y - inset) / travel
                        value = Float(min(1, max(0, t)))
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = defaultValue })
        }
        .opacity(enabled ? 1 : 0.35)
        .allowsHitTesting(enabled)
    }
}

/// Medidor de nivel de LED segmentados. `db` en dBFS (−60 a 0).
struct LedMeter: View {
    let db: Float

    private let segments = 12
    private let floorDb: Float = -48

    var body: some View {
        VStack(spacing: 3) {
            ForEach((0..<segments).reversed(), id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color(for: i))
            }
        }
    }

    private func color(for index: Int) -> Color {
        // El segmento superior equivale a 0 dBFS.
        let threshold = floorDb - floorDb * Float(index) / Float(segments - 1)
        guard db >= threshold else { return Color(white: 0.16) }
        if index >= segments - 2 { return Skin.red }
        if index >= segments - 4 { return Color(red: 0.96, green: 0.77, blue: 0.14) }
        return Skin.green
    }
}

struct LabeledMeter: View {
    let title: String
    let db: Float

    var body: some View {
        VStack(spacing: 2) {
            LedMeter(db: db).frame(width: 18, height: 150)
            ConsoleLabel(title)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ConsoleLabel: View {
    let text: String
    var size: CGFloat = 10

    init(_ text: String, size: CGFloat = 10) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(Skin.label)
            .lineLimit(1)
    }
}

/// Botón de goma retroiluminado: tenue apagado, brillante encendido.
struct CapButton: View {
    let title: String
    let color: Color
    var isOn: Bool = false
    var enabled: Bool = true
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundColor(Color(white: 0.06))
                .frame(width: 76, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(color)
                        .opacity(enabled ? (isOn ? 1 : 0.38) : 0.15)
                )
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
