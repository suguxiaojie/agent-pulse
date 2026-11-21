import SwiftUI

private struct IslandFullWidthProviderSwitchKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var islandFullWidthProviderSwitch: Bool {
        get { self[IslandFullWidthProviderSwitchKey.self] }
        set { self[IslandFullWidthProviderSwitchKey.self] = newValue }
    }
}

private protocol IslandUsageFormatting {}
private extension IslandUsageFormatting {
    var secondary: Color { FloatingSurfaceTheme.secondary() }
    func tokens(_ value: Int?) -> String {
        value.map { CountFormatter.display(Int64($0)) } ?? "—"
    }
    func money(_ value: Double?) -> String { value.map { $0.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US"))) } ?? "—" }
    func heading(_ value: String) -> some View {
        Text(value).font(.system(size: 10, weight: .medium)).foregroundStyle(secondary)
    }
    func surface<Content: View>(verticalPadding: CGFloat = 14, @ViewBuilder _ content: () -> Content) -> some View {
        content().padding(.horizontal, 14).padding(.vertical, verticalPadding).frame(maxWidth: .infinity, alignment: .leading)
            .islandGlass(RoundedRectangle(cornerRadius: 14, style: .continuous),
                         tint: Color(white: 0.025).opacity(0.90), solidTint: Color(white: 0.025))
    }
}

enum OfficialProviderSVGPath {
    static let codex = "M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z"

    static let claude = "M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z"

    static let grok = "M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272.98 2.369.542 5.215-1.41 7.169-1.951 1.954-4.667 2.382-7.149 1.406l-2.711 1.257c3.889 2.661 8.611 2.003 11.562-.953 2.341-2.344 3.066-5.539 2.388-8.42l.006.007c-.983-4.232.242-5.924 2.75-9.383.06-.082.12-.164.179-.248l-3.301 3.305v-.01L9.267 15.292M7.623 16.723c-2.792-2.67-2.31-6.801.071-9.184 1.761-1.763 4.647-2.483 7.166-1.425l2.705-1.25a7.808 7.808 0 00-1.829-1A8.975 8.975 0 005.984 5.83c-2.533 2.536-3.33 6.436-1.962 9.764 1.022 2.487-.653 4.246-2.34 6.022-.599.63-1.199 1.259-1.682 1.925l7.62-6.815"

    static let antigravity = "M21.751 22.607c1.34 1.005 3.35.335 1.508-1.508C17.73 15.74 18.904 1 12.037 1 5.17 1 6.342 15.74.815 21.1c-2.01 2.009.167 2.511 1.507 1.506 5.192-3.517 4.857-9.714 9.715-9.714 4.857 0 4.522 6.197 9.714 9.715z"

    static func parseNormalized(_ d: String, insetFraction: CGFloat = 0.03) -> CGPath {
        let raw = parseRaw(d)
        let bounds = raw.boundingBox
        guard bounds.width > 0, bounds.height > 0 else { return raw }
        let usable = max(0.1, 1.0 - insetFraction * 2)
        let scale = usable / max(bounds.width, bounds.height)
        let tx = (1.0 - bounds.width * scale) / 2.0 - bounds.minX * scale
        let ty = (1.0 - bounds.height * scale) / 2.0 - bounds.minY * scale
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
        return raw.copy(using: &transform) ?? raw
    }

    static func fit(_ normalized: CGPath, in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        guard side > 0 else { return Path() }
        let ox = rect.midX - side / 2
        let oy = rect.midY - side / 2
        var transform = CGAffineTransform(a: side, b: 0, c: 0, d: side, tx: ox, ty: oy)
        guard let scaled = normalized.copy(using: &transform) else { return Path() }
        return Path(scaled)
    }

    private static func parseRaw(_ d: String) -> CGPath {
        let path = CGMutablePath()
        let chars = Array(d.unicodeScalars)
        var i = 0
        let count = chars.count

        func skipSeparators() {
            while i < count {
                let c = chars[i]
                if c == " " || c == "," || c == "\n" || c == "\r" || c == "\t" { i += 1 } else { break }
            }
        }

        func isCommand(_ c: UnicodeScalar) -> Bool {
            switch c {
            case "M", "m", "L", "l", "H", "h", "V", "v", "C", "c", "S", "s", "Q", "q", "A", "a", "Z", "z":
                return true
            default:
                return false
            }
        }

        func readNumber() -> CGFloat? {
            skipSeparators()
            guard i < count, !isCommand(chars[i]) else { return nil }
            var str = ""
            if chars[i] == "+" || chars[i] == "-" {
                str.unicodeScalars.append(chars[i])
                i += 1
            }
            var hasDot = false
            var hasDigit = false
            while i < count {
                let c = chars[i]
                if c >= "0" && c <= "9" {
                    hasDigit = true
                    str.unicodeScalars.append(c)
                    i += 1
                } else if c == "." && !hasDot {
                    hasDot = true
                    str.unicodeScalars.append(c)
                    i += 1
                } else if (c == "e" || c == "E") && hasDigit {
                    str.unicodeScalars.append(c)
                    i += 1
                    if i < count && (chars[i] == "+" || chars[i] == "-") {
                        str.unicodeScalars.append(chars[i])
                        i += 1
                    }
                } else {
                    break
                }
            }
            guard hasDigit, let val = Double(str) else { return nil }
            return CGFloat(val)
        }

        func readFlag() -> Bool? {
            skipSeparators()
            guard i < count else { return nil }
            let c = chars[i]
            if c == "0" { i += 1; return false }
            if c == "1" { i += 1; return true }
            return nil
        }

        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var cmd: UnicodeScalar = "M"

        while i < count {
            skipSeparators()
            guard i < count else { break }
            if isCommand(chars[i]) {
                cmd = chars[i]
                i += 1
            }
            switch cmd {
            case "M", "m":
                let rel = (cmd == "m")
                guard let x = readNumber(), let y = readNumber() else { break }
                current = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                start = current
                path.move(to: current)
                lastControl = nil
                cmd = rel ? "l" : "L"
            case "L", "l":
                let rel = (cmd == "l")
                guard let x = readNumber(), let y = readNumber() else { break }
                current = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addLine(to: current)
                lastControl = nil
            case "H", "h":
                let rel = (cmd == "h")
                guard let x = readNumber() else { break }
                current = CGPoint(x: rel ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case "V", "v":
                let rel = (cmd == "v")
                guard let y = readNumber() else { break }
                current = CGPoint(x: current.x, y: rel ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
            case "C", "c":
                let rel = (cmd == "c")
                guard let x1 = readNumber(), let y1 = readNumber(),
                      let x2 = readNumber(), let y2 = readNumber(),
                      let x = readNumber(), let y = readNumber() else { break }
                let c1 = rel ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                let c2 = rel ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                let end = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case "S", "s":
                let rel = (cmd == "s")
                guard let x2 = readNumber(), let y2 = readNumber(),
                      let x = readNumber(), let y = readNumber() else { break }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = rel ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                let end = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case "Q", "q":
                let rel = (cmd == "q")
                guard let x1 = readNumber(), let y1 = readNumber(),
                      let x = readNumber(), let y = readNumber() else { break }
                let c1 = rel ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                let end = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addQuadCurve(to: end, control: c1)
                lastControl = c1
                current = end
            case "A", "a":
                let rel = (cmd == "a")
                guard let rx = readNumber(), let ry = readNumber(),
                      let rot = readNumber(),
                      let largeArc = readFlag(),
                      let sweep = readFlag(),
                      let x = readNumber(), let y = readNumber() else { break }
                let end = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                addSVGArc(to: path, from: current, end: end, rx: rx, ry: ry, xAxisRotationDegrees: rot, largeArc: largeArc, sweep: sweep)
                current = end
                lastControl = nil
            case "Z", "z":
                path.closeSubpath()
                current = start
                lastControl = nil
            default:
                i += 1
            }
        }
        return path
    }

    private static func addSVGArc(
        to path: CGMutablePath,
        from p1: CGPoint,
        end p2: CGPoint,
        rx rawRx: CGFloat,
        ry rawRy: CGFloat,
        xAxisRotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        if p1 == p2 { return }
        var rx = abs(rawRx)
        var ry = abs(rawRy)
        if rx == 0 || ry == 0 {
            path.addLine(to: p2)
            return
        }
        let phi = xAxisRotationDegrees * .pi / 180.0
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (p1.x - p2.x) / 2.0
        let dy2 = (p1.y - p2.y) / 2.0
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let root = sqrt(lambda)
            rx *= root
            ry *= root
        }

        let rx2 = rx * rx, ry2 = ry * ry
        let x1p2 = x1p * x1p, y1p2 = y1p * y1p
        let num = max(0, rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2)
        let den = rx2 * y1p2 + ry2 * x1p2
        let sign: CGFloat = (largeArc == sweep) ? -1 : 1
        let coef = sign * (den > 0 ? sqrt(num / den) : 0)
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * (-ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2.0
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2.0

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            guard len > 0 else { return 0 }
            let clamped = min(1, max(-1, dot / len))
            let a = acos(clamped)
            return (ux * vy - uy * vx) < 0 ? -a : a
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        else if sweep && dTheta < 0 { dTheta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2.0))))
        let delta = dTheta / CGFloat(segments)
        let alpha = (4.0 / 3.0) * tan(delta / 4.0)

        for seg in 0..<segments {
            let t1 = theta1 + CGFloat(seg) * delta
            let t2 = t1 + delta
            let cos1 = cos(t1), sin1 = sin(t1)
            let cos2 = cos(t2), sin2 = sin(t2)

            let e1x = cos1 - alpha * sin1
            let e1y = sin1 + alpha * cos1
            let e2x = cos2 + alpha * sin2
            let e2y = sin2 - alpha * cos2

            func mapPoint(_ ex: CGFloat, _ ey: CGFloat) -> CGPoint {
                let sx = rx * ex, sy = ry * ey
                return CGPoint(
                    x: cosPhi * sx - sinPhi * sy + cx,
                    y: sinPhi * sx + cosPhi * sy + cy
                )
            }
            path.addCurve(to: mapPoint(cos2, sin2), control1: mapPoint(e1x, e1y), control2: mapPoint(e2x, e2y))
        }
    }
}

struct CodexBrandMarkShape: Shape {
    private static let unit = OfficialProviderSVGPath.parseNormalized(OfficialProviderSVGPath.codex)
    func path(in rect: CGRect) -> Path { OfficialProviderSVGPath.fit(Self.unit, in: rect) }
}

struct ClaudeMarkShape: Shape {
    private static let unit = OfficialProviderSVGPath.parseNormalized(OfficialProviderSVGPath.claude)
    func path(in rect: CGRect) -> Path { OfficialProviderSVGPath.fit(Self.unit, in: rect) }
}

struct GrokBrandMarkShape: Shape {
    private static let unit = OfficialProviderSVGPath.parseNormalized(OfficialProviderSVGPath.grok)
    func path(in rect: CGRect) -> Path { OfficialProviderSVGPath.fit(Self.unit, in: rect) }
}

struct AntigravityMarkShape: Shape {
    private static let unit = OfficialProviderSVGPath.parseNormalized(OfficialProviderSVGPath.antigravity)
    func path(in rect: CGRect) -> Path { OfficialProviderSVGPath.fit(Self.unit, in: rect) }
}

struct ProviderBrandIcon: View {
    enum Brand: Equatable {
        case codex, claude, grok, antigravity
    }

