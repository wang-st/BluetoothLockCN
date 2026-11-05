// 图标生成工具：解析 锁.svg 的矢量路径，渲染 App 图标(icns)与菜单栏模板图标
// 用法: swift tools/make_icon.swift <svg路径> <输出目录>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 最小 SVG path 解析器（支持 M/L/H/V/A/Z 及相对坐标）
struct PathParser {
    let path: String
    private var tokens: [String] = []
    private var pos = 0
    private var cur = CGPoint.zero
    private var start = CGPoint.zero

    init(path: String) { self.path = path; tokenize() }

    private mutating func tokenize() {
        var current = ""
        for ch in path {
            if ch.isLetter { if !current.isEmpty { tokens.append(current); current = "" }; tokens.append(String(ch)) }
            else if ch == "," || ch == " " || ch == "\n" || ch == "\t" { if !current.isEmpty { tokens.append(current); current = "" } }
            else if ch == "-" { if !current.isEmpty { tokens.append(current) }; current = "-" }
            else { current += String(ch) }
        }
        if !current.isEmpty { tokens.append(current) }
    }

    private mutating func number() -> CGFloat {
        let v = CGFloat(Double(tokens[pos])!)
        pos += 1
        return v
    }

    /// 解析为 CGPath（SVG 坐标系：y 向下）
    mutating func parse() -> CGPath {
        let p = CGMutablePath()
        var cmd: Character = " "
        var prevCmd: Character = " "

        func nextCmd() -> Bool {
            while pos < tokens.count {
                let t = tokens[pos]
                if t.count == 1, let c = t.first, c.isLetter { cmd = c; pos += 1; return true }
                // 隐式重复上一命令
                if "MLHVAmZz".contains(prevCmd) { cmd = prevCmd; return true }
                pos += 1
            }
            return false
        }

        while nextCmd() {
            switch cmd {
            case "M", "m":
                var x = number(), y = number()
                if cmd == "m" { x += cur.x; y += cur.y }
                cur = CGPoint(x: x, y: y); start = cur
                p.move(to: cur)
            case "L", "l":
                var x = number(), y = number()
                if cmd == "l" { x += cur.x; y += cur.y }
                cur = CGPoint(x: x, y: y)
                p.addLine(to: cur)
            case "H", "h":
                var x = number()
                if cmd == "h" { x += cur.x }
                cur = CGPoint(x: x, y: cur.y)
                p.addLine(to: cur)
            case "V", "v":
                var y = number()
                if cmd == "v" { y += cur.y }
                cur = CGPoint(x: cur.x, y: y)
                p.addLine(to: cur)
            case "A", "a":
                let rx = number(), ry = number(), rot = number()
                let largeArc = number(), sweep = number()
                var x = number(), y = number()
                if cmd == "a" { x += cur.x; y += cur.y }
                let end = CGPoint(x: x, y: y)
                addArc(p: p, from: cur, to: end, rx: rx, ry: ry, rotation: rot,
                       largeArc: largeArc != 0, sweep: sweep != 0)
                cur = end
            case "Z", "z":
                p.closeSubpath()
                cur = start
            default:
                break
            }
            prevCmd = cmd
        }
        return p
    }

