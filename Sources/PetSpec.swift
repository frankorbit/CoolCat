import AppKit

// MARK: - Pet Spec

/// 一只猫的外观数据：配色 + 形状参数。渲染时借用一只内置猫的画法（style.baseCoat），再按这里的数据重新上色、调形状。
/// 内置的新猫和以后用户自定义的猫都用这个格式（Codable，可存成 JSON）。
struct PetSpec: Codable, Equatable, Identifiable {
    /// 借用哪只内置猫的画法
    enum Style: String, Codable, CaseIterable {
        /// 纯色（借小黑猫）
        case solid
        /// 虎斑 + 白肚皮（借美短）
        case tabby
        /// 白底 + 色块（借橘白）
        case bicolor
        /// 浅色身体 + 深色脸/耳/爪/尾（借暹罗）
        case colorpoint

        var baseCoat: CatCoatTheme {
            switch self {
            case .solid: return .classicBlack
            case .tabby: return .shorthair
            case .bicolor: return .orangeWhite
            case .colorpoint: return .siamese
            }
        }
    }

    enum HeadShape: String, Codable {
        /// 圆脸（大多数猫）
        case round
        /// 楔形 / 倒三角（德文、东方短毛）：头顶平、颧骨宽、小尖下巴
        case wedge
    }

    enum EarStyle: String, Codable {
        /// 普通立耳
        case pointed
        /// 折耳（苏格兰折耳）
        case folded
        /// 小圆耳
        case round
        /// 垂耳（狗、垂耳兔）
        case floppy
    }

    struct Shape: Codable, Equatable {
        var earStyle: EarStyle = .pointed
        /// 耳朵大小系数
        var earSize: Double = 1
        /// 身体宽度系数（胖瘦）
        var bodyWidth: Double = 1
        /// 尾巴粗细系数
        var tailWidth: Double = 1
        /// 脸宽系数（胖脸猫两颊更鼓）
        var headWidth: Double = 1
        /// 长毛：两颊蓬毛
        var fluffy = false
        /// 耳朵向外撇的角度（弧度）：德文卷毛那种招风耳
        var earFlare: Double = 0
        /// 眼睛大小系数
        var eyeScale: Double = 1
        /// 卷胡须（德文、柯尼斯卷毛猫）
        var curlyWhiskers = false
        /// 身上的卷毛纹理
        var wavyCoat = false
        /// 头部大小系数（整颗头连同五官、耳朵等比缩放）
        var headSize: Double = 1
        /// 腿粗细系数（伸出去打字、拿鼠标时的前腿）
        var limbWidth: Double = 1
        var headShape: HeadShape = .round
    }

    let id: String
    var name: String
    var style: Style
    /// 主色：纯色的毛色 / 虎斑的底色 / 双色的色块 / 重点色的脸耳爪尾
    var main: String
    /// 副色：虎斑和双色的白肚皮 / 重点色的身体
    var secondary: String
    /// 点缀色：虎斑条纹、色块上的花纹
    var accent: String
    var eye: String
    /// 鸳鸯眼：左眼的颜色（nil = 两只眼一样）
    var eye2: String?
    var shape = Shape()
    /// 三花：双色基础上再加黑色色块（只对 bicolor 生效）
    var tricolor: Bool?
    /// 大白脸：白斑从额头一道细线往下张开，盖住两眼之间和整个下半张脸（黑白德文、奶牛猫那种）
    var whiteFace: Bool?
    /// 白腿：伸出去的前腿整条用副色（白），不画深色腿
    var whiteLegs: Bool?

    var mainColor: NSColor { HexColor.color(main) }
    var secondaryColor: NSColor { HexColor.color(secondary) }
    var accentColor: NSColor { HexColor.color(accent) }
    var eyeColor: NSColor { HexColor.color(eye) }
    var secondEyeColor: NSColor? { eye2.map(HexColor.color) }
}

// MARK: - Color Helpers

enum HexColor {
    /// "#RRGGBB" / "RRGGBB" → NSColor；格式不对返回品红，一眼能看出配置写错了
    static func color(_ hex: String) -> NSColor {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return .magenta }
        return NSColor(calibratedRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    /// 线性混色：t = 0 → a，t = 1 → b
    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat, alpha: CGFloat = 1) -> NSColor {
        let ca = a.usingColorSpace(.deviceRGB) ?? a, cb = b.usingColorSpace(.deviceRGB) ?? b
        func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return NSColor(calibratedRed: lerp(ca.redComponent, cb.redComponent),
                       green: lerp(ca.greenComponent, cb.greenComponent),
                       blue: lerp(ca.blueComponent, cb.blueComponent), alpha: alpha)
    }