    let brand: Brand
    var size: CGFloat = 13
    var active: Bool = true
    var disabled: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch brand {
            case .codex:
                CodexBrandMarkShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.694, green: 0.655, blue: 1.0),
                                Color(red: 0.478, green: 0.616, blue: 1.0),
                                Color(red: 0.345, green: 0.400, blue: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        style: FillStyle(eoFill: true)
                    )
            case .claude:
                ClaudeMarkShape()
                    .fill(Color(red: 0.851, green: 0.467, blue: 0.341))
            case .grok:
                GrokBrandMarkShape()
                    .fill(
                        colorScheme == .dark ? Color(white: 0.96) : Color(white: 0.14),
                        style: FillStyle(eoFill: true)
                    )
            case .antigravity:
                ZStack {
                    Color(red: 0.192, green: 0.525, blue: 1.0)
                    RadialGradient(
                        colors: [Color(red: 0.0, green: 0.725, blue: 0.361), .clear],
                        center: UnitPoint(x: 0.18, y: 0.36),
                        startRadius: 0,
                        endRadius: size * 0.54
                    )
                    RadialGradient(
                        colors: [Color(red: 0.988, green: 0.255, blue: 0.239), .clear],
                        center: UnitPoint(x: 0.80, y: 0.28),
                        startRadius: 0,
                        endRadius: size * 0.54
                    )
                    RadialGradient(
                        colors: [Color(red: 1.0, green: 0.855, blue: 0.180), .clear],
                        center: UnitPoint(x: 0.48, y: 0.08),
                        startRadius: 0,
                        endRadius: size * 0.46
                    )
                }
                .mask(AntigravityMarkShape())
            }
        }
        .frame(width: size, height: size)
        .opacity(active ? 1.0 : 0.72)
        .saturation(disabled ? 0 : 1)
        .accessibilityHidden(true)
    }
}

