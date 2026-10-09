import SwiftUI

let eraserSizes = [4.0, 9.0, 18.0]
let textSizes = [12.0, 18.0, 28.0]
let tapeColors = [RGB(0.96, 0.82, 0.36), RGB(0.55, 0.8, 0.95), RGB(0.95, 0.6, 0.65), RGB(0.6, 0.85, 0.6), RGB(0.72, 0.72, 0.76)]
let tapeWidths = [10.0, 16.0, 26.0]
let noteColors = [RGB(1.0, 0.93, 0.55), RGB(1.0, 0.8, 0.86), RGB(0.75, 0.9, 1.0), RGB(0.8, 0.95, 0.75)]
let palette = [RGB(0, 0, 0), RGB(0.37, 0.37, 0.37), RGB(0.6, 0.6, 0.6), RGB(0.82, 0.82, 0.82), RGB(1, 1, 1),
               RGB(1.0, 0.1, 0.1), RGB(0.53, 0.18, 0.57), RGB(0.95, 0.33, 0.33), RGB(1.0, 0.6, 0.6), RGB(0.97, 0.58, 0.11),
               RGB(0.04, 0.47, 1.0), RGB(0.05, 0.29, 0.56), RGB(0.03, 0.62, 0.36), RGB(0.49, 0.76, 0.22), RGB(1.0, 1.0, 0.5)]
// (id, icon, name): the desktop app's tools, in its order, with its icons.
let toolList: [(String, String, String)] = [
    ("lasso", "lasso", "套索"), ("pen", "pen", "笔"), ("eraser", "eraser", "橡皮擦"), ("hl", "highlighter", "荧光笔"),
    ("shape", "shapes", "形状"), ("text", "text", "文本"), ("note", "note", "便签"), ("tape", "tape", "胶带"),
    ("laser", "laser", "激光笔"),
]
let laserColors = [RGB(1.0, 0.16, 0.2), RGB(0.1, 0.8, 0.3), RGB(0.16, 0.5, 1.0)]
let penList: [(String, String, String)] = [("fountain", "fountain", "钢笔"), ("ball", "ball", "圆珠笔"), ("brush", "brush", "画笔")]
let shapeList: [(String, String, String)] = [("line", "shape_line", "直线"), ("arrow", "shape_arrow", "箭头"),
                                             ("rect", "shape_rect", "矩形"), ("ellipse", "shape_ellipse", "椭圆")]

struct PenSetting: Codable, Equatable {
    var widths: [Double]
    var slot = 1
    var sens = 50.0   // pressure sensitivity in percent
    var stab = 0.0    // stabilisation in percent
    var dash = 0
}

/// Tool and app preferences, the same set as the desktop app's settings.json.
struct Prefs: Codable, Equatable {
    var penType = "fountain"
    var pens: [String: PenSetting] = [
        "fountain": PenSetting(widths: [0.9, 1.6, 2.8]),
        "ball": PenSetting(widths: [0.7, 1.2, 2.0]),
        "brush": PenSetting(widths: [1.4, 2.4, 3.8]),
    ]
    var penColors: [[Double]] = [[0.29, 0.62, 0.96], [0.66, 0.11, 0.94], [0.94, 0.24, 0.24], [0.49, 0.76, 0.19], [0.0, 0.0, 0.0], [1.0, 0.6, 0.12]]
    var penColor = 4
    var hlColors: [[Double]] = [[1.0, 0.88, 0.3], [0.56, 0.89, 0.41], [1.0, 0.54, 0.82], [0.49, 0.77, 1.0], [1.0, 0.7, 0.28]]
    var hlColor = 0
    var hlW = 1
    var hlWidths = [8.0, 14.0, 22.0]
    var noteColor = 0
    var tapeColor = 0
    var tapeW = 1
    var eraserSize = 1
    var eraserMode = "standard"
    var lassoRect = false
    var eraseFilter = ["pen", "hl", "shape"]
    var lassoFilter = ["ink", "image", "shape", "text"]
    var addPos = "after"   // where a new page goes: before, after, last
    var eraserAuto = false   // go back to the previous tool after one erasure
    var theme = "system"
    var language = "auto"
    var scrollbars = true
    var maxZoom = 6.0
    var hiddenTools: [String] = []
    var paging = "vertical"  // or horizontal: one page at a time, side by side
    var palmMs = 80.0        // fingers are ignored this long after the pencil lifts
    var laserMode = "trail"  // or dot: a spot that follows the pen
    var laserColor = 0
    var mouseHand = true     // once a pencil has been used, a mouse moves the page instead of drawing
    var crosshair = true     // the mark under a hovering pencil or pointer: a cross, or only its centre
    var inputLog = false
    var recent: [String] = []  // the notebooks opened last, newest first, as paths inside the library
    var lastFolder = ""      // the folder the library was left in, relative to its root
    var views: [String: [Double]] = [:]   // notebook id -> where it was being looked at: zoom, page, x, y
    var viewOrder: [String] = []          // the same ids, the one opened longest ago first
    var shapeKind = "line"
    var textSize = 1
    var holdShape = true
    var scribbleErase = true
    var fingerDraw = false
    var pencilDoubleTap = true
    var pencilSqueeze = true   // squeezing an Apple Pencil Pro brings the tools up around its tip
    var template: [Double] = [595, 842]
    var templatePaper = "blank"
    var templateColor: [Double] = [1, 1, 1]
    var sort = "date"
    var lastPages: [String: Int] = [:]   // notebook id -> the page it was left on

