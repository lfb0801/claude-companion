import SwiftUI

/// A project always looks the same: FNV-1a over its folder path, like the Mac stage (Layout.looks).
struct PhoneLook {
  static let accessories = ["none", "cap", "bow", "glasses", "headphones", "crown", "antenna"]
  let hue: Double
  let accessory: String

  init(_ key: String) {
    var h: UInt32 = 2166136261
    for u in key.utf16 { h ^= UInt32(u); h = h &* 16777619 }
    hue = Double(h % 360)
    accessory = Self.accessories[Int((h >> 9) % UInt32(Self.accessories.count))]
  }
}

/// One session as a Claude in a bubble. The sprite shows what it is doing: working cycles and bobs, waiting
/// looks scared, idle sits still and dim, and a whip or stamp makes it dizzy for a moment.
struct SessionFigure: View {
  let size: CGFloat
  let look: PhoneLook
  /// waiting, working or idle.
  let state: String
  let dizzyUntil: Date?
  let pal: Palette
  var ring: Color? = nil
  var filled = false
  var calm = false

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: calm)) { context in
      let now = context.date
      let t = calm ? 0 : now.timeIntervalSinceReferenceDate
      let dizzy = (dizzyUntil ?? .distantPast) > now
      let working = state == "working" && !dizzy
      let waiting = state == "waiting" && !dizzy
      let idle = state == "idle" && !dizzy
      let mood = dizzy ? "dizzy" : waiting ? "scared" : "happy"
      let frame = idle ? 0 : Int(t * 8) % 3
      let sw = size * 0.66, sh = sw * 363 / 461
      let tint = Color(hue: ((20 + look.hue).truncatingRemainder(dividingBy: 360)) / 360, saturation: 0.5, brightness: 0.9)
      let accent = ring ?? tint

      // Working hops and rocks, waiting trembles and pulses, idle breathes slowly, dizzy sways and wobbles.
      let hop = working ? abs(sin(t * 5.5)) : 0
      let breath = sin(t * 1.5)
      let pulse = sin(t * 3.2)
      let scaleY = working ? 1 + (hop - 0.5) * 0.10 : idle ? 1 + breath * 0.035 : waiting ? 1 + pulse * 0.04 : 1
      let scaleX = working ? 1 - (hop - 0.5) * 0.07 : idle ? 1 - breath * 0.02 : waiting ? 1 + pulse * 0.04 : 1
      let lift = working ? -hop * size * 0.10 : 0
      let shake = waiting ? sin(t * 30) * size * 0.018 : dizzy ? cos(t * 7) * size * 0.03 : 0
      let sway = working ? sin(t * 5.5 + 0.6) * 0.10 : idle ? sin(t * 0.9) * 0.03 : dizzy ? sin(t * 8) * 0.22 : 0

      ZStack {
        Circle().fill(accent.opacity(filled ? 0.28 : 0.16))
        Circle().strokeBorder(accent.opacity(filled ? 0.95 : 0.55), lineWidth: filled ? 3 : 1.5)
        Circle().strokeBorder(accent.opacity(0.16), lineWidth: 1).padding(10)
        ZStack {
          Image("\(mood)-\(frame)")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: sw, height: sh)
            .hueRotation(.degrees(look.hue))
          Accessory(kind: look.accessory, hue: look.hue, width: sw, height: sh)
            .frame(width: sw * 1.4, height: sh * 1.9)
        }
        .scaleEffect(x: scaleX, y: scaleY, anchor: .bottom)
        .rotationEffect(.radians(sway), anchor: .bottom)
        .offset(x: shake, y: lift + size * 0.05)

        if idle && !calm {
          ForEach(0..<2, id: \.self) { i in
            let phase = (t * 0.45 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
            Text("z")
              .font(.system(size: size * (0.09 + 0.07 * phase), weight: .heavy, design: .rounded))
              .foregroundStyle(pal.subtext)
              .opacity(sin(phase * .pi))
              .offset(x: size * (0.20 + 0.10 * phase), y: -size * (0.12 + 0.20 * phase))
          }
        }
      }
      .frame(width: size, height: size)
    }
    .accessibilityHidden(true)
  }
}

/// The project's accessory, drawn like the Mac stage draws it (Renderer.drawAccessory).
private struct Accessory: View {
  let kind: String
  let hue: Double
  let width: CGFloat
  let height: CGFloat

