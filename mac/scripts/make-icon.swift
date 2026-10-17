// Jindesk 앱 아이콘을 그린다: 책상 위에 펼친 책. 왼쪽 쪽은 학교 자료(글줄), 오른쪽 쪽은 학습 페이지(그래프 그림),
// 위에는 설명을 비추는 작은 빛. 1024 정사각형(시스템이 둥근 모서리를 씌운다). Assayer 의 make-icon.swift 와 같은 방식이다.
// 사용: swift make-icon.swift <출력.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// 바탕: 짙은 청록에서 먹청록으로 (책상)
let bg = CGGradient(colorsSpace: space, colors: [color(0x23707A), color(0x0B2B33)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// 스탠드 불빛: 위에서 책을 비추는 따뜻한 빛
let glow = CGGradient(colorsSpace: space, colors: [color(0xFFD98A, 0.38), color(0xFFD98A, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 640), startRadius: 0, endCenter: CGPoint(x: 512, y: 640), endRadius: 520, options: [])

// 책: 가운데 등을 두고 두 쪽이 위로 휘어 펼쳐진다
let spineTop = CGPoint(x: 512, y: 690)
let spineBottom = CGPoint(x: 512, y: 262)
func page(left: Bool) -> CGPath {
  let s: CGFloat = left ? -1 : 1
  let p = CGMutablePath()
  p.move(to: spineBottom)
  p.addCurve(to: CGPoint(x: 512 + s * 352, y: 300), control1: CGPoint(x: 512 + s * 120, y: 300), control2: CGPoint(x: 512 + s * 260, y: 318))
  p.addLine(to: CGPoint(x: 512 + s * 352, y: 732))
  p.addCurve(to: spineTop, control1: CGPoint(x: 512 + s * 260, y: 750), control2: CGPoint(x: 512 + s * 120, y: 744))
  p.closeSubpath()
  return p
}

// 표지: 쪽보다 조금 크게, 아래로 비켜 두께를 보인다
// 그림자는 표지 전체에 한 번만 드리운다 (투명 층으로 묶는다)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -28), blur: 60, color: color(0x000000, 0.5))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(color(0xC2563C))
ctx.setStrokeColor(color(0xC2563C))
ctx.setLineWidth(26)
ctx.setLineJoin(.round)
for left in [true, false] {
  var shift = CGAffineTransform(translationX: 0, y: -22)
  guard let cover = page(left: left).copy(using: &shift) else { continue }
  ctx.addPath(cover)
  ctx.fillPath()
  ctx.addPath(cover)
  ctx.strokePath()
}
ctx.endTransparencyLayer()
ctx.restoreGState()

// 쪽: 크림색, 등 쪽으로 갈수록 그늘이 진다
for left in [true, false] {
  let path = page(left: left)
  ctx.saveGState()
  ctx.addPath(path)
  ctx.clip()
  let paper = CGGradient(colorsSpace: space, colors: [color(0xFFFDF6), color(0xEFE7D6)] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(paper, start: CGPoint(x: 512, y: 740), end: CGPoint(x: 512, y: 270), options: [])
  let shade = CGGradient(colorsSpace: space, colors: [color(0x7A6A4F, 0.32), color(0x7A6A4F, 0)] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(shade, start: CGPoint(x: 512, y: 500), end: CGPoint(x: left ? 420 : 604, y: 500), options: [])
  ctx.restoreGState()
}

// 왼쪽 쪽: 학교 자료의 글줄
ctx.setLineCap(.round)
ctx.setStrokeColor(color(0x8C96A0))
ctx.setLineWidth(22)
for (i, y) in [CGFloat(630), 560, 490, 420].enumerated() {
  let x0: CGFloat = 214
  let x1: CGFloat = i == 3 ? 380 : 462
  ctx.move(to: CGPoint(x: x0, y: y + 8))
  ctx.addLine(to: CGPoint(x: x1, y: y + 2))
}
ctx.strokePath()

// 오른쪽 쪽: 학습 페이지의 그림 (좌표축과 오르는 곡선, 점 하나)
ctx.setStrokeColor(color(0xA3ACB5))
ctx.setLineWidth(12)
ctx.move(to: CGPoint(x: 580, y: 650))
ctx.addLine(to: CGPoint(x: 580, y: 372))
ctx.addLine(to: CGPoint(x: 820, y: 384))
ctx.strokePath()
let (c0, c1, c2, c3) = (CGPoint(x: 596, y: 404), CGPoint(x: 700, y: 410), CGPoint(x: 770, y: 480), CGPoint(x: 806, y: 664))
let curve = CGMutablePath()
curve.move(to: c0)
curve.addCurve(to: c3, control1: c1, control2: c2)
ctx.addPath(curve)
ctx.setStrokeColor(color(0x2F7FD8))
ctx.setLineWidth(26)
ctx.strokePath()
// 곡선 위의 점 하나 (t = 0.62)
let tt: CGFloat = 0.62
func bez(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
  pow(1 - tt, 3) * a + 3 * pow(1 - tt, 2) * tt * b + 3 * (1 - tt) * tt * tt * c + pow(tt, 3) * d
}
let dot = CGPoint(x: bez(c0.x, c1.x, c2.x, c3.x), y: bez(c0.y, c1.y, c2.y, c3.y))
ctx.setFillColor(color(0xFFFDF6))
ctx.fillEllipse(in: CGRect(x: dot.x - 40, y: dot.y - 40, width: 80, height: 80))
ctx.setFillColor(color(0xE8613C))
ctx.fillEllipse(in: CGRect(x: dot.x - 30, y: dot.y - 30, width: 60, height: 60))

// 설명의 빛: 책 위 오른쪽의 네 갈래 반짝임
func sparkle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
  let p = CGMutablePath()
  let k = r * 0.22
  p.move(to: CGPoint(x: c.x, y: c.y + r))
  p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y + k))
  p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + k, y: c.y - k))
  p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y - k))
  p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - k, y: c.y + k))
  return p
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: color(0xFFD45C, 0.9))
ctx.addPath(sparkle(CGPoint(x: 780, y: 852), 96))
ctx.addPath(sparkle(CGPoint(x: 900, y: 760), 44))
ctx.setFillColor(color(0xFFE08A))
ctx.fillPath()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("그렸습니다: \(out)")
