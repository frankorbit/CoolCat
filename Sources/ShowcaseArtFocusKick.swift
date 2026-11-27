import AppKit
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - Focus & Kick Showcase

/// README 配图：番茄钟（趴在窗口上陪你专注、到点举牌）和踢飞文件（Finder 右键、一脚踢飞）
extension ShowcaseArt {
    private struct Panel {
        var rect: CGRect
        var title: String
        var subtitle: String
        var colors: (NSColor, NSColor)
    }

    /// 一个文件图标画在哪：中心（画布 y 向下）、边长、角度（顺时针为正）、透明度
    private struct IconPlacement {
        var center: CGPoint
        var size: CGFloat
        var angle: CGFloat = 0
        var alpha: CGFloat = 1
    }

    /// 两块并排的圆角面板：标题、说明、地面线
    private static func drawPanels(_ panels: [Panel], in ctx: CGContext) {
        for panel in panels {
            fillGradient(panel.rect, radius: 18, colors: panel.colors, in: ctx)
            text(panel.title, at: CGPoint(x: panel.rect.minX + 22, y: panel.rect.minY + 18), size: 20,
                 weight: .heavy, color: rgb(0x1D1D24), in: ctx)
            text(panel.subtitle, at: CGPoint(x: panel.rect.minX + 22, y: panel.rect.minY + 50), size: 13,
                 weight: .regular, color: rgb(0x6B6E78), in: ctx, maxWidth: panel.rect.width - 44)
            let floorY = panel.rect.maxY - 30
            ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.12).cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: panel.rect.minX + 18, y: floorY))
            ctx.addLine(to: CGPoint(x: panel.rect.maxX - 18, y: floorY))
            ctx.strokePath()
        }
    }

    private static func useSiamese() {
        PetLibrary.shared.select(nil)
        CatSettings.shared.coatTheme = .siamese
        CatSettings.shared.eyeTheme = .siameseBlue
    }

    // MARK: Focus

    /// 番茄钟配图：左边蜷在你的窗口顶上睡、鼻尖前摆着番茄计时器，菜单栏有倒计时；右边到点举牌叫你休息
    static func renderFocus(english: Bool) -> CGImage? {
        let width: CGFloat = 1280, height: CGFloat = 460
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        CatSettings.shared.accessory = .none
        ctx.setFillColor(rgb(0xFAFAFC).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let panels = [
            Panel(rect: CGRect(x: 40, y: 40, width: 590, height: 380),
                  title: english ? "Naps on your window while you focus" : "趴在你的窗口上陪你专注",
                  subtitle:
                english ? "Start a pomodoro from the menu: it curls up atop your front window, the tomato dial "
                    + "shows what's left, and typing won't wake it"
                    : "菜单里开一个番茄：小猫蜷在你最前面的窗口顶上睡，番茄表盘是还剩的时间，你打字它也不醒",
                  colors: (rgb(0xFFF1E6), rgb(0xFFE8EE))),
            Panel(rect: CGRect(x: 650, y: 40, width: 590, height: 380),
                  title: english ? "Time's up: a sign says take a break" : "到点举牌叫你休息",
                  subtitle: english ? "It wakes up and holds a sign on your window; every 4th pomodoro earns a "
                    + "15-minute break" : "醒过来在你的窗口上举牌；每完成 4 个番茄，休息变成 15 分钟",
                  colors: (rgb(0xE8F1FF), rgb(0xF3E8FF)))
        ]
        drawPanels(panels, in: ctx)
        useSiamese()
        // 左：编辑器窗口顶上蜷着睡，菜单栏一角是倒计时
        let left = panels[0].rect
        let editor = CGRect(x: left.minX + 60, y: left.maxY - 150, width: 470, height: 120)
        drawFakeWindow(editor, title: english ? "Code Editor" : "代码编辑器", in: ctx)
        drawWalker(.init(pose: .curl, phase: 0, facing: 1, air: 0, time: 1.2, blink: false, curl: 1, asleep: true,
                         focusLeft: 0.62),
                   feet: CGPoint(x: editor.midX - 40, y: editor.minY), k: 0.95, alpha: 1, in: ctx)
        drawMenuBarCountdown(right: left.maxX - 24, top: left.minY + 92, in: ctx)
        // 右：到点举牌
        let right = panels[1].rect
        let browser = CGRect(x: right.minX + 70, y: right.maxY - 130, width: 450, height: 100)
        drawFakeWindow(browser, title: english ? "Browser" : "浏览器", in: ctx)
        let lines = english ? ["🍅 Pomodoro #3 done", "Stretch for 5 minutes"]
            : ["🍅 第 3 个番茄完成", "起来活动 5 分钟吧"]
        drawWalker(.init(pose: .sign, phase: 0, facing: 1, air: 0, time: 0.4, blink: false, signLines: lines),
                   feet: CGPoint(x: browser.midX - 20, y: browser.minY), k: 0.9, alpha: 1, in: ctx)
        return ctx.makeImage()
    }

    /// 一小截菜单栏：小猫图标右边是倒计时
    private static func drawMenuBarCountdown(right: CGFloat, top: CGFloat, in ctx: CGContext) {
        let bar = CGRect(x: right - 150, y: top, width: 150, height: 28)
        ctx.saveGState()
        let shadow = NSColor(calibratedWhite: 0, alpha: 0.12).cgColor
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: shadow)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.92).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        text("🔋  📶  🐱", at: CGPoint(x: bar.minX + 12, y: bar.minY + 5), size: 13, weight: .regular,
             color: rgb(0x1D1D24), in: ctx)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let clock = NSAttributedString(string: "15:32", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: rgb(0x1D1D24)
        ])
        clock.draw(at: CGPoint(x: bar.maxX - 50, y: bar.minY + 5))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Kick

    /// 踢飞文件配图：左边 Finder 里右键文件选「CoolCat 小猫踢飞」；右边小猫一脚把它踢飞，转着圈飞出去
    static func renderKick(english: Bool) -> CGImage? {
        let width: CGFloat = 1280, height: CGFloat = 460
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        CatSettings.shared.accessory = .none
        ctx.setFillColor(rgb(0xFAFAFC).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let panels = [
            Panel(rect: CGRect(x: 40, y: 40, width: 520, height: 380),
                  title: english ? "Right-click a file in Finder" : "Finder 里右键文件",
                  subtitle: english ? "Services → “CoolCat 小猫踢飞（移到废纸篓）” (\"kick away, move to Trash\")"
                    : "快速操作 / 服务 →「CoolCat 小猫踢飞（移到废纸篓）」",
                  colors: (rgb(0xE8F1FF), rgb(0xF3E8FF))),
            Panel(rect: CGRect(x: 580, y: 40, width: 660, height: 380),
                  title: english ? "…and it gets kicked off the screen" : "小猫跑过去，一脚踢飞",
                  subtitle: english ? "The file drops from its spot and gets kicked away at a random angle; it's in "
                    + "the Trash, so you can put it back"
                    : "文件从原来的地方掉下来，小猫起脚按随机角度踢飞；文件在废纸篓里，还能放回原处",
                  colors: (rgb(0xFFF1E6), rgb(0xFFE8EE)))
        ]
        drawPanels(panels, in: ctx)
        let icon = NSWorkspace.shared.icon(for: .plainText)
        // 左：桌面上的文件 + 右键菜单
        let left = panels[0].rect
        let fileName = english ? "draft.txt" : "旧草稿.txt"
        let fileSpot = CGPoint(x: left.minX + 90, y: left.minY + 150)
        drawFileIcon(icon, at: IconPlacement(center: fileSpot, size: 64), in: ctx)
        drawFileLabel(fileName, center: CGPoint(x: fileSpot.x, y: fileSpot.y + 38), in: ctx)
        drawContextMenu(origin: CGPoint(x: fileSpot.x + 30, y: fileSpot.y - 8), english: english, in: ctx)
        // 右：一脚踢飞
        let right = panels[1].rect
        let floorY = right.maxY - 30
        useSiamese()
        let catX = right.minX + 170
        drawWalker(.init(pose: .kick, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, kickTime: 0.95,
                         kickAngle: 0.75),
                   feet: CGPoint(x: catX, y: floorY), k: 1.05, alpha: 1, in: ctx)
        drawKickFlight(icon, from: CGPoint(x: catX + 78, y: floorY - 34), in: ctx)
        PetLibrary.shared.select(nil)
        return ctx.makeImage()
    }

    /// 被踢飞的文件：虚线弧线 + 几道越来越淡的残影 + 越飞越小、转着圈的图标
    private static func drawKickFlight(_ icon: NSImage, from start: CGPoint, in ctx: CGContext) {
        let control = CGPoint(x: start.x + 150, y: start.y - 190)
        let end = CGPoint(x: start.x + 420, y: start.y - 165)
        func point(_ along: CGFloat) -> CGPoint {
            let rest = 1 - along
            return CGPoint(x: rest * rest * start.x + 2 * rest * along * control.x + along * along * end.x,
                           y: rest * rest * start.y + 2 * rest * along * control.y + along * along * end.y)
        }
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        ctx.saveGState()
        ctx.setStrokeColor(rgb(0xA6ABBA).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [2, 7])
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
        for (along, alpha) in [(0.42 as CGFloat, 0.12 as CGFloat), (0.52, 0.22), (0.62, 0.36)] {
            drawFileIcon(icon, at: IconPlacement(center: point(along), size: 60 * (1 - along * 0.35),
                                                 angle: along * 4.2, alpha: alpha), in: ctx)
        }
        drawFileIcon(icon, at: IconPlacement(center: point(0.74), size: 60 * (1 - 0.74 * 0.35), angle: 0.74 * 4.2),
                     in: ctx)
    }

    private static func drawFileIcon(_ icon: NSImage, at place: IconPlacement, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: place.center.x, y: place.center.y)
        ctx.rotate(by: place.angle)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let half = place.size / 2
        icon.draw(in: CGRect(x: -half, y: -half, width: place.size, height: place.size), from: .zero,
                  operation: .sourceOver, fraction: place.alpha, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    /// 桌面图标下面的文件名
    private static func drawFileLabel(_ name: String, center: CGPoint, in ctx: CGContext) {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let labelWidth = (name as NSString).size(withAttributes: [.font: font]).width
        text(name, at: CGPoint(x: center.x - labelWidth / 2, y: center.y), size: 12, weight: .medium,
             color: rgb(0x1D1D24), in: ctx)
    }

    /// 简化的右键菜单：最后一项「服务」展开，CoolCat 那一项高亮
    private static func drawContextMenu(origin: CGPoint, english: Bool, in ctx: CGContext) {
        let items = english ? ["Open", "Get Info", "Rename", "-", "Copy", "Share…", "-", "Services"]
            : ["打开", "显示简介", "重新命名", "-", "拷贝", "共享…", "-", "服务"]
        let menu = CGRect(x: origin.x, y: origin.y, width: 150, height: 172)
        drawMenuBackground(menu, in: ctx)
        var rowY = menu.minY + 8
        var servicesRow = rowY
        for item in items {
            if item == "-" {
                ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.1).cgColor)
                ctx.fill(CGRect(x: menu.minX + 10, y: rowY + 5, width: menu.width - 20, height: 1))
                rowY += 11
                continue
            }
            let isServices = item == items.last
            if isServices {
                servicesRow = rowY
                ctx.addPath(CGPath(roundedRect: CGRect(x: menu.minX + 5, y: rowY, width: menu.width - 10, height: 22),
                                   cornerWidth: 5, cornerHeight: 5, transform: nil))
                ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.08).cgColor)
                ctx.fillPath()
                text("›", at: CGPoint(x: menu.maxX - 20, y: rowY + 2), size: 13, weight: .semibold,
                     color: rgb(0x6B6E78), in: ctx)
            }
            text(item, at: CGPoint(x: menu.minX + 14, y: rowY + 3), size: 13, weight: .regular, color: rgb(0x1D1D24),
                 in: ctx)
            rowY += 22
        }
        // 「服务」子菜单：CoolCat 那一项高亮
        // 菜单项只有中文名（Info.plist 的 NSServices），英文系统里看到的也是它
        let title = "CoolCat 小猫踢飞（移到废纸篓）"
        let sub = CGRect(x: menu.maxX - 4, y: servicesRow - 8, width: english ? 236 : 222, height: 60)
        drawMenuBackground(sub, in: ctx)
        text(english ? "New Terminal at Folder" : "新建位于文件夹位置的终端窗口",
             at: CGPoint(x: sub.minX + 14, y: sub.minY + 11), size: 13, weight: .regular, color: rgb(0x1D1D24), in: ctx)
        let highlight = CGRect(x: sub.minX + 5, y: sub.minY + 31, width: sub.width - 10, height: 22)
        ctx.addPath(CGPath(roundedRect: highlight, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.setFillColor(rgb(0x2F7BF6).cgColor)
        ctx.fillPath()
        text(title, at: CGPoint(x: highlight.minX + 9, y: highlight.minY + 3), size: 13, weight: .medium,
             color: .white, in: ctx)
    }

    private static func drawMenuBackground(_ rect: CGRect, in ctx: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.saveGState()
        let shadow = NSColor(calibratedWhite: 0, alpha: 0.2).cgColor
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: shadow)
        ctx.addPath(path)
        ctx.setFillColor(NSColor(calibratedWhite: 0.985, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.08).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }
}
