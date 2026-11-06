// Draws the stage with CoreGraphics, ported from theater.js's canvas code.
// Coordinates are the stage's logical units (900 high); the view scales them to the screen.
import AppKit
import CoreImage
import StageCore

extension NSColor {
  convenience init(hex: UInt32, alpha: CGFloat = 1) {
    self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
  }
  static let lime = NSColor(hex: 0xd7ff62), ink = NSColor(hex: 0x2b2233), cream = NSColor(hex: 0xfff5e2)
}

func tone(_ t: Tone) -> NSColor {
  switch t { case .lime: .lime; case .amber: NSColor(hex: 0xffc574); case .red: NSColor(hex: 0xff8a7a); case .cream: NSColor(hex: 0xfff3bd); case .grey: NSColor(hex: 0x8a8f86) }
}

/// Sprites from the bundle, hue-rotated per project and cached.
final class Sprites {
  private var base: [String: CGImage] = [:]
  private var tinted: [String: CGImage] = [:]
  private let ci = CIContext()
  init() {
    for mood in ["happy", "scared", "dizzy"] { for f in 0..<3 {
      if let url = resource("\(mood)-\(f)", "png"),
         let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { base["\(mood)-\(f)"] = img }
    } }
  }
  func image(_ name: String, hue: Double) -> CGImage? {
    guard let img = base[name] else { return nil }
    let h = Int(hue) / 10 * 10
    if h == 0 { return img }
    let key = "\(name)-\(h)"
    if let t = tinted[key] { return t }
    let f = CIFilter(name: "CIHueAdjust")!
    f.setValue(CIImage(cgImage: img), forKey: kCIInputImageKey)
    f.setValue(Double(h) * .pi / 180, forKey: kCIInputAngleKey)
    guard let out = f.outputImage, let cg = ci.createCGImage(out, from: out.extent) else { return img }
    tinted[key] = cg
    return cg
  }
}

struct Renderer {
  let ctx: CGContext
  let stage: Stage
  let sprites: Sprites

  private func text(_ s: String, at p: CGPoint, size: CGFloat, bold: Bool = false, color: NSColor, align: NSTextAlignment = .left, maxWidth: CGFloat? = nil) {
    let font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    var str = s
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if let maxWidth {
      while str.count > 1 && (str as NSString).size(withAttributes: attrs).width > maxWidth { str = String(str.dropLast(2)) + "…" }
    }
    let w = (str as NSString).size(withAttributes: attrs).width
    let x = align == .center ? p.x - w / 2 : align == .right ? p.x - w : p.x
    (str as NSString).draw(at: CGPoint(x: x, y: p.y - size), withAttributes: attrs)
  }

  private func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

  // MARK: characters