struct IslandUsageProviderSwitch: View {
    @ObservedObject var model: ActivityIslandViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandFullWidthProviderSwitch) private var fullWidth
    @Namespace private var selection

    private var visibleProviders: [IslandUsageProvider] {
        IslandUsageProvider.allCases.filter {
            ($0 != .grok || model.grokEnabled) && ($0 != .antigravity || model.antigravityEnabled)
        }
    }

    private var controlWidth: CGFloat {
        switch visibleProviders.count {
        case ..<3: return 240
        case 3: return 330
        default: return 374
        }
    }

    private func switchLabel(for provider: IslandUsageProvider, compact: Bool) -> String {
        guard compact else { return provider.rawValue }
        switch provider {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .antigravity: return "Antigravity"
        }
    }

    var body: some View {
        let providers = visibleProviders
        let compact = providers.count >= 4
        let pillHeight: CGFloat = fullWidth ? 24 : 28
        let trackHeight: CGFloat = fullWidth ? 30 : 28

        let row = HStack(spacing: fullWidth ? 4 : 0) {
            ForEach(providers, id: \.self) { provider in
                let disabled = (provider == .claude && !model.claudeEnabled)
                    || (provider == .grok && !model.grokEnabled)
                    || (provider == .antigravity && !model.antigravityEnabled)
                    || model.resetBusy || model.resetConfirmationPresented
                Button {
                    withAnimation(reduceMotion ? nil : FloatingSurfaceTheme.selectionMotion) { model.selectUsageProvider(provider) }
                } label: {
                    HStack(spacing: compact ? 4.5 : 5.5) {
                        let brand: ProviderBrandIcon.Brand = {
                            switch provider {
                            case .codex: return .codex
                            case .claude: return .claude
                            case .grok: return .grok
                            case .antigravity: return .antigravity
                            }
                        }()
                        ProviderBrandIcon(
                            brand: brand,
                            size: 13,
                            active: model.usageProvider == provider,
                            disabled: disabled
                        )
                        Text(switchLabel(for: provider, compact: compact))
                            .font(FloatingSurfaceTypography.control)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, fullWidth ? 10 : 0)
                    .frame(maxWidth: .infinity)
                    .frame(height: pillHeight)
                    .foregroundStyle(model.usageProvider == provider ? FloatingSurfaceTheme.primary() : FloatingSurfaceTheme.secondary())
                    .background {
                        if model.usageProvider == provider {
                            Capsule()
                                .fill(FloatingSurfaceTheme.accent().opacity(fullWidth ? 0.24 : 0.20))
                                .overlay {
                                    if fullWidth {
                                        Capsule().strokeBorder(FloatingSurfaceTheme.accent().opacity(0.42), lineWidth: 0.5)
                                    }
                                }
                                .matchedGeometryEffect(id: "provider-selection", in: selection)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(FloatingSurfaceButtonStyle())
                .disabled(disabled)
                .accessibilityLabel(provider.rawValue)
                .accessibilityValue(model.usageProvider == provider ? "已选择" : "未选择")
                .accessibilityAddTraits(model.usageProvider == provider ? .isSelected : [])
                .help(provider == .claude && !model.claudeEnabled ? "请先在监控中心启用 Claude Code" : "查看 " + provider.rawValue + " 用量")
            }
        }
        .padding(fullWidth ? 3 : 0)

        Group {
            if fullWidth {
                row.frame(maxWidth: .infinity).frame(height: trackHeight)
            } else {
                row.frame(width: controlWidth, height: trackHeight)
            }
        }
        .islandGlass(Capsule(), tint: .black.opacity(0.28))
        .animation(reduceMotion ? nil : FloatingSurfaceTheme.selectionMotion, value: model.usageProvider)
        .accessibilityElement(children: .contain).accessibilityLabel("用量来源")
    }
}

private struct IslandConcentricQuotaRing: View {
    let primaryPercent: Int?
    let secondaryPercent: Int?
    let stale: Bool

    private func clamped(_ percent: Int?) -> Double {
        guard let percent else { return 0 }
        return min(1, max(0, Double(percent) / 100.0))
    }

    var body: some View {
        let outer = clamped(primaryPercent)
        let inner = secondaryPercent.map { clamped($0) }
        let outerColor = stale ? FloatingSurfaceTheme.secondary() : FloatingSurfaceTheme.quotaHealth(primaryPercent)
        let innerColor = stale ? FloatingSurfaceTheme.secondary() : FloatingSurfaceTheme.quotaHealth(secondaryPercent ?? primaryPercent)

        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 5.2)
                .frame(width: 50, height: 50)
            Circle()
                .trim(from: 0, to: primaryPercent == 0 ? 0.03 : outer)
                .stroke(outerColor, style: StrokeStyle(lineWidth: 5.2, lineCap: .round))
                .frame(width: 50, height: 50)
                .rotationEffect(.degrees(-90))

            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 4.2)
                .frame(width: 34, height: 34)
            if let inner {
                Circle()
                    .trim(from: 0, to: secondaryPercent == 0 ? 0.03 : inner)
                    .stroke(innerColor, style: StrokeStyle(lineWidth: 4.2, lineCap: .round))
                    .frame(width: 34, height: 34)
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .trim(from: 0, to: primaryPercent == nil ? 0 : max(0.08, outer))
                    .stroke(outerColor.opacity(0.38), style: StrokeStyle(lineWidth: 4.2, lineCap: .round))
                    .frame(width: 34, height: 34)
                    .rotationEffect(.degrees(-90))
            }

            Circle()
                .fill(outerColor)
                .frame(width: 5.5, height: 5.5)
        }
        .frame(width: 58, height: 58)
        .opacity(stale ? 0.58 : 1)
        .accessibilityHidden(true)
    }
}