    init() {
        #if targetEnvironment(simulator)
        fingerDraw = true
        #endif
        // There is no pencil for an iPhone: a finger is what writes there, and two move the page.
        if UIDevice.current.userInterfaceIdiom == .phone { fingerDraw = true }
    }
}

final class ToolState: ObservableObject {
    static let shared = ToolState()
    private static let key = "prefs.v1"

    @Published var tool = "pen"
    @Published var p: Prefs {
        didSet {
            if p != oldValue, let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: Self.key) }
        }
    }

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetPrefs") { UserDefaults.standard.removeObject(forKey: Self.key) }
        #endif
        // Saved values are laid over the defaults, so that a setting added later does not
        // throw the saved ones away.
        var merged = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Prefs()))) as? [String: Any] ?? [:]
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            merged.merge(saved) { _, new in new }
        }
        if let data = try? JSONSerialization.data(withJSONObject: merged), let prefs = try? JSONDecoder().decode(Prefs.self, from: data) {
            p = prefs
        } else {
            p = Prefs()
        }
    }

    var pen: PenSetting {
        get { p.pens[p.penType] ?? PenSetting(widths: [0.9, 1.6, 2.8]) }
        set { p.pens[p.penType] = newValue }
    }

    var penWidth: Double { pen.widths[min(max(pen.slot, 0), pen.widths.count - 1)] }
    /// The slider's 100 % is the response that used to be its 50 %: more than that made the
    /// line of a pressure-sensitive pencil swing too far.
    var penSens: Double { pen.sens / 100 }
    var penStab: Double { pen.stab / 100 }
    var penColor: RGB { RGB(p.penColors[min(max(p.penColor, 0), p.penColors.count - 1)]) }
    var hlColor: RGB { RGB(p.hlColors[min(max(p.hlColor, 0), p.hlColors.count - 1)]) }
    var hlWidth: Double { p.hlWidths[min(max(p.hlW, 0), p.hlWidths.count - 1)] }
    var eraserR: Double { eraserSizes[min(max(p.eraserSize, 0), 2)] }
    var textSize: Double { textSizes[min(max(p.textSize, 0), 2)] }
    var noteColor: RGB { noteColors[p.noteColor % noteColors.count] }
    var tapeColor: RGB { tapeColors[p.tapeColor % tapeColors.count] }
    var tapeWidth: Double { tapeWidths[p.tapeW % tapeWidths.count] }
    var laserColor: RGB { laserColors[max(0, p.laserColor) % laserColors.count] }

    /// Remember where a notebook was being looked at; the 300 opened last are kept.
    func remember(view memo: [Double], of id: String) {
        var order = p.viewOrder.filter { $0 != id } + [id]
        var views = p.views
        views[id] = memo
        while order.count > 300 { views[order.removeFirst()] = nil }
        p.views = views
        p.viewOrder = order
    }

    var template: PageTemplate {
        get { PageTemplate(w: p.template[0], h: p.template[1], paper: p.templatePaper, color: RGB(p.templateColor)) }
        set {
            p.template = [newValue.w, newValue.h]
            p.templatePaper = newValue.paper
            p.templateColor = newValue.color.list
        }
    }
}

extension RGB {
    var color: Color { Color(red: r, green: g, blue: b) }

    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(Double(max(0, min(1, r))), Double(max(0, min(1, g))), Double(max(0, min(1, b))))
    }
}