  var body: some View {
    Canvas { ctx, size in
      let w = width, h = height, k = w / 110
      let top = -h / 2
      let col = Color(hue: ((hue + 180).truncatingRemainder(dividingBy: 360)) / 360, saturation: 0.7, brightness: 0.95)
      let ink = Color(hex: 0x11120f)
      ctx.translateBy(x: size.width / 2, y: size.height / 2)

      func fillStroke(_ p: Path) {
        ctx.fill(p, with: .color(col))
        ctx.stroke(p, with: .color(ink), lineWidth: 3 * k)
      }

      switch kind {
      case "cap":
        fillStroke(Path(roundedRect: CGRect(x: -w * 0.3, y: top - 16 * k, width: w * 0.6, height: 22 * k), cornerRadius: 10 * k))
        fillStroke(Path(CGRect(x: w * 0.2, y: top + 2 * k, width: w * 0.22, height: 6 * k)))
      case "bow":
        for s in [-1.0, 1.0] {
          var p = Path()
          p.move(to: CGPoint(x: w * 0.22, y: top + 4 * k))
          p.addLine(to: CGPoint(x: w * 0.22 + s * 18 * k, y: top - 10 * k))
          p.addLine(to: CGPoint(x: w * 0.22 + s * 18 * k, y: top + 18 * k))
          p.closeSubpath()
          fillStroke(p)
        }
      case "glasses":
        for s in [-1.0, 1.0] {
          let eye = Path(ellipseIn: CGRect(x: s * w * 0.15 - 15 * k, y: top + h * 0.33 - 15 * k, width: 30 * k, height: 30 * k))
          ctx.stroke(eye, with: .color(ink), lineWidth: 3 * k)
        }
        var bridge = Path()
        bridge.move(to: CGPoint(x: -w * 0.15 + 15 * k, y: top + h * 0.33))
        bridge.addLine(to: CGPoint(x: w * 0.15 - 15 * k, y: top + h * 0.33))
        ctx.stroke(bridge, with: .color(ink), lineWidth: 3 * k)
      case "headphones":
        var band = Path()
        let steps = 24
        for i in 0...steps {
          let a = Double.pi * (1.08 + 0.84 * Double(i) / Double(steps))
          let point = CGPoint(x: w * 0.4 * cos(a), y: top + 14 * k + w * 0.4 * sin(a))
          if i == 0 { band.move(to: point) } else { band.addLine(to: point) }
        }
        ctx.stroke(band, with: .color(col), lineWidth: 6 * k)
        for s in [-1.0, 1.0] {
          fillStroke(Path(roundedRect: CGRect(x: s * w * 0.42 - 9 * k, y: top + 8 * k, width: 18 * k, height: 30 * k), cornerRadius: 6 * k))
        }
      case "crown":
        var p = Path()
        let points: [(Double, Double)] = [(-0.2, 4), (-0.2, -16), (-0.1, -4), (0, -20), (0.1, -4), (0.2, -16), (0.2, 4)]
        p.addLines(points.map { CGPoint(x: w * $0.0, y: top + $0.1 * k) })
        p.closeSubpath()
        fillStroke(p)
      case "antenna":
        var stem = Path()
        stem.move(to: CGPoint(x: 0, y: top + 2 * k))
        stem.addLine(to: CGPoint(x: 0, y: top - 22 * k))
        ctx.stroke(stem, with: .color(ink), lineWidth: 3 * k)
        fillStroke(Path(ellipseIn: CGRect(x: -7 * k, y: top - 33 * k, width: 14 * k, height: 14 * k)))
      default:
        break
      }
    }
  }
}

/// Where an option of the long-press menu sits around the figure. Swiping that way picks it.
enum SessionMenuDirection: CaseIterable { case left, up, right }

/// The long-press menu: the figure lifted in the middle, its options sprung out around it.
struct SessionMenuOverlay: View {
  struct Option { let direction: SessionMenuDirection; let symbol: String; let title: String; let tint: Color }
  let figure: SessionFigure
  let name: String
  let options: [Option]
  let aim: SessionMenuDirection?
  let pal: Palette
  let pick: (SessionMenuDirection) -> Void
  let close: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown = false

  var body: some View {
    ZStack {
      pal.crust.opacity(shown ? 0.82 : 0).ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: close)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Close menu")
      VStack(spacing: 28) {
        bubble(.up)
        HStack(spacing: 14) {
          bubble(.left)
          figure.scaleEffect(shown ? 1.06 : 0.9).onTapGesture(perform: close)
          bubble(.right)
        }
        VStack(spacing: 4) {
          Text(name).font(.headline).foregroundStyle(pal.text).lineLimit(1)
          Text("Swipe toward one, or tap it. Tap outside to close.")
            .font(.footnote).foregroundStyle(pal.subtext)
        }
        .opacity(shown ? 1 : 0)
      }
      .padding(20)
    }
    .onAppear {
      withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.62)) { shown = true }
    }
  }

  @ViewBuilder private func bubble(_ direction: SessionMenuDirection) -> some View {
    if let option = options.first(where: { $0.direction == direction }) {
      let on = aim == direction
      let index = Double(SessionMenuDirection.allCases.firstIndex(of: direction) ?? 0)
      let away: CGSize = switch direction {
      case .left: CGSize(width: 50, height: 0)
      case .up: CGSize(width: 0, height: 50)
      case .right: CGSize(width: -50, height: 0)
      }
      Button { pick(direction) } label: { VStack(spacing: 6) {
        Image(systemName: option.symbol).font(.system(size: 24, weight: .semibold))
          .foregroundStyle(on ? pal.onAccent : option.tint)
          .frame(width: 64, height: 64)
          .background(on ? option.tint : pal.surface0, in: Circle())
          .overlay(Circle().strokeBorder(option.tint.opacity(on ? 0 : 0.6), lineWidth: 1.5))
        Text(option.title).font(.caption.weight(.semibold)).foregroundStyle(on ? option.tint : pal.subtext)
          .fixedSize()
      } }
      .buttonStyle(.plain)
      .scaleEffect(on ? 1.18 : 1)
      .opacity(shown ? (aim == nil || on ? 1 : 0.45) : 0)
      .offset(shown || reduceMotion ? .zero : away)
      .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.6).delay(0.05 * index), value: shown)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: aim)
    } else {
      Color.clear.frame(width: 64, height: 64)
    }
  }
}