struct IslandUsageSourceCard: View, IslandUsageFormatting {
    static let unifiedHeight: CGFloat = 132

    let source: IslandUsagePresentation.Source
    let playbackVisible: Bool
    let flightActive: Bool
    let onReset: () -> Void

    var body: some View {
        switch source {
        case .codex(let planName, let balance, let resetCount):
            codexAccountCard(planName: planName, balance: balance, resetCount: resetCount)
        case .claude:
            structuredSourceCard(
                leftHeading: "当前来源",
                leftTitle: "Claude Code",
                rightHeading: "状态栏",
                rightValue: "官方采集",
                bottomLeft: "额度 · CLI 状态栏同步",
                bottomRight: "本机全部会话",
                helpText: "历史为本机全部会话，含子 Agent；账号归属未推断。"
            )
        case .grok(let plan, let shared, let prepaid):
            structuredSourceCard(
                leftHeading: "Grok 官方额度",
                leftTitle: plan,
                rightHeading: "预付余额",
                rightValue: prepaid.map { String(format: "$%.2f", Double($0) / 100) } ?? "—",
                bottomLeft: shared == true ? "统一共享额度池" : "订阅额度池",
                bottomRight: "本机记录",
                helpText: "Grok 官方计费额度池与预付余额分开统计；历史为本机记录。"
            )
        case .antigravity(let plan, let credits, let useG1Credits):
            structuredSourceCard(
                leftHeading: "Antigravity",
                leftTitle: plan,
                rightHeading: "AI Credits",
                rightValue: credits.map { CountFormatter.display(Int64($0)) } ?? "—",
                bottomLeft: useG1Credits == true ? "超额自动用 Credits" : "CLI 状态栏同步",
                bottomRight: "本机三端记录",
                helpText: "覆盖本机 Antigravity 2.0、IDE 与 CLI 记录；AI Credits 与订阅配额分开统计。"
            )
        }
    }

