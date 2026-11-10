import SwiftUI

/// Circular gauge with the value in the middle.
struct RingGauge: View {
    var title: String
    var fraction: Double?
    var color: Color
    var size: CGFloat = 56

    var body: some View {
        let line = max(4, size * 0.1)
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: line)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction ?? 0, 0), 1)))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                valueText
                Text(title)
                    .font(.system(size: max(8, size * 0.15), weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    private var valueText: Text {
        guard let f = fraction else {
            return Text(Fmt.dash).font(.system(size: size * 0.3, weight: .semibold, design: .rounded))
        }
        return Text("\(Int((f * 100).rounded()))")
            .font(.system(size: size * 0.3, weight: .semibold, design: .rounded))
            .monospacedDigit()
            + Text("%").font(.system(size: size * 0.16, weight: .semibold, design: .rounded))
    }
}

/// Horizontal bar made of colored segments (fractions of the whole).
struct SegmentedBar: View {
    var segments: [(fraction: Double, color: Color)]
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        Rectangle()
                            .fill(seg.color)
                            .frame(width: max(0, geo.size.width * CGFloat(min(max(seg.fraction, 0), 1))))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
    }
}

struct Bar: View {
    var fraction: Double?
    var color: Color
    var height: CGFloat = 6

    var body: some View {
        SegmentedBar(segments: [(fraction ?? 0, color)], height: height)
    }
}

/// One small vertical bar per logical CPU; efficiency cores drawn lighter.
struct CoreBars: View {
    var values: [Double]
    var kinds: String
    var color: Color = Theme.cpu

    var body: some View {
        let kindChars = Array(kinds)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: values.count > 16 ? 1 : 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    let efficiency = i < kindChars.count && kindChars[i] == "E"
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(efficiency ? color.opacity(0.55) : color)
                            .frame(height: max(1.5, geo.size.height * CGFloat(min(max(v, 0), 100) / 100)))
                    }
                }
            }
        }
    }
}

struct SignalBars: View {
    var rssi: Int?
    var color: Color
    var scale: CGFloat = 1

    var body: some View {
        let level = Signal.bars(rssi)
        HStack(alignment: .bottom, spacing: 1.5 * scale) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < level ? color : Color.primary.opacity(0.18))
                    .frame(width: 3 * scale, height: (4 + CGFloat(i) * 2.6) * scale)
            }
        }
    }
}

struct Sparkline: Shape {
    var values: [Double]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let step = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: rect.minX + CGFloat(i) * step,
                             y: rect.maxY - CGFloat(min(max(v, 0), 1)) * rect.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

struct SparklineFill: Shape {
    var values: [Double]

    func path(in rect: CGRect) -> Path {
        var p = Sparkline(values: values).path(in: rect)
        guard values.count > 1 else { return p }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct StatusDot: View {
    var kind: HostStatus.Kind
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(Theme.status(kind))
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Theme.status(kind).opacity(0.35), lineWidth: 3).scaleEffect(1.25))
    }
}

/// Small caps section title.
struct SectionLabel: View {
    var text: String
    var trailing: String? = nil
    var trailingColor: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(.system(size: 9, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(trailingColor)
            }
        }
    }
}

/// Rounded tile used by the large layout.
struct Tile<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) { content }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// Background shared by the widget, the menu card and the desktop panel.
struct CardBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.11, green: 0.12, blue: 0.15), Color(red: 0.07, green: 0.08, blue: 0.10)]
                : [Color(red: 0.98, green: 0.98, blue: 1.0), Color(red: 0.92, green: 0.93, blue: 0.96)],
            startPoint: .top, endPoint: .bottom)
    }
}