    /// 相对亮度（0 黑 … 1 白）：决定描线、胡须用深色还是浅色
    static func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}

// MARK: - Library

/// 可选的猫：内置的 4 只经典猫（不走 PetSpec，画面和以前逐像素一致）+ 内置新猫（PetSpec 预设）。
final class PetLibrary {
    static let shared = PetLibrary()

    static let builtIns: [PetSpec] = [
        PetSpec(id: "orange-tabby", name: "大橘", style: .tabby,
                main: "#E9A15B", secondary: "#FBF3E6", accent: "#C0702F", eye: "#7BC96F",
                shape: .init(bodyWidth: 1.14, tailWidth: 1.1, headWidth: 1.1)),
        PetSpec(id: "dragon-li", name: "狸花猫", style: .tabby,
                main: "#9C8A6E", secondary: "#EFE6D6", accent: "#3E352B", eye: "#C9D85A",
                shape: .init(earSize: 1.1, headWidth: 0.96)),
        PetSpec(id: "tuxedo", name: "奶牛猫", style: .bicolor,
                main: "#232326", secondary: "#F7F5F0", accent: "#232326", eye: "#E9C84A"),
        PetSpec(id: "calico", name: "三花", style: .bicolor,
                main: "#E39A4F", secondary: "#FAF6EE", accent: "#2E2A28", eye: "#D9A43B", tricolor: true),
        PetSpec(id: "british-blue", name: "英短蓝猫", style: .solid,
                main: "#8C97A6", secondary: "#A9B2BE", accent: "#6E7887", eye: "#E8A13A",
                shape: .init(earSize: 0.8, bodyWidth: 1.12, headWidth: 1.16)),
        PetSpec(id: "scottish-fold", name: "折耳猫", style: .tabby,
                main: "#C9CDD3", secondary: "#F6F4F0", accent: "#6F747C", eye: "#E2B04A",
                shape: .init(earStyle: .folded, headWidth: 1.08)),
        PetSpec(id: "ragdoll", name: "布偶猫", style: .colorpoint,
                main: "#7E7280", secondary: "#F7F2EC", accent: "#5E5463", eye: "#5FA8F0",
                shape: .init(bodyWidth: 1.06, tailWidth: 1.12)),
        PetSpec(id: "white", name: "小白", style: .solid,
                main: "#F4F1EB", secondary: "#FFFFFF", accent: "#D9D3C9", eye: "#7FC4F2", eye2: "#E8B64A"),
        PetSpec(id: "golden", name: "金渐层", style: .solid,
                main: "#DDB070", secondary: "#F1D9A8", accent: "#B98A4C", eye: "#6FB86A",
                shape: .init(earSize: 0.9, bodyWidth: 1.08, headWidth: 1.06, fluffy: true)),
        // 德文卷毛（黑白）：黑头顶黑耳朵、大白脸、深蓝灰大眼睛、超大招风耳、卷胡须、身上小卷毛
        PetSpec(id: "devon-rex", name: "德文卷毛", style: .bicolor,
                main: "#2A2527", secondary: "#FBF8F4", accent: "#2A2527", eye: "#4C6787",
                shape: .init(earSize: 1.65, bodyWidth: 0.64, tailWidth: 0.78, headWidth: 1.0,
                             earFlare: 0.62, eyeScale: 0.94, curlyWhiskers: true, wavyCoat: true, headSize: 0.84, limbWidth: 0.68, headShape: .wedge),
                whiteFace: true, whiteLegs: true)
    ]

    private init() {}

    var all: [PetSpec] { Self.builtIns }

    func pet(id: String) -> PetSpec? { all.first { $0.id == id } }

    /// 当前选中的 PetSpec 猫；选的是经典猫时为 nil
    var active: PetSpec? {
        guard let id = CatSettings.shared.customPetID else { return nil }
        if let cached = activeCache, cached.id == id { return cached }
        activeCache = pet(id: id)
        return activeCache
    }

    private var activeCache: PetSpec?

    /// 切换到某只猫：PetSpec 猫同时把 coatTheme 切到它借用的那只（渲染器靠这个选画法）
    func select(_ pet: PetSpec?) {
        let settings = CatSettings.shared
        if let pet {
            settings.coatTheme = pet.style.baseCoat
            settings.customPetID = pet.id
        } else {
            settings.customPetID = nil
        }
    }
}