    /// SVG 椭圆弧 → 三次贝塞尔（W3C 规范算法，SVG 坐标系内计算）
    private func addArc(p: CGMutablePath, from: CGPoint, to: CGPoint,
                        rx: CGFloat, ry: CGFloat, rotation: CGFloat,
                        largeArc: Bool, sweep: Bool) {
        if rx == 0 || ry == 0 || from == to { p.addLine(to: to); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (from.x - to.x) / 2, dy2 = (from.y - to.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2
        var rx = rx, ry = ry
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda); rx *= s; ry *= s
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = sqrt(max(0, num / den))
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (from.x + to.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (from.y + to.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                           (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
        if sweep && dtheta < 0 { dtheta += 2 * .pi }

        let n = max(1, Int(ceil(abs(dtheta) / (.pi / 2))))
        let delta = dtheta / CGFloat(n)
        let t = 4.0 / 3.0 * tan(delta / 4)
        var theta = theta1
        for _ in 0..<n {
            let cos1 = cos(theta), sin1 = sin(theta)
            let cos2 = cos(theta + delta), sin2 = sin(theta + delta)
            let e2x = cx + rx * cos2, e2y = cy + ry * sin2   // 段终点
            let d1x = -rx * sin1 * t, d1y = ry * cos1 * t    // 起点切线
            let d2x = -rx * sin2 * t, d2y = ry * cos2 * t    // 终点切线
            let s1 = CGPoint(x: cx + rx * cos1, y: cy + ry * sin1)
            p.addCurve(to: CGPoint(x: e2x, y: e2y),
                       control1: CGPoint(x: s1.x + d1x, y: s1.y + d1y),
                       control2: CGPoint(x: e2x - d2x, y: e2y - d2y))
            theta += delta
        }
    }
}

// MARK: - 渲染
func makeContext(size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func savePNG(_ ctx: CGContext, _ url: URL) {
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
guard args.count >= 3,
      let svgData = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    print("用法: make_icon.swift <svg> <输出目录>"); exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// 提取 path 的 d 属性（用 <path d= 精确匹配，避免误中 p-id= 等属性）
let d = svgData.components(separatedBy: "<path d=\"")[1].components(separatedBy: "\"")[0]
var parser = PathParser(path: d)
let lockPath = parser.parse()

// 锁形在 SVG 坐标系中的包围盒（y 已翻转到 CG 系）
let bbox = lockPath.boundingBox
print("锁形包围盒: \(bbox)")

// MARK: 1) App 图标 1024：蓝色渐变圆角矩形 + 白色锁
let size = 1024
let ctx = makeContext(size: size)
// 翻转坐标系：SVG y 向下 → CG y 向上
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)
ctx.setShouldAntialias(true)

// 圆角矩形底板（macOS 现代风格，占满画布）
let radius: CGFloat = 230
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let rounded = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(rounded)
ctx.clip()

// 对角渐变：左上亮蓝 → 右下深蓝
let colors = [
    CGColor(red: 0.36, green: 0.55, blue: 1.00, alpha: 1),
    CGColor(red: 0.16, green: 0.33, blue: 0.86, alpha: 1),
] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])

// 白色锁：放大到画布 62% 并居中（垂直方向略偏上，视觉平衡）
let targetW = CGFloat(size) * 0.62
let scale = targetW / bbox.width
let scaledW = bbox.width * scale, scaledH = bbox.height * scale
let tx = (CGFloat(size) - scaledW) / 2 - bbox.minX * scale
let ty = (CGFloat(size) - scaledH) / 2 - bbox.minY * scale
var t = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
let scaled = lockPath.copy(using: &t)!

// 柔和投影增加立体感
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36,
              color: CGColor(red: 0, green: 0, blue: 0.25, alpha: 0.35))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.addPath(scaled)
ctx.fillPath()
ctx.restoreGState()
ctx.resetClip()
savePNG(ctx, outDir.appendingPathComponent("icon_1024.png"))
print("✓ icon_1024.png")

// MARK: 2) 菜单栏模板图标 72px：黑色锁（透明背景，代码里设 isTemplate）
let msize = 72
let mctx = makeContext(size: msize)
mctx.translateBy(x: 0, y: CGFloat(msize))
mctx.scaleBy(x: 1, y: -1)
mctx.setShouldAntialias(true)
let mscale = CGFloat(msize - 8) / max(bbox.width, bbox.height)
let msW = bbox.width * mscale, msH = bbox.height * mscale
var mt = CGAffineTransform(translationX: (CGFloat(msize) - msW) / 2 - bbox.minX * mscale,
                           y: (CGFloat(msize) - msH) / 2 - bbox.minY * mscale)
    .scaledBy(x: mscale, y: mscale)
mctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
mctx.addPath(lockPath.copy(using: &mt)!)
mctx.fillPath()
savePNG(mctx, outDir.appendingPathComponent("LockTemplate.png"))
print("✓ LockTemplate.png")