  func mascot(x: Double, y: Double, r: Double, hurt: Int, scared: Bool, hue: Double, accessory: String, folder: String, title: String, ghost: Bool = false) {
    ctx.saveGState()
    let lift = hurt > 0 ? sin(Double(hurt) / 28 * .pi) * 20 : 0
    ctx.translateBy(x: x, y: y - lift)
    if hurt > 0 { ctx.rotate(by: sin(Double(hurt) * 0.8) * 0.08) }
    let mood = hurt > 0 ? "dizzy" : scared ? "scared" : "happy"
    let w = r * 2, h = w * 363 / 461
    if let img = sprites.image("\(mood)-\((stage.time / 9) % 3)", hue: hue) {
      ctx.saveGState()
      ctx.setShadow(offset: .zero, blur: 3, color: NSColor.cream.cgColor)
      ctx.translateBy(x: 0, y: h / 2); ctx.scaleBy(x: 1, y: -1)
      ctx.draw(img, in: CGRect(x: -w / 2, y: 0, width: w, height: h))
      ctx.restoreGState()
    }
    drawAccessory(accessory, hue: hue, w: w, h: h)
    if !ghost {
      // A dark plate behind the label keeps it readable over any desktop.
      let label = clip(folder.isEmpty ? "session" : folder, 20)
      ctx.setFillColor(NSColor(hex: 0x11120f, alpha: 0.72).cgColor)
      ctx.addPath(CGPath(roundedRect: CGRect(x: -w * 0.62, y: h / 2 + 4, width: w * 1.24, height: title.isEmpty ? 22 : 40), cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.fillPath()
      text(label, at: CGPoint(x: 0, y: h / 2 + 22), size: 15, bold: true, color: .cream, align: .center)
      if !title.isEmpty { text(clip(title, 26), at: CGPoint(x: 0, y: h / 2 + 39), size: 11, color: NSColor(hex: 0xb8bba8), align: .center) }
    }
    ctx.restoreGState()
  }

  private func drawAccessory(_ a: String, hue: Double, w: Double, h: Double) {
    let top = -h / 2
    let col = NSColor(hue: CGFloat((hue + 180).truncatingRemainder(dividingBy: 360) / 360), saturation: 0.7, brightness: 0.95, alpha: 1).cgColor
    ctx.saveGState(); ctx.setFillColor(col); ctx.setStrokeColor(NSColor.ink.cgColor); ctx.setLineWidth(3)
    func fs(_ p: CGPath) { ctx.addPath(p); ctx.drawPath(using: .fillStroke) }
    switch a {
    case "cap":
      fs(CGPath(roundedRect: CGRect(x: -w * 0.3, y: top - 16, width: w * 0.6, height: 22), cornerWidth: 10, cornerHeight: 10, transform: nil))
      fs(CGPath(rect: CGRect(x: w * 0.2, y: top + 2, width: w * 0.22, height: 6), transform: nil))
    case "bow":
      for s in [-1.0, 1.0] { let p = CGMutablePath(); p.move(to: CGPoint(x: w * 0.22, y: top + 4)); p.addLine(to: CGPoint(x: w * 0.22 + s * 18, y: top - 10)); p.addLine(to: CGPoint(x: w * 0.22 + s * 18, y: top + 18)); p.closeSubpath(); fs(p) }
    case "glasses":
      for s in [-1.0, 1.0] { ctx.strokeEllipse(in: CGRect(x: s * w * 0.15 - 15, y: top + h * 0.33 - 15, width: 30, height: 30)) }
      ctx.move(to: CGPoint(x: -w * 0.15 + 15, y: top + h * 0.33)); ctx.addLine(to: CGPoint(x: w * 0.15 - 15, y: top + h * 0.33)); ctx.strokePath()
    case "headphones":
      ctx.setStrokeColor(col); ctx.setLineWidth(6)
      ctx.addArc(center: CGPoint(x: 0, y: top + 14), radius: w * 0.4, startAngle: .pi * 1.08, endAngle: .pi * 1.92, clockwise: false); ctx.strokePath()
      ctx.setStrokeColor(NSColor.ink.cgColor); ctx.setLineWidth(3)
      for s in [-1.0, 1.0] { fs(CGPath(roundedRect: CGRect(x: s * w * 0.42 - 9, y: top + 8, width: 18, height: 30), cornerWidth: 6, cornerHeight: 6, transform: nil)) }
    case "crown":
      let p = CGMutablePath()
      p.addLines(between: [(-0.2, 4), (-0.2, -16), (-0.1, -4), (0, -20), (0.1, -4), (0.2, -16), (0.2, 4)].map { CGPoint(x: w * $0.0, y: top + $0.1) }); p.closeSubpath(); fs(p)
    case "antenna":
      ctx.move(to: CGPoint(x: 0, y: top + 2)); ctx.addLine(to: CGPoint(x: 0, y: top - 22)); ctx.strokePath()
      fs(CGPath(ellipseIn: CGRect(x: -7, y: top - 33, width: 14, height: 14), transform: nil))
    default: break
    }
    ctx.restoreGState()
  }

  // MARK: prompt boxes

  static let kindLabel = ["permission": "PERMISSION REQUIRED", "question": "QUESTION", "plan": "PLAN READY", "input": "WAITING FOR YOU"]
  static let kindColor: [String: UInt32] = ["permission": 0xd89324, "question": 0x6789ad, "plan": 0x8a6bc4, "input": 0x6b9853]

  func promptBox(_ m: Box, prompt: Prompt, folder: String, born: Int, live: Bool, stamp: StampMark?) {
    let age = Double(stage.time - born), scale = min(1, (age + 1) / 12)
    let shk = age < 40 ? (1 - age / 40) * 7 : 0, pulse = live ? (sin(Double(stage.time) * 0.14) + 1) / 2 : 0
    ctx.saveGState()
    ctx.translateBy(x: m.x + m.w / 2 + sin(age * 1.9) * shk, y: m.y + m.h / 2 + cos(age * 2.3) * shk * 0.5)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -m.w / 2, y: -m.h / 2)
    let rect = CGRect(x: 0, y: 0, width: m.w, height: m.h), path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: pulse > 0 ? .zero : CGSize(width: 0, height: 7), blur: pulse > 0 ? 14 + pulse * 14 : 15,
                  color: pulse > 0 ? NSColor(srgbRed: 1, green: 170 / 255, blue: 40 / 255, alpha: 0.35 + pulse * 0.55).cgColor : NSColor(white: 0, alpha: 0.55).cgColor)
    ctx.setFillColor(NSColor(hex: prompt.kind == "permission" ? 0xfff0c8 : 0xfff5e2).cgColor)
    ctx.addPath(path); ctx.fillPath()
    ctx.restoreGState()
    ctx.setStrokeColor(pulse > 0 ? NSColor(srgbRed: 1, green: (150 + pulse * 70) / 255, blue: (30 + pulse * 50) / 255, alpha: 1).cgColor : NSColor.ink.cgColor)
    ctx.setLineWidth(4 + pulse * 3); ctx.addPath(path); ctx.strokePath()
    let kc = NSColor(hex: Renderer.kindColor[prompt.kind] ?? 0xd97757)
    ctx.setFillColor(kc.cgColor); ctx.fill(CGRect(x: 0, y: 14, width: 5, height: m.h - 28))
    text("\(clip(folder.isEmpty ? "session" : folder, 22).uppercased()) · \(Renderer.kindLabel[prompt.kind] ?? "NEEDS YOU")", at: CGPoint(x: 17, y: 25), size: 11, bold: true, color: kc)
    // Up to two lines of the prompt text, word-wrapped.
    let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold), attrs: [NSAttributedString.Key: Any] = [.font: font]
    var lines: [String] = [], line = ""
    for word in prompt.text.split(separator: " ") {
      let next = line.isEmpty ? String(word) : line + " " + word
      if (next as NSString).size(withAttributes: attrs).width > m.w - 34 && !line.isEmpty { lines.append(line); line = String(word); if lines.count == 2 { break } } else { line = next }
    }
    if lines.count < 2 && !line.isEmpty { lines.append(line) } else if lines.count == 2 && !line.isEmpty { lines[1] = clip(lines[1], 30) + "…" }
    for (i, l) in lines.prefix(2).enumerated() { text(l, at: CGPoint(x: 17, y: 49 + Double(i) * 20), size: 15, bold: true, color: .ink, maxWidth: m.w - 30) }
    text(clip(prompt.detail ?? "", 52), at: CGPoint(x: 17, y: m.h - 12), size: 10, color: NSColor(hex: 0x9a4d17), maxWidth: m.w - 30)
    if let st = stamp {
      let a = Double(st.max - st.life), pop = a < 6 ? 1.6 - a / 10 : 1
      ctx.saveGState(); ctx.setAlpha(min(1, CGFloat(st.life) / 30))
      ctx.translateBy(x: m.w / 2, y: m.h / 2); ctx.rotate(by: -0.14); ctx.scaleBy(x: pop, y: pop)
      let c = st.approve ? NSColor(hex: 0x3f7d1f) : NSColor(hex: 0xd6281a)
      let w = (st.text as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 40, weight: .bold)]).width + 30
      ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(6); ctx.stroke(CGRect(x: -w / 2, y: -34, width: w, height: 64))
      text(st.text, at: CGPoint(x: 0, y: 22), size: 40, bold: true, color: c, align: .center)
      ctx.restoreGState()
    }
    ctx.restoreGState()
  }

  // MARK: tools

  func whip(_ pts: [RopePoint], intern: Bool = false) {
    ctx.saveGState(); ctx.setLineCap(.round)
    if intern {
      ctx.setStrokeColor(NSColor.lime.cgColor); ctx.setLineWidth(5)
      ctx.addLines(between: pts.map { CGPoint(x: $0.x, y: $0.y) }); ctx.strokePath()
    } else {
      for i in 0..<(pts.count - 1) {
        let a = CGPoint(x: pts[i].x, y: pts[i].y), b = CGPoint(x: pts[i + 1].x, y: pts[i + 1].y)
        ctx.setStrokeColor(NSColor(hex: 0xfff7d4).cgColor); ctx.setLineWidth(12 - Double(i) * 0.28); ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        ctx.setStrokeColor(NSColor(hex: i < 2 ? 0x91a23e : 0x6f452c).cgColor); ctx.setLineWidth(7 - Double(i) * 0.19); ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
      }
    }
    ctx.restoreGState()
  }

  func cannon() {
    let o = stage.cannonOrigin
    ctx.saveGState()
    ctx.translateBy(x: o.x - 420 * pow(Double(stage.cannonEntry) / 90, 3), y: o.y)
    ctx.rotate(by: atan2(stage.mouse.y - o.y, stage.mouse.x - o.x))
    ctx.setFillColor(NSColor.lime.cgColor); ctx.setStrokeColor(NSColor(hex: 0x10120b).cgColor); ctx.setLineWidth(5)
    ctx.addPath(CGPath(roundedRect: CGRect(x: -60, y: -43, width: 160, height: 86), cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.drawPath(using: .fillStroke)
    ctx.setFillColor(NSColor(hex: 0x778347).cgColor); ctx.fill(CGRect(x: 85, y: -28, width: 95, height: 56))
    text("LGTM-9000", at: CGPoint(x: -47, y: 12), size: 15, bold: true, color: NSColor(hex: 0x11150b))
    ctx.restoreGState()
    if stage.cannonEntry > 0 { text("SAY HELLO TO MY LITTLE FRIEND.", at: CGPoint(x: 80, y: 700), size: 27, bold: true, color: .lime) }
  }

  func shots() {
    for p in stage.shots {
      ctx.saveGState(); ctx.translateBy(x: p.x, y: p.y); ctx.rotate(by: p.angle)
      ctx.setFillColor(NSColor.lime.cgColor); ctx.fill(CGRect(x: -48, y: -23, width: 96, height: 46))
      ctx.setStrokeColor(NSColor(hex: 0x111111).cgColor); ctx.setLineWidth(3); ctx.stroke(CGRect(x: -44, y: -19, width: 88, height: 38))
      text("LGTM", at: CGPoint(x: 0, y: 14), size: 24, bold: true, color: NSColor(hex: 0x111111), align: .center)
      ctx.restoreGState()
    }
  }

  func particles() {
    for p in stage.particles {
      ctx.saveGState(); ctx.setAlpha(min(1, CGFloat(p.life) / 65)); ctx.translateBy(x: p.x, y: p.y); ctx.rotate(by: p.angle)
      text(p.text, at: CGPoint(x: 0, y: 0), size: 22, bold: true, color: tone(p.tone))
      ctx.restoreGState()
    }
  }

  private func stampDevice(x: Double, y: Double, lift: Double, scale: Double, alpha: Double, grey: Bool) {
    ctx.saveGState(); ctx.setAlpha(alpha); ctx.translateBy(x: x, y: y - lift); ctx.scaleBy(x: scale, y: scale)
    ctx.setLineWidth(4); ctx.setStrokeColor(NSColor.ink.cgColor)
    ctx.setFillColor((grey ? NSColor(hex: 0x6d6f68) : .ink).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: -20, y: -146, width: 40, height: 56), cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.fillPath()
    ctx.fill(CGRect(x: -9, y: -92, width: 18, height: 40))
    ctx.setFillColor((grey ? NSColor(hex: 0x8a8f86) : NSColor(hex: 0xc9331f)).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: -84, y: -56, width: 168, height: 56), cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.drawPath(using: .fillStroke)
    text("REQUEST", at: CGPoint(x: 0, y: -25), size: 14, bold: true, color: NSColor(hex: 0xfff3e8), align: .center)
    text("CHANGES", at: CGPoint(x: 0, y: -7), size: 14, bold: true, color: NSColor(hex: 0xfff3e8), align: .center)
    ctx.restoreGState()
  }

  func stamps() {
    for s in stage.slams {
      let a = Double(s.age)
      stampDevice(x: s.x, y: s.y, lift: s.age < 5 ? (5 - a) * 16 : s.age > 26 ? (a - 26) * 20 : 0, scale: s.age < 5 ? 1 + (5 - a) * 0.07 : 1, alpha: s.age > 30 ? Double(Layout.slam - s.age) / 6 : 1, grey: false)
    }
    // With the whip in hand, a ring round the handle shows the stamp cooling down after a slam.
    if stage.tools.whip, stage.slams.isEmpty, stage.stampReady > stage.time {
      let wait = stage.stampReady - stage.time, m = stage.mouse
      ctx.setStrokeColor(NSColor(hex: 0xff9b82).cgColor); ctx.setLineWidth(4)
      ctx.addArc(center: CGPoint(x: m.x, y: m.y), radius: 26, startAngle: -.pi / 2, endAngle: -.pi / 2 + (1 - Double(wait) / Double(Layout.stampCooldown)) * .pi * 2, clockwise: false)
      ctx.strokePath()
    }
    for m in stage.marks {
      let a = Double(m.max - m.life), pop = a < 6 ? 1.5 - a / 12 : 1
      ctx.saveGState(); ctx.setAlpha(min(1, CGFloat(m.life) / 40) * 0.9); ctx.translateBy(x: m.x, y: m.y); ctx.rotate(by: -0.1); ctx.scaleBy(x: pop, y: pop)
      let w = (m.text as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 28, weight: .bold)]).width + 36
      ctx.setStrokeColor(NSColor(hex: 0x8a8f86).cgColor); ctx.setLineWidth(5); ctx.stroke(CGRect(x: -w / 2, y: -30, width: w, height: 52))
      text(m.text, at: CGPoint(x: 0, y: 12), size: 28, bold: true, color: NSColor(hex: 0x8a8f86), align: .center)
      ctx.restoreGState()
    }
  }

  func intern() {
    guard let i = stage.intern else { return }
    let x = i.hand.x - 38, y = i.hand.y + 62
    if let img = sprites.image("happy-0", hue: 0) {
      ctx.saveGState(); ctx.translateBy(x: x - 60, y: y + 47); ctx.scaleBy(x: 1, y: -1); ctx.draw(img, in: CGRect(x: 0, y: 0, width: 120, height: 94)); ctx.restoreGState()
    }
    let flash = Double(stage.internFlash) / 26
    ctx.setFillColor((flash > 0 ? NSColor(white: 1, alpha: 0.9) : .lime).cgColor); ctx.fill(CGRect(x: x - 72, y: y + 48, width: 144, height: 27))
    text("APPROVAL INTERN", at: CGPoint(x: x, y: y + 67), size: 12, bold: true, color: NSColor(hex: 0x14200c), align: .center)
    if let w = i.whip { whip(w.points, intern: true) }
  }

  // MARK: answer cards

  func spread(_ s: Spread) {
    let q = s.question, age = Double(stage.time - s.dealtAt)
    let hover = s.card(at: stage.mouse)
    // The question above the cards, on a dark plate so it reads over any desktop.
    let head = "\(s.questions.count > 1 ? "\(s.index + 1)/\(s.questions.count) · " : "")\(q.header.map { "\($0.uppercased()) · " } ?? "")\(q.question)"
    let hint = s.multi ? "click to toggle · Done to send · right-click: pick with a note · Esc: put away" : "click to pick · right-click: pick with a note · Esc: put away"
    let left = s.cards.map(\.box.x).min() ?? 0, right = s.cards.map { $0.box.x + $0.box.w }.max() ?? 0
    let plateW = max(right - left, 520.0), plateX = (left + right) / 2 - plateW / 2
    ctx.setFillColor(NSColor(hex: 0x11120f, alpha: 0.85).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: plateX, y: s.bannerY - 44, width: plateW, height: 50), cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.fillPath()
    text(head, at: CGPoint(x: plateX + 14, y: s.bannerY - 22), size: 16, bold: true, color: .lime, maxWidth: plateW - 28)
    text(hint, at: CGPoint(x: plateX + 14, y: s.bannerY - 4), size: 11, color: NSColor(hex: 0xc9ccb8), maxWidth: plateW - 28)
    for (i, c) in s.cards.enumerated() {
      // Dealt one after another, popping up from below.
      let t = min(1, max(0, (age - Double(i) * 3) / 10))
      guard t > 0 else { continue }
      let picked: Bool = { if case .option(let l) = c.kind { return s.picked.contains(l) }; return false }()
      let lifted = hover == i
      let b = c.box
      ctx.saveGState()
      ctx.setAlpha(t)
      ctx.translateBy(x: b.x + b.w / 2, y: b.y + b.h / 2 + (1 - t) * 40 - (lifted ? 6 : 0))
      ctx.rotate(by: (Double(i) - Double(s.cards.count - 1) / 2) * 0.012)
      ctx.translateBy(x: -b.w / 2, y: -b.h / 2)
      let rect = CGRect(x: 0, y: 0, width: b.w, height: b.h), path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
      ctx.saveGState()
      ctx.setShadow(offset: CGSize(width: 0, height: lifted ? 14 : 8), blur: lifted ? 22 : 14, color: NSColor(white: 0, alpha: 0.55).cgColor)
      let isDone = c.kind == .done
      ctx.setFillColor(NSColor(hex: picked ? 0xffc574 : isDone ? 0xd7ff62 : 0xfff5e2).cgColor)
      ctx.addPath(path); ctx.fillPath()
      ctx.restoreGState()
      ctx.setStrokeColor((lifted || picked ? NSColor.ink : NSColor(hex: 0x6789ad)).cgColor); ctx.setLineWidth(lifted || picked ? 4 : 3)
      ctx.addPath(path); ctx.strokePath()
      if !isDone { ctx.setFillColor(NSColor(hex: 0x6789ad).cgColor); ctx.fill(CGRect(x: 0, y: 14, width: 5, height: b.h - 28)) }
      text(c.title, at: CGPoint(x: 16, y: 30), size: 17, bold: true, color: .ink, maxWidth: b.w - 30)
      // Description, up to three wrapped lines.
      let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), attrs: [NSAttributedString.Key: Any] = [.font: font]
      var lines: [String] = [], line = ""
      for word in c.detail.split(separator: " ") {
        let next = line.isEmpty ? String(word) : line + " " + word
        if (next as NSString).size(withAttributes: attrs).width > b.w - 32 && !line.isEmpty { lines.append(line); line = String(word) } else { line = next }
      }
      if !line.isEmpty { lines.append(line) }
      for (k, l) in lines.prefix(3).enumerated() { text(k == 2 && lines.count > 3 ? clip(l, 26) + "…" : l, at: CGPoint(x: 16, y: 54 + Double(k) * 16), size: 11, color: NSColor.ink.withAlphaComponent(0.75), maxWidth: b.w - 30) }
      if picked { text("✓", at: CGPoint(x: b.w - 18, y: 30), size: 20, bold: true, color: .ink, align: .right) }
      ctx.restoreGState()
    }
  }

  // MARK: frame

  func draw() {
    for c in stage.all {
      let dx = stage.enterOffset(c)
      if dx > 2 {
        for k in 1...4 { ctx.saveGState(); ctx.setAlpha(0.2 * (1 - CGFloat(k) / 5)); mascot(x: c.x + dx + Double(k) * 26, y: c.y, r: c.r, hurt: c.hurt, scared: true, hue: c.hue, accessory: c.accessory, folder: "", title: "", ghost: true); ctx.restoreGState() }
      }
      mascot(x: c.x + dx, y: c.y, r: c.r, hurt: c.hurt, scared: c.prompt != nil && !c.answered, hue: c.hue, accessory: c.accessory, folder: c.folder, title: c.title)
    }
    for d in stage.departures {
      let f = max(0, CGFloat(d.life) / CGFloat(d.max))
      for k in 1...3 { ctx.saveGState(); ctx.setAlpha(f * 0.22 / CGFloat(k)); mascot(x: d.x - Double(k) * 34, y: d.y, r: d.r, hurt: d.hurt, scared: false, hue: d.hue, accessory: d.accessory, folder: "", title: "", ghost: true); ctx.restoreGState() }
      ctx.saveGState(); ctx.setAlpha(f); mascot(x: d.x, y: d.y, r: d.r, hurt: d.hurt, scared: false, hue: d.hue, accessory: d.accessory, folder: d.folder, title: d.title); ctx.restoreGState()
    }
    for c in stage.all { if let b = c.box, let p = c.prompt { ctx.saveGState(); ctx.translateBy(x: stage.enterOffset(c), y: 0); promptBox(b, prompt: p, folder: c.folder, born: c.boxBorn, live: !c.answered, stamp: c.stamp); ctx.restoreGState() } }
    for d in stage.departures { if let b = d.box, let p = d.prompt { ctx.saveGState(); ctx.setAlpha(max(0, CGFloat(d.life) / CGFloat(d.max))); ctx.translateBy(x: d.x - d.x0, y: 0); promptBox(b, prompt: p, folder: d.folder, born: -100, live: false, stamp: d.stamp); ctx.restoreGState() } }
    if let w = stage.whip { whip(w.points) }
    if stage.tools.cannon { cannon() }
    if let s = stage.spread { spread(s) }
    shots(); particles(); stamps(); intern()
  }
}