    private func structuredSourceCard(
        leftHeading: String,
        leftTitle: String,
        rightHeading: String,
        rightValue: String,
        bottomLeft: String,
        bottomRight: String,
        helpText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    heading(leftHeading)
                    Text(leftTitle)
                        .font(.system(size: 15.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    heading(rightHeading)
                    Text(rightValue)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            Spacer(minLength: 4)
            Divider().overlay(FloatingSurfaceTheme.separator())
                .padding(.bottom, 8)
            HStack(spacing: 6) {
                Text(bottomLeft)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(bottomRight)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(FloatingSurfaceTheme.primary().opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 9)
            .frame(height: 36)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.unifiedHeight)
        .islandGlass(RoundedRectangle(cornerRadius: 14, style: .continuous),
                     tint: Color(white: 0.025).opacity(0.90), solidTint: Color(white: 0.025))
        .help(helpText)
    }

    private func codexAccountCard(planName: String, balance: String?, resetCount: Int?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    heading("当前账户")
                    Text(planName)
                        .font(.system(size: 15.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    heading("积分余额")
                    Text(CreditBalanceFormatter.summary(balance))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .help("完整余额：" + CreditBalanceFormatter.string(balance))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("积分余额")
                .accessibilityValue(CreditBalanceFormatter.string(balance))
            }
            Spacer(minLength: 4)
            Divider().overlay(FloatingSurfaceTheme.separator())
                .padding(.bottom, 7)
            Button { onReset() } label: {
                HStack(spacing: 8) {
                    DashboardResetTicket(playbackEnabled: playbackVisible && !flightActive)
                        .opacity(flightActive ? 0 : 1)
                        .anchorPreference(key: DashboardResetTicketAnchors.self, value: .bounds) { [.usage: $0] }
                        .accessibilityHidden(true)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        heading("官方额度重置")
                        Text(resetCount.map { $0 > 0 ? "\($0) 次可用 ›" : "\($0) 次" } ?? "—")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle((resetCount ?? 0) > 0 ? FloatingSurfaceTheme.accent() : FloatingSurfaceTheme.primary())
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(FloatingSurfaceButtonStyle())
            .help("在灵动岛内查看重置次数与有效期，点击票卡不会消耗次数")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.unifiedHeight)
        .islandGlass(RoundedRectangle(cornerRadius: 14, style: .continuous),
                     tint: Color(white: 0.025).opacity(0.90), solidTint: Color(white: 0.025))
    }
}

struct IslandUsageMetricStrip: View, IslandUsageFormatting {
    @AppStorage(CountStyle.preferenceKey) private var countStyle = CountStyle.chinese.rawValue
    let metrics: [IslandUsagePresentation.Metric]

    private func defaultScopeTag(for index: Int) -> String {
        switch index {
        case 0: return "今日"
        case 1: return "近 30 日"
        default: return "全部历史"
        }
    }

    var body: some View {
        let _ = countStyle
        HStack(spacing: 8) {
            ForEach(metrics.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        heading(metrics[index].title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Spacer(minLength: 2)
                        Text(metrics[index].dateTag ?? defaultScopeTag(for: index))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(secondary.opacity(0.8))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    Text(tokens(metrics[index].tokens))
                        .foregroundStyle(FloatingSurfaceTheme.usageData())
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 64)
                .islandGlass(RoundedRectangle(cornerRadius: 14, style: .continuous),
                             tint: Color(white: 0.025).opacity(0.90), solidTint: Color(white: 0.025))
            }
        }
    }
}

struct IslandUsageQuotaRow: View, IslandUsageFormatting {
    let quotas: [IslandUsagePresentation.Quota]
    let now: Date
    var statusHint: String? = nil
    var resetCount: Int? = nil

    private var primaryQuota: IslandUsagePresentation.Quota {
        quotas.min { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) }
            ?? quotas.first
            ?? .init(title: "额度剩余", remainingPercent: nil, usedPercent: nil, resetsAt: nil, freshness: .unavailable)
    }

    private var secondaryQuota: IslandUsagePresentation.Quota? {
        let primary = primaryQuota
        return quotas.first { $0 != primary }
    }

    private func statusBadge(for quota: IslandUsagePresentation.Quota) -> (text: String, color: Color) {
        guard let rem = quota.remainingPercent else {
            return ("等待同步", secondary)
        }
        if rem <= 0 { return ("额度已用完", FloatingSurfaceTheme.danger) }
        if rem < 20 { return ("额度告急", FloatingSurfaceTheme.danger) }
        if rem < 50 { return ("余量偏紧", .orange) }
        return ("余量充裕", FloatingSurfaceTheme.quotaHealth(rem))
    }

    var body: some View {
        let primary = primaryQuota
        let secondaryWindow = secondaryQuota
        let badge = statusBadge(for: primary)
        let healthColor = primary.freshness.isStale
            ? secondary
            : FloatingSurfaceTheme.quotaHealth(primary.remainingPercent)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    heading(primary.title)
                        .lineLimit(1)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(primary.remainingPercent.map(String.init) ?? "—")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .fixedSize()
                        if primary.remainingPercent != nil {
                            Text("%")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(secondary)
                        }
                        Text(badge.text)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(badge.color)
                            .padding(.leading, 4)
                            .lineLimit(1)
                    }

                    Text(subtitleText(for: primary))
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 6)

                IslandConcentricQuotaRing(
                    primaryPercent: primary.remainingPercent,
                    secondaryPercent: secondaryWindow?.remainingPercent,
                    stale: primary.freshness.isStale
                )
            }

            Spacer(minLength: 4)

            Divider().overlay(FloatingSurfaceTheme.separator())
                .padding(.bottom, 7)

            HStack(spacing: 6) {
                if let sec = secondaryWindow {
                    Text("\(sec.title) \(sec.remainingPercent.map { "\($0)%" } ?? "—")")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Text(sec.freshness.observationLabel(now: now) ?? reset(sec.resetsAt))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    Text(statusHint ?? "副窗口 · 无额外短周期限制")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Spacer(minLength: 4)
                    if (resetCount ?? 0) > 0 && (primary.remainingPercent ?? 100) <= 20 {
                        Text("可点击右侧票卡重置 ›")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(FloatingSurfaceTheme.accent())
                            .lineLimit(1)
                    } else {
                        Text(primary.freshness.isStale ? "上次观测快照" : "官方实时窗口")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: IslandUsageSourceCard.unifiedHeight)
        .islandGlass(
            RoundedRectangle(cornerRadius: 14, style: .continuous),
            tint: Color(white: 0.025).opacity(0.90),
            solidTint: Color(white: 0.025)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [healthColor.opacity(primary.remainingPercent == nil ? 0.02 : 0.10), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(healthColor.opacity(primary.remainingPercent == nil ? 0.08 : 0.24), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .opacity(primary.freshness.isStale ? 0.68 : 1)
        .help(statusHint ?? reset(primary.resetsAt))
        .accessibilityElement(children: .combine)
        .accessibilityValue(primary.freshness.isStale ? "上次观测，非当前" : "")
    }

    private func subtitleText(for quota: IslandUsagePresentation.Quota) -> String {
        let resetPart = quota.freshness.observationLabel(now: now) ?? reset(quota.resetsAt)
        if let used = quota.usedPercent {
            return "\(resetPart) · 已使用 \(used)%"
        }
        return resetPart
    }

    private func reset(_ date: Date?) -> String {
        guard let date else { return "重置时间 —" }
        let hours = max(0, Int(ceil(date.timeIntervalSince(now) / 3600)))
        return ChineseDisplayText.spacing(hours >= 24 ? "\(hours / 24)天\(hours % 24)小时后重置" : "\(hours)小时后重置")
    }
}

struct IslandUsageTrendCard: View, IslandUsageFormatting {
    @AppStorage(CountStyle.preferenceKey) private var countStyle = CountStyle.chinese.rawValue
    let presentation: IslandUsagePresentation
    let width: CGFloat
    let now: Date
    @Binding var mode: IslandDashboardHeatmap.Mode
    @Binding var selectedCost: Date?
    @Binding var selectedActivity: String?
    @Binding var hoveredCost: Date?
    @Binding var hoveredActivity: Int?
    private var chart: IslandUsagePresentation.Cost { presentation.cost }
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()
    private static let abbreviatedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        surface(verticalPadding: 11) {
            VStack(spacing: 10) {
                costCard.zIndex(hoveredCost == nil ? 0 : 1)
                Divider().overlay(FloatingSurfaceTheme.separator())
                IslandUsageHeatmapCard(
                    activity: presentation.activity,
                    lifetimeTokens: presentation.lifetimeTokens,
                    activityHelp: presentation.activityHelp,
                    width: width,
                    endingAt: max(now, presentation.activity.last?.date ?? now),
                    generation: generation,
                    countStyle: countStyle,
                    mode: $mode,
                    selectedActivity: $selectedActivity,
                    hoveredActivity: $hoveredActivity
                )
                .zIndex(hoveredActivity == nil ? 0 : 1)
            }
        }
        .onChange(of: width) { _ in hoveredCost = nil; hoveredActivity = nil }
        .onDisappear { hoveredCost = nil; hoveredActivity = nil }
    }

    private var contentWidth: CGFloat { width - 56 }
    private var barsAreaWidth: CGFloat { max(120, contentWidth - 28 - 156 - 16) }
    private var barGap: CGFloat { 3 }
    private var barCellWidth: CGFloat {
        let count = max(1, chart.days.count)
        return max(3.5, (barsAreaWidth - CGFloat(max(0, count - 1)) * barGap) / CGFloat(count))
    }
    private var generation: String { "\(presentation.provider.rawValue)-\(presentation.supportsReset)-\(chart.days.last?.date.timeIntervalSinceReferenceDate ?? 0)" }

    private func costDayIndex(at point: CGPoint, count: Int, cellWidth: CGFloat, height: CGFloat) -> Int? {
        guard count > 0, point.x >= 0, point.y >= 0, point.y <= height else { return nil }
        let stride = cellWidth + barGap
        let index = Int(point.x / stride)
        guard (0..<count).contains(index), point.x - CGFloat(index) * stride <= cellWidth + 1.5 else { return nil }
        return index
    }

    private var costCard: some View {
        let chart = self.chart
        let selected = chart.days.first { $0.date == selectedCost }
        let focusLabel = selected?.date.formatted(.dateTime.month().day()) ?? chart.latestDateTag ?? "最近一天"
        let focusMoney = money(selected != nil ? selected?.cost : chart.latest?.cost)

        return HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                heading(chart.title + " · 30天")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text((chart.totalIsLowerBound && chart.total != nil ? "≥" : "") + money(chart.total))
                    .foregroundStyle(FloatingSurfaceTheme.costData())
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                HStack(spacing: 4) {
                    Text(focusLabel)
                        .foregroundStyle(secondary)
                    Text(focusMoney)
                        .fontWeight(.semibold)
                        .foregroundStyle(FloatingSurfaceTheme.primary())
                    Text("· 非账单")
                        .foregroundStyle(secondary)
                }
                .font(.system(size: 9.5))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            .frame(width: 156, alignment: .leading)

            Canvas { context, size in
                let track = GraphicsContext.Shading.color(FloatingSurfaceTheme.track())
                let baseColor = FloatingSurfaceTheme.costData()
                let stride = barCellWidth + barGap
                let maxCost = max(0.0001, chart.maximum)
                for (index, day) in chart.days.enumerated() {
                    let x = CGFloat(index) * stride
                    let barHeight = max(3, size.height * CGFloat((day.cost ?? 0) / maxCost))
                    let rect = CGRect(x: x, y: size.height - barHeight, width: barCellWidth, height: barHeight)
                    let path = Path(roundedRect: rect, cornerRadius: 2)
                    if let cost = day.cost, cost > 0 {
                        let highlighted = selectedCost == day.date || hoveredCost == day.date
                        let opacity = highlighted ? 1.0 : (0.38 + 0.44 * cost / maxCost)
                        context.fill(path, with: .color(baseColor.opacity(opacity)))
                    } else {
                        context.fill(path, with: track)
                    }
                }
            }
            .frame(width: barsAreaWidth, height: 52)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let next = costDayIndex(at: point, count: chart.days.count, cellWidth: barCellWidth, height: 52)
                        .map { chart.days[$0].date }
                    if hoveredCost != next { hoveredCost = next }
                case .ended:
                    if hoveredCost != nil { hoveredCost = nil }
                }
            }
            .gesture(
                SpatialTapGesture().onEnded { event in
                    if let index = costDayIndex(at: event.location, count: chart.days.count, cellWidth: barCellWidth, height: 52) {
                        let date = chart.days[index].date
                        selectedCost = selectedCost == date ? nil : date
                    }
                }
            )
            .overlay(alignment: .topLeading) {
                if let hoveredCost, let index = chart.days.firstIndex(where: { $0.date == hoveredCost }) {
                    Color.clear
                        .frame(width: barCellWidth, height: 52)
                        .offset(x: CGFloat(index) * (barCellWidth + barGap), y: 0)
                        .anchorPreference(key: DashboardHoverAnchor.self, value: .bounds) { $0 }
                        .allowsHitTesting(false)
                }
            }
            .overlayPreferenceValue(DashboardHoverAnchor.self) { anchor in
                if let day = chart.days.first(where: { $0.date == hoveredCost }) {
                    IslandUsageChartTooltip(anchor: anchor, height: 74) {
                        Text(Self.abbreviatedDateFormatter.string(from: day.date))
                        Text(day.cost == nil ? chart.missingLabel(for: day) : money(day.cost) + " · 估算值")
                        Text(tokens(day.tokens) + " Tokens")
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(chart.title)
            .accessibilityValue((chart.totalIsLowerBound && chart.total != nil ? "≥" : "") + money(chart.total))
        }
        .frame(height: 58)
        .help(chart.helpText)
        .accessibilityHint(chart.accessibilityHint)
    }

    fileprivate static func monthTitle(for date: Date) -> String {
        monthFormatter.string(from: date)
    }

    fileprivate static func dateTitle(for date: Date) -> String {
        abbreviatedDateFormatter.string(from: date)
    }
}

private struct IslandUsageHeatmapCard: View, IslandUsageFormatting {
    let activity: [DailyTokenActivity]
    let lifetimeTokens: Int?
    let activityHelp: String
    let width: CGFloat
    let endingAt: Date
    let generation: String
    let countStyle: String
    @Binding var mode: IslandDashboardHeatmap.Mode
    @Binding var selectedActivity: String?
    @Binding var hoveredActivity: Int?

    private var viewportWidth: CGFloat { max(180, width - 56 - 28) }
    private var visibleColumns: Int { max(24, min(53, Int((viewportWidth + 2.5) / 11.0))) }

    var body: some View {
        let grid = IslandDashboardHeatmap(
            activity: activity,
            endingAt: endingAt,
            mode: mode,
            lifetimeTokens: lifetimeTokens
        )
        IslandUsageHeatmapContentView(
            grid: grid,
            activityHelp: activityHelp,
            viewportWidth: viewportWidth,
            visibleColumns: visibleColumns,
            countStyle: countStyle,
            mode: $mode,
            selectedActivity: $selectedActivity,
            hoveredActivity: $hoveredActivity
        )
    }
}

private struct IslandUsageHeatmapContentView: View, IslandUsageFormatting {
    let grid: IslandDashboardHeatmap
    let activityHelp: String
    let viewportWidth: CGFloat
    let visibleColumns: Int
    let countStyle: String
    @Binding var mode: IslandDashboardHeatmap.Mode
    @Binding var selectedActivity: String?
    @Binding var hoveredActivity: Int?

    private let cellGap: CGFloat = 2.5
    private let cellHeight: CGFloat = 8.0
    private var startColumn: Int { max(0, 53 - visibleColumns) }
    private var cellWidth: CGFloat {
        max(4, (viewportWidth - CGFloat(max(0, visibleColumns - 1)) * cellGap) / CGFloat(max(1, visibleColumns)))
    }
    private var rowsHeight: CGFloat { cellHeight * 7 + cellGap * 6 }

    private func cellHitIndex(at point: CGPoint) -> Int? {
        guard point.x >= 0, point.y >= 0, point.y <= rowsHeight else { return nil }
        let xStride = cellWidth + cellGap
        let yStride = cellHeight + cellGap
        let visCol = Int(point.x / xStride)
        let row = Int(point.y / yStride)
        guard (0..<visibleColumns).contains(visCol), (0..<7).contains(row),
              point.x - CGFloat(visCol) * xStride <= cellWidth + 1.25,
              point.y - CGFloat(row) * yStride <= cellHeight + 1.25 else { return nil }
        let column = startColumn + visCol
        let index = grid.cellIndex(column: column, row: row)
        guard grid.cells.indices.contains(index), !grid.cells[index].future else { return nil }
        return index
    }

    var body: some View {
        let _ = countStyle
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                heading("Token 活动")
                if let selectedActivity {
                    heading("· " + selectedActivity).lineLimit(1)
                }
                Spacer(minLength: 8)
                ForEach(IslandDashboardHeatmap.Mode.allCases, id: \.self) { option in
                    Button { mode = option; selectedActivity = nil; hoveredActivity = nil } label: {
                        Text(option == .daily ? "每天" : option == .weekly ? "每周" : "累计")
                            .font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
                            .islandGlass(Capsule(), tint: mode == option ? FloatingSurfaceTheme.accent().opacity(0.24) : .black.opacity(0.28))
                            .contentShape(Capsule())
                    }.buttonStyle(FloatingSurfaceButtonStyle()).accessibilityValue(mode == option ? "已选择" : "未选择")
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Canvas { context, _ in
                    let track = GraphicsContext.Shading.color(FloatingSurfaceTheme.track())
                    let futureTrack = GraphicsContext.Shading.color(FloatingSurfaceTheme.track().opacity(0.25))
                    let base = FloatingSurfaceTheme.usageData()
                    let shade1 = GraphicsContext.Shading.color(base.opacity(0.25))
                    let shade2 = GraphicsContext.Shading.color(base.opacity(0.45))
                    let shade3 = GraphicsContext.Shading.color(base.opacity(0.65))
                    let shade4 = GraphicsContext.Shading.color(base.opacity(0.90))
                    let hoverStroke = GraphicsContext.Shading.color(base)
                    let xStride = cellWidth + cellGap
                    let yStride = cellHeight + cellGap
                    let maxVal = Double(max(1, grid.maximum))

                    for visCol in 0..<visibleColumns {
                        let column = startColumn + visCol
                        let x = CGFloat(visCol) * xStride
                        for row in 0..<7 {
                            let index = grid.cellIndex(column: column, row: row)
                            let cell = grid.cells[index]
                            let y = CGFloat(row) * yStride
                            let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
                            let path = Path(roundedRect: rect, cornerRadius: 2)
                            if cell.future {
                                context.fill(path, with: futureTrack)
                                continue
                            }
                            let filled = grid.mode == .daily || grid.isFilled(column: column, row: row)
                            if filled, let value = cell.tokens, value > 0 {
                                let level = Double(value) / maxVal
                                let shading = level < 0.25 ? shade1 : (level < 0.5 ? shade2 : (level < 0.75 ? shade3 : shade4))
                                context.fill(path, with: shading)
                            } else {
                                context.fill(path, with: track)
                            }
                            if hoveredActivity == index {
                                context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1.5), with: hoverStroke, lineWidth: 1)
                            }
                        }
                    }
                }
                .frame(width: viewportWidth, height: rowsHeight)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let next = cellHitIndex(at: point)
                        if hoveredActivity != next { hoveredActivity = next }
                    case .ended:
                        if hoveredActivity != nil { hoveredActivity = nil }
                    }
                }
                .gesture(
                    SpatialTapGesture().onEnded { event in
                        if let index = cellHitIndex(at: event.location) {
                            let cell = grid.cells[index]
                            selectedActivity = IslandUsageTrendCard.dateTitle(for: cell.date) + " · " + tokens(cell.tokens)
                        }
                    }
                )
                .overlay(alignment: .topLeading) {
                    if let index = hoveredActivity, grid.cells.indices.contains(index) {
                        let anchorColumn = grid.mode == .daily ? index / 7 : index
                        let anchorRow = grid.mode == .daily ? index % 7 : 0
                        let visCol = anchorColumn - startColumn
                        if (0..<visibleColumns).contains(visCol) {
                            Color.clear
                                .frame(width: cellWidth, height: cellHeight)
                                .offset(x: CGFloat(visCol) * (cellWidth + cellGap), y: CGFloat(anchorRow) * (cellHeight + cellGap))
                                .anchorPreference(key: DashboardHoverAnchor.self, value: .bounds) { $0 }
                                .allowsHitTesting(false)
                        }
                    }
                }
                .overlayPreferenceValue(DashboardHoverAnchor.self) { anchor in
                    if let index = hoveredActivity, grid.cells.indices.contains(index) {
                        IslandUsageChartTooltip(anchor: anchor, height: 58) {
                            Text(IslandUsageTrendCard.dateTitle(for: grid.cells[index].date))
                            Text(tokens(grid.cells[index].tokens) + " Tokens")
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Token 活动热力图")
                .accessibilityValue(selectedActivity ?? "峰值 " + tokens(grid.maximum))

                ZStack(alignment: .leading) {
                    ForEach(grid.months.indices, id: \.self) { index in
                        let visCol = grid.months[index].column - startColumn
                        if visCol >= 0 && visCol < visibleColumns - 1 {
                            Text(IslandUsageTrendCard.monthTitle(for: grid.months[index].date))
                                .font(FloatingSurfaceTypography.fine).foregroundStyle(secondary)
                                .offset(x: CGFloat(visCol) * (cellWidth + cellGap))
                        }
                    }
                }
                .frame(width: viewportWidth, height: 12, alignment: .leading)
            }
        }
        .help(activityHelp)
    }
}

private struct IslandUsageChartTooltip<Content: View>: View {
    let anchor: Anchor<CGRect>?
    let height: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View {
        // Resolve the upstream anchor outside the scroll clip so edge cells retain a readable tooltip.
        GeometryReader { proxy in
            if let anchor {
                let rect = proxy[anchor]
                let width = min(214, proxy.size.width)
                if rect.maxX > 0 && rect.minX < proxy.size.width {
                    VStack(alignment: .leading, spacing: 3, content: content)
                        .font(FloatingSurfaceTypography.caption).foregroundStyle(FloatingSurfaceTheme.primary()).padding(.horizontal, 11).padding(.vertical, 8)
                        .frame(width: width, alignment: .leading)
                        .background(FloatingSurfaceTheme.popover(), in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(FloatingSurfaceTheme.outline(), lineWidth: 0.5) }
                        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                        .offset(x: min(max(0, rect.midX - width / 2), max(0, proxy.size.width - width)), y: rect.minY - height)
                }
            }
        }.allowsHitTesting(false)
    }
}

private struct DashboardHoverAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { if let next = nextValue() { value = next } }
}
