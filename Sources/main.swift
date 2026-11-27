import Foundation
import AppKit
import SwiftUI

// Claude Code / Codex hook 中继：必须最先处理，读完 stdin 立即退出，不启动任何 UI
if CommandLine.arguments.contains(ClaudeHookRelay.argument) {
    ClaudeHookRelay.run(agent: .claude)
}
if CommandLine.arguments.contains(ClaudeHookRelay.codexArgument) {
    ClaudeHookRelay.run(agent: .codex)
}

// 命令行安装/卸载 hook（和设置面板里的按钮走同一套逻辑，方便脚本化）：
// --install-claude-hooks / --uninstall-claude-hooks / --install-codex-hooks / --uninstall-codex-hooks
for agent in CodingAgent.allCases {
    let install = "--install-\(agent.rawValue)-hooks", uninstall = "--uninstall-\(agent.rawValue)-hooks"
    guard CommandLine.arguments.contains(install) || CommandLine.arguments.contains(uninstall) else { continue }
    let installer = AgentHookInstaller.installer(for: agent)
    let installing = CommandLine.arguments.contains(install)
    do {
        if installing { try installer.install() } else { try installer.uninstall() }
        print(installing ? "已连接 \(agent.displayName)：\(installer.hookCommand)" : "已移除 CoolCat 的 \(agent.displayName) hook")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// Support headless multi-pose preview rendering for visual verification
if let idx = CommandLine.arguments.firstIndex(of: "--render-preview"),
   idx + 1 < CommandLine.arguments.count {
    let outPath = CommandLine.arguments[idx + 1]
    renderPreviewSheet(to: outPath, forceSiamese: false)
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--render-siamese-preview"),
   idx + 1 < CommandLine.arguments.count {
    let outPath = CommandLine.arguments[idx + 1]
    renderPreviewSheet(to: outPath, forceSiamese: true)
    exit(0)
}

// Support headless Live-style animated frame sequence export (for GIF & MP4 generation)
if let idx = CommandLine.arguments.firstIndex(of: "--render-demos"),
   idx + 1 < CommandLine.arguments.count {
    let outDir = CommandLine.arguments[idx + 1]
    renderAllLiveDemos(to: outDir)
    exit(0)
}

// Support custom-background full feature showcase video (skin switch, typing, hunting boba eyes, petting, combo!)
if let idx = CommandLine.arguments.firstIndex(of: "--render-showcase-video"),
   idx + 2 < CommandLine.arguments.count {
    let bgPath = CommandLine.arguments[idx + 1]
    let outDir = CommandLine.arguments[idx + 2]
    renderCustomShowcaseVideo(bgPath: bgPath, outDir: outDir)
    exit(0)
}

// 听歌戴耳机多皮肤预览：4 皮肤 x 3 姿态（陶醉正脸 / 左转 / 右转打字）
if let idx = CommandLine.arguments.firstIndex(of: "--render-music-preview"),
   idx + 1 < CommandLine.arguments.count {
    renderMusicPreviewSheet(to: CommandLine.arguments[idx + 1])
    exit(0)
}

func renderMusicPreviewSheet(to path: String) {
    let settings = CatSettings.shared
    let saved = (settings.coatTheme, settings.eyeTheme, settings.keyboardTheme)
    defer { (settings.coatTheme, settings.eyeTheme, settings.keyboardTheme) = saved }

    let coats: [(CatCoatTheme, EyeColorTheme)] = [
        (.classicBlack, .neonChartreuse), (.siamese, .siameseBlue),
        (.shorthair, .referenceHazel), (.orangeWhite, .warmAmber)
    ]
    let poses: [(String, (CatPhysics) -> Void)] = [
        ("陶醉正脸", { p in
            p.setListening(true, musicApp: true)
            p.showTrack(title: "猫咪狂想曲", artist: "CoolCat")
            for _ in 0..<160 { p.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
            p.headYaw.value = 0; p.headPitch.value = 0.1; p.headTilt.value = 0.06
        }),
        ("左转看鼠标", { p in
            p.setListening(true, musicApp: true)
            for _ in 0..<90 { p.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 0)) }
            p.leftPaw.x.value = CatPhysics.mouseBaseCenter.x + 2
            p.leftPaw.y.value = CatPhysics.mouseBaseCenter.y - 3
            p.headYaw.value = -0.85; p.headPitch.value = -0.4; p.headTilt.value = -0.1
            p.eyeGaze.x.value = -0.7; p.eyeGaze.y.value = -0.4
        }),
        ("右转打字", { p in
            p.setListening(true, musicApp: false)
            for _ in 0..<90 { p.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 0)) }
            let ptL = KeyboardLayout.canvasPoint(for: .o)
            let ptR = KeyboardLayout.canvasPoint(for: .f)
            p.leftPaw.x.value = ptL.x; p.leftPaw.y.value = ptL.y
            p.rightPaw.x.value = ptR.x; p.rightPaw.y.value = ptR.y
            p.headYaw.value = 0.8; p.headPitch.value = 0.6; p.headTilt.value = 0.09
            p.eyeGaze.x.value = 0.65; p.eyeGaze.y.value = 0.6
        })
    ]

    let cellW = 360, cellH = 320, scale = 2
    let cols = poses.count, rows = coats.count
    guard let ctx = CGContext(
        data: nil, width: cellW * cols * scale, height: cellH * rows * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.translateBy(x: 0, y: CGFloat(cellH * rows * scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    ctx.setFillColor(NSColor(calibratedRed: 0.66, green: 0.70, blue: 0.68, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: cellW * cols, height: cellH * rows))

    for (row, coat) in coats.enumerated() {
        settings.coatTheme = coat.0
        settings.eyeTheme = coat.1
        for (col, pose) in poses.enumerated() {
            let physics = CatPhysics()
            pose.1(physics)
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(col * cellW), y: CGFloat(row * cellH))
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.25).cgColor)
            ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(cellW) - 1, height: CGFloat(cellH) - 1))
            CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: pose.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
            ]).draw(at: CGPoint(x: 10, y: 296))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
    }
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("写入预览失败: \(error)\n".utf8))
    }
}

// Claude Code 联动预览：4 皮肤 x 3 状态（思考中 / 等你批准 / 搞定）
if let idx = CommandLine.arguments.firstIndex(of: "--render-claude-preview"),
   idx + 1 < CommandLine.arguments.count {
    renderClaudePreviewSheet(to: CommandLine.arguments[idx + 1])
    exit(0)
}

func renderClaudePreviewSheet(to path: String) {
    let settings = CatSettings.shared
    let saved = (settings.coatTheme, settings.eyeTheme)
    defer { (settings.coatTheme, settings.eyeTheme) = saved }
    let coats: [(CatCoatTheme, EyeColorTheme)] = [
        (.classicBlack, .neonChartreuse), (.siamese, .siameseBlue),
        (.shorthair, .referenceHazel), (.orangeWhite, .warmAmber)
    ]
    let states: [(String, ClaudeStatus, Int)] = [
        ("思考中（写代码）", .working(tool: "Edit", sessions: 2), 60),
        ("等你批准", .waiting(.permission), 50),
        ("搞定！", .done, 24),
        ("5 个会话同时在忙", .working(tool: nil, sessions: 5), 60),
        ("Claude + Codex 一起干活", .working(tool: "Edit", sessions: 3), 60),
        ("Codex 等你批准", .waiting(.permission), 50)
    ]
    let cellW = 360, cellH = 320, scale = 2
    let cols = states.count, rows = coats.count
    guard let ctx = CGContext(
        data: nil, width: cellW * cols * scale, height: cellH * rows * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.translateBy(x: 0, y: CGFloat(cellH * rows * scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    ctx.setFillColor(NSColor(calibratedRed: 0.66, green: 0.70, blue: 0.68, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: cellW * cols, height: cellH * rows))

    for (row, coat) in coats.enumerated() {
        settings.coatTheme = coat.0
        settings.eyeTheme = coat.1
        for (col, state) in states.enumerated() {
            let physics = CatPhysics()
            // 先空跑 2 秒让"用户闲置"成立，再切状态并推进若干帧
            for _ in 0..<120 { physics.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
            physics.updateClaude(state.1)
            switch state.1 {
            case .working:
                physics.claudeLines = [
                    ClaudeSessionLine(project: "Faceplant", detail: "写代码", kind: .working, elapsed: 134),
                    ClaudeSessionLine(project: "CoolCat", detail: "跑命令", kind: .working, elapsed: 35)
                ]
            case .waiting:
                physics.claudeLines = [
                    ClaudeSessionLine(project: "CoolCat", detail: "等你批准", kind: .waiting, elapsed: nil),
                    ClaudeSessionLine(project: "Faceplant", detail: "读代码", kind: .working, elapsed: 252)
                ]
            case .done:
                physics.claudeLines = [ClaudeSessionLine(project: "Faceplant", detail: "搞定", kind: .done, elapsed: nil)]
            default:
                break
            }
            if case .working(_, let n) = state.1, n == 3 {
                physics.claudeLines = [
                    ClaudeSessionLine(project: "CoolCat", detail: "写代码", kind: .working, elapsed: 134),
                    ClaudeSessionLine(project: "api-server", detail: "跑命令", kind: .working, elapsed: 61, agent: .codex),
                    ClaudeSessionLine(project: "web", detail: "思考中", kind: .working, elapsed: 8, agent: .codex)
                ]
            }
            if state.0 == "Codex 等你批准" {
                physics.claudeLines = [
                    ClaudeSessionLine(project: "api-server", detail: "等你批准", kind: .waiting, elapsed: nil, agent: .codex),
                    ClaudeSessionLine(project: "CoolCat", detail: "读代码", kind: .working, elapsed: 252)
                ]
            }
            if case .working(_, let n) = state.1, n == 5 {
                physics.claudeLines = [
                    ClaudeSessionLine(project: "Faceplant", detail: "写代码", kind: .working, elapsed: 412),
                    ClaudeSessionLine(project: "CoolCat", detail: "跑命令", kind: .working, elapsed: 95),
                    ClaudeSessionLine(project: "api-server", detail: "翻文件", kind: .working, elapsed: 40),
                    ClaudeSessionLine(project: "infra", detail: "思考中", kind: .working, elapsed: 12),
                    ClaudeSessionLine(project: "docs", detail: "上网查", kind: .working, elapsed: 5)
                ]
            }
            for _ in 0..<state.2 { physics.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(col * cellW), y: CGFloat(row * cellH))
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.25).cgColor)
            ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(cellW) - 1, height: CGFloat(cellH) - 1))
            CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: state.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
            ]).draw(at: CGPoint(x: 10, y: 296))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
    }
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("写入预览失败: \(error)\n".utf8))
    }
}

// 会议模式预览：4 皮肤 x 3 状态（戴耳麦 / 嘘 / 洗脸）
if let idx = CommandLine.arguments.firstIndex(of: "--render-meeting-preview"),
   idx + 1 < CommandLine.arguments.count {
    renderMeetingPreviewSheet(to: CommandLine.arguments[idx + 1])
    exit(0)
}

func renderMeetingPreviewSheet(to path: String) {
    let settings = CatSettings.shared
    let saved = (settings.coatTheme, settings.eyeTheme, settings.meetingMode, settings.keyboardNoiseReminder)
    defer { (settings.coatTheme, settings.eyeTheme, settings.meetingMode, settings.keyboardNoiseReminder) = saved }
    settings.meetingMode = true
    settings.keyboardNoiseReminder = true
    let coats: [(CatCoatTheme, EyeColorTheme)] = [
        (.classicBlack, .neonChartreuse), (.siamese, .siameseBlue),
        (.shorthair, .referenceHazel), (.orangeWhite, .warmAmber)
    ]
    let poses: [(String, (CatPhysics) -> Void)] = [
        ("开麦戴耳麦", { p in
            p.setMeeting(mic: true, micApp: "腾讯会议", camera: false)
            for _ in 0..<60 { p.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
        }),
        ("打字太吵：嘘", { p in
            p.setMeeting(mic: true, micApp: nil, camera: false)
            for _ in 0..<40 { p.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
            for k in [PhysicalKey.j, .k, .l, .f, .d, .s, .a, .j, .k, .l] { p.triggerKeyDown(k) }
            for _ in 0..<45 { p.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
        }),
        ("开摄像头：洗脸", { p in
            p.setMeeting(mic: false, micApp: nil, camera: true)
            for _ in 0..<70 { p.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
        })
    ]
    let cellW = 360, cellH = 320, scale = 2
    let cols = poses.count, rows = coats.count
    guard let ctx = CGContext(
        data: nil, width: cellW * cols * scale, height: cellH * rows * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.translateBy(x: 0, y: CGFloat(cellH * rows * scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    ctx.setFillColor(NSColor(calibratedRed: 0.66, green: 0.70, blue: 0.68, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: cellW * cols, height: cellH * rows))
    for (row, coat) in coats.enumerated() {
        settings.coatTheme = coat.0
        settings.eyeTheme = coat.1
        for (col, pose) in poses.enumerated() {
            let physics = CatPhysics()
            pose.1(physics)
            physics.floatingKeycaps.removeAll()
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(col * cellW), y: CGFloat(row * cellH))
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.25).cgColor)
            ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(cellW) - 1, height: CGFloat(cellH) - 1))
            CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: pose.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
            ]).draw(at: CGPoint(x: 10, y: 296))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
    }
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("写入预览失败: \(error)\n".utf8))
    }
}

// 键盘习惯预览：4 皮肤 x 4 反应（狂删冒汗 / ⌘S 盖章 / 截图比耶 / KPM 皇冠）
if let idx = CommandLine.arguments.firstIndex(of: "--render-habits-preview"),
   idx + 1 < CommandLine.arguments.count {
    renderHabitsPreviewSheet(to: CommandLine.arguments[idx + 1])
    exit(0)
}

func renderHabitsPreviewSheet(to path: String) {
    let settings = CatSettings.shared
    let saved = (settings.coatTheme, settings.eyeTheme, settings.keyHabitReactions)
    defer { (settings.coatTheme, settings.eyeTheme, settings.keyHabitReactions) = saved }
    settings.keyHabitReactions = true
    let coats: [(CatCoatTheme, EyeColorTheme)] = [
        (.classicBlack, .neonChartreuse), (.siamese, .siameseBlue),
        (.shorthair, .referenceHazel), (.orangeWhite, .warmAmber)
    ]
    let poses: [(String, KeyHabitEvent, Int)] = [
        ("狂按退格：冒汗", .backspaceStorm, 40),
        ("⌘S：盖章", .save, 12),
        ("截图：比耶", .screenshot, 30),
        ("KPM 破纪录：皇冠", .newKPMRecord(312), 40)
    ]
    let cellW = 360, cellH = 320, scale = 2
    let cols = poses.count, rows = coats.count
    guard let ctx = CGContext(
        data: nil, width: cellW * cols * scale, height: cellH * rows * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.translateBy(x: 0, y: CGFloat(cellH * rows * scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    ctx.setFillColor(NSColor(calibratedRed: 0.66, green: 0.70, blue: 0.68, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: cellW * cols, height: cellH * rows))
    for (row, coat) in coats.enumerated() {
        settings.coatTheme = coat.0
        settings.eyeTheme = coat.1
        for (col, pose) in poses.enumerated() {
            let physics = CatPhysics()
            for _ in 0..<60 { physics.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
            if case .newKPMRecord = pose.1 { physics.react(to: .recordBurstStarted) }
            physics.react(to: pose.1)
            for _ in 0..<pose.2 { physics.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(col * cellW), y: CGFloat(row * cellH))
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.25).cgColor)
            ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(cellW) - 1, height: CGFloat(cellH) - 1))
            CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: pose.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
            ]).draw(at: CGPoint(x: 10, y: 296))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
    }
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("写入预览失败: \(error)\n".utf8))
    }
}

// 跳舞 + 空闲动作预览
if let idx = CommandLine.arguments.firstIndex(of: "--render-dance-preview"),
   idx + 1 < CommandLine.arguments.count {
    renderDancePreviewSheet(to: CommandLine.arguments[idx + 1])
    exit(0)
}

func renderDancePreviewSheet(to path: String) {
    let settings = CatSettings.shared
    let saved = (settings.coatTheme, settings.eyeTheme, settings.musicVisualizer, settings.musicDance, settings.idleAnimations)
    defer { (settings.coatTheme, settings.eyeTheme, settings.musicVisualizer, settings.musicDance, settings.idleAnimations) = saved }
    settings.musicVisualizer = true
    settings.musicDance = true
    settings.idleAnimations = true
    let coats: [(CatCoatTheme, EyeColorTheme)] = [
        (.classicBlack, .neonChartreuse), (.siamese, .siameseBlue),
        (.shorthair, .referenceHazel), (.orangeWhite, .warmAmber)
    ]
    enum Scene { case dance(DanceMove, CGFloat), idle(IdleAction, CGFloat) }
    // 每只猫两行：上排激烈歌的舞步，下排舒缓歌的舞步（空闲动作见 --render-idle 之前的版本，已单独验证）
    let scenes: [(String, Scene)] = [
        ("举爪蹦迪", .dance(.raiseTheRoof, 0.05)),
        ("左右摇摆", .dance(.sway, 0.45)),
        ("指挥家", .dance(.conductor, 0.3)),
        ("甩头", .dance(.headbang, 0.04)),
        ("舒缓·轻轻摇摆", .dance(.gentleSway, 1.0)),
        ("舒缓·梦游画圈", .dance(.dreamyCircle, 0.5)),
        ("舒缓·演唱会挥手", .dance(.concertWave, 1.0)),
        ("舒缓·摇椅", .dance(.rocking, 1.0))
    ]
    _ = Scene.idle(.yawn, 0)
    let cellW = 360, cellH = 320, scale = 2
    let cols = scenes.count / 2, rows = coats.count * 2
    guard let ctx = CGContext(
        data: nil, width: cellW * cols * scale, height: cellH * rows * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.translateBy(x: 0, y: CGFloat(cellH * rows * scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    ctx.setFillColor(NSColor(calibratedRed: 0.22, green: 0.23, blue: 0.27, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: cellW * cols, height: cellH * rows))
    for (coatIndex, coat) in coats.enumerated() {
        settings.coatTheme = coat.0
        settings.eyeTheme = coat.1
        for (sceneIndex, scene) in scenes.enumerated() {
            let physics = CatPhysics()
            switch scene.1 {
            case .dance(let move, let beatFraction):
                physics.setListening(true, musicApp: true)
                physics.debugArousal = move.isCalm ? 0.2 : 0.8
                // 先跑 3 秒让耳机戴好、进入跳舞，再强制舞步并停在拍内指定位置
                for _ in 0..<180 { physics.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
                physics.debugForceDance(move)
                let framesPerBeat = 60.0 * 60.0 / Double(physics.beatsPerMinute)
                let target = Int(framesPerBeat * 2 + framesPerBeat * Double(beatFraction))
                for _ in 0..<target { physics.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
            case .idle(let action, let age):
                physics.debugForceIdle(action, age: 0)
                for _ in 0..<Int(age * 60) { physics.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
            }
            physics.floatingKeycaps.removeAll()
            let col = sceneIndex % cols
            let row = coatIndex * 2 + sceneIndex / cols
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(col * cellW), y: CGFloat(row * cellH))
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.15).cgColor)
            ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(cellW) - 1, height: CGFloat(cellH) - 1))
            CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: scene.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
            ]).draw(at: CGPoint(x: 10, y: 296))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
    }
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("写入预览失败: \(error)\n".utf8))
    }
}

// 生活陪伴预览：4 皮肤 x 5 场景
if let idx = CommandLine.arguments.firstIndex(of: "--render-life-preview"),
   idx + 1 < CommandLine.arguments.count {
    renderLifePreviewSheet(to: CommandLine.arguments[idx + 1])
    exit(0)
}

func renderLifePreviewSheet(to path: String) {
    let settings = CatSettings.shared
    let saved = (settings.coatTheme, settings.eyeTheme, settings.lifeNight, settings.lifeBattery)
    defer { (settings.coatTheme, settings.eyeTheme, settings.lifeNight, settings.lifeBattery) = saved }
    settings.lifeNight = true
    settings.lifeBattery = true
    let coats: [(CatCoatTheme, EyeColorTheme)] = [
        (.classicBlack, .neonChartreuse), (.siamese, .siameseBlue),
        (.shorthair, .referenceHazel), (.orangeWhite, .warmAmber)
    ]
    let scenes: [(String, (CatPhysics) -> Int)] = [
        ("深夜：睡帽", { p in p.debugNight = true; return 60 }),
        ("早晨：捧着咖啡", { p in p.react(life: .morningCoffee); return 60 }),
        ("早晨：抿一口", { p in p.react(life: .morningCoffee); return Int(2.7 * 60) }),
        ("低电量：没精神", { p in p.debugBattery = BatteryStatus(percent: 9, onAC: false); return 120 }),
        ("插电：喝奶", { p in p.debugBattery = BatteryStatus(percent: 9, onAC: true); p.react(life: .pluggedIn); return 30 }),
        ("久坐：喝水", { p in p.react(life: .workBreak(minutes: 50)); return Int(2.7 * 60) })
    ]
    let cellW = 360, cellH = 320, scale = 2
    let cols = scenes.count, rows = coats.count
    guard let ctx = CGContext(
        data: nil, width: cellW * cols * scale, height: cellH * rows * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.translateBy(x: 0, y: CGFloat(cellH * rows * scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    ctx.setFillColor(NSColor(calibratedRed: 0.66, green: 0.70, blue: 0.68, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: cellW * cols, height: cellH * rows))
    for (row, coat) in coats.enumerated() {
        settings.coatTheme = coat.0
        settings.eyeTheme = coat.1
        for (col, scene) in scenes.enumerated() {
            let physics = CatPhysics()
            for _ in 0..<30 { physics.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
            let frames = scene.1(physics)
            for _ in 0..<frames { physics.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(col * cellW), y: CGFloat(row * cellH))
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.25).cgColor)
            ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(cellW) - 1, height: CGFloat(cellH) - 1))
            CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: scene.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
            ]).draw(at: CGPoint(x: 10, y: 296))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
    }
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("写入预览失败: \(error)\n".utf8))
    }
}

// 睡帽预览：4 皮肤 x 4 个头部姿态（检查帽檐贴合、耳朵从洞里钻出、帽尖惯性）
if let idx = CommandLine.arguments.firstIndex(of: "--render-cap-preview"),
   idx + 1 < CommandLine.arguments.count {
    renderCapPreviewSheet(to: CommandLine.arguments[idx + 1])
    exit(0)
}

func renderCapPreviewSheet(to path: String) {
    let settings = CatSettings.shared
    let saved = (settings.coatTheme, settings.eyeTheme, settings.lifeNight)
    defer { (settings.coatTheme, settings.eyeTheme, settings.lifeNight) = saved }
    settings.lifeNight = true
    let coats: [(CatCoatTheme, EyeColorTheme)] = [
        (.classicBlack, .neonChartreuse), (.siamese, .siameseBlue),
        (.shorthair, .referenceHazel), (.orangeWhite, .warmAmber)
    ]
    // (名称, yaw, pitch, tilt, 是否刚歪过头让帽尖甩出去)
    let poses: [(String, CGFloat, CGFloat, CGFloat, Bool)] = [
        ("正脸", 0, 0.05, 0, false),
        ("向左转头", -0.75, -0.3, -0.08, false),
        ("向右转并低头", 0.7, 0.55, 0.08, false),
        ("歪头：帽尖甩出去", 0.1, 0, 0.18, true)
    ]
    let cellW = 360, cellH = 320, scale = 2
    let cols = poses.count, rows = coats.count
    guard let ctx = CGContext(
        data: nil, width: cellW * cols * scale, height: cellH * rows * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.translateBy(x: 0, y: CGFloat(cellH * rows * scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    ctx.setFillColor(NSColor(calibratedRed: 0.66, green: 0.70, blue: 0.68, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: cellW * cols, height: cellH * rows))
    for (row, coat) in coats.enumerated() {
        settings.coatTheme = coat.0
        settings.eyeTheme = coat.1
        for (col, pose) in poses.enumerated() {
            let physics = CatPhysics()
            physics.debugNight = true
            for _ in 0..<90 { physics.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
            physics.headYaw.value = pose.1
            physics.headPitch.value = pose.2
            physics.headTilt.value = pose.3
            if !pose.4 { physics.capSway.value = pose.3 }
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(col * cellW), y: CGFloat(row * cellH))
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.25).cgColor)
            ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(cellW) - 1, height: CGFloat(cellH) - 1))
            CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: pose.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
            ]).draw(at: CGPoint(x: 10, y: 296))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
    }
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("写入预览失败: \(error)\n".utf8))
    }
}

// 逗猫 & 喂食预览：4 皮肤 x 5 个瞬间
if let idx = CommandLine.arguments.firstIndex(of: "--render-roam-compare"),
   idx + 1 < CommandLine.arguments.count {
    renderRoamCompare(to: CommandLine.arguments[idx + 1])
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--render-walk-preview"),
   idx + 1 < CommandLine.arguments.count {
    renderWalkPreviewSheet(to: CommandLine.arguments[idx + 1])
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--render-pets-preview"),
   idx + 1 < CommandLine.arguments.count {
    renderPetsPreviewSheet(to: CommandLine.arguments[idx + 1])
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--render-golden"),
   idx + 1 < CommandLine.arguments.count {
    renderGoldenSheet(to: CommandLine.arguments[idx + 1])
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--capture-settings-shots"),
   idx + 1 < CommandLine.arguments.count {
    captureSettingsShots(toDirectory: CommandLine.arguments[idx + 1])
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--render-readme-art"),
   idx + 1 < CommandLine.arguments.count {
    ShowcaseArt.render(toDirectory: CommandLine.arguments[idx + 1])
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--render-settings-preview"),
   idx + 1 < CommandLine.arguments.count {
    renderSettingsPreview(toDirectory: CommandLine.arguments[idx + 1])
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--render-holiday-preview"),
   idx + 1 < CommandLine.arguments.count {
    renderHolidayPreviewSheet(to: CommandLine.arguments[idx + 1])
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--render-bond-preview"),
   idx + 1 < CommandLine.arguments.count {
    renderBondPreviewSheet(to: CommandLine.arguments[idx + 1])
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--render-play-preview"),
   idx + 1 < CommandLine.arguments.count {
    renderPlayPreviewSheet(to: CommandLine.arguments[idx + 1])
    exit(0)
}

func renderPlayPreviewSheet(to path: String) {
    let settings = CatSettings.shared
    let saved = (settings.coatTheme, settings.eyeTheme, settings.cursorPlay)
    defer { (settings.coatTheme, settings.eyeTheme, settings.cursorPlay) = saved }
    settings.cursorPlay = true
    let coats: [(CatCoatTheme, EyeColorTheme)] = [
        (.classicBlack, .neonChartreuse), (.siamese, .siameseBlue),
        (.shorthair, .referenceHazel), (.orangeWhite, .warmAmber)
    ]
    let cursorAt = CGPoint(x: 86, y: 168)
    // (名称, 是否画光标, 准备)
    let scenes: [(String, Bool, (CatPhysics) -> Void)] = [
        ("盯上：压低、扭屁股", true, { p in
            p.debugCursorCanvas = cursorAt; p.debugPlayAvailable = true
            // 停在蓄力满、还没出爪的那一刻
            for _ in 0..<60 {
                p.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100))
                if p.playWiggle > 0.9 && sin(p.time * 24) > 0.8 { break }
            }
            if ProcessInfo.processInfo.environment["COOLCAT_DEBUG_PLAY"] != nil {
                print("stalk", p.playStalk, "wiggle", p.playWiggle)
            }
        }),
        ("出爪！", true, { p in
            p.debugCursorCanvas = cursorAt; p.debugPlayAvailable = true
            // 先扭 0.7–1.3s 屁股才出爪，给足 3s
            for _ in 0..<180 {
                p.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100))
                if let s = p.swatStreak, s.extension > 0.9 { break }
            }
        }),
        ("小鱼干掉下来", false, { p in
            p.feed()
            for _ in 0..<20 { p.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
        }),
        ("捧着啃", false, { p in
            p.feed()
            for _ in 0..<Int(2.3 * 60) { p.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
        }),
        ("吃不下：摇头", false, { p in
            for _ in 0..<FeedLog.dailyLimit { p.feed(); for _ in 0..<Int(4.4 * 60) { p.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) } }
            p.feed()
            for _ in 0..<20 { p.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
        })
    ]
    let suite = "coolcat.preview.feed"
    let cellW = 360, cellH = 320, scale = 2
    let cols = scenes.count, rows = coats.count
    guard let ctx = CGContext(
        data: nil, width: cellW * cols * scale, height: cellH * rows * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.translateBy(x: 0, y: CGFloat(cellH * rows * scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    ctx.setFillColor(NSColor(calibratedRed: 0.66, green: 0.70, blue: 0.68, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: cellW * cols, height: cellH * rows))
    _ = suite
    for (row, coat) in coats.enumerated() {
        settings.coatTheme = coat.0
        settings.eyeTheme = coat.1
        for (col, scene) in scenes.enumerated() {
            // 预览不写真实的喂食记录
            let savedFeedDay = UserDefaults.standard.string(forKey: "CoolCat.FeedDay")
            let savedFeedCount = UserDefaults.standard.integer(forKey: "CoolCat.FeedCount")
            UserDefaults.standard.removeObject(forKey: "CoolCat.FeedDay")
            let physics = CatPhysics()
            for _ in 0..<30 { physics.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
            scene.2(physics)
            UserDefaults.standard.set(savedFeedDay, forKey: "CoolCat.FeedDay")
            UserDefaults.standard.set(savedFeedCount, forKey: "CoolCat.FeedCount")
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(col * cellW), y: CGFloat(row * cellH))
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.25).cgColor)
            ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(cellW) - 1, height: CGFloat(cellH) - 1))
            CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
            if scene.1 { drawMacCursor(in: ctx, at: cursorAt, clicking: false) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: scene.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
            ]).draw(at: CGPoint(x: 10, y: 296))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
    }
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("写入预览失败: \(error)\n".utf8))
    }
}

/// 亲密度预览：四件装扮 + 送礼物 + 蹭光标
/// 节日装扮：每行一只猫，左到右 = 圣诞帽 + 小雪、深夜（还是圣诞帽，不叠睡帽）、礼盒、拐杖糖
func renderHolidayPreviewSheet(to path: String) {
    let settings = CatSettings.shared
    let saved = (settings.coatTheme, settings.eyeTheme, settings.accessory, settings.customPetID)
    defer { (settings.coatTheme, settings.eyeTheme, settings.accessory, settings.customPetID) = saved }
    let cats: [(String, () -> Void)] = [
        ("小黑猫", { PetLibrary.shared.select(nil); settings.coatTheme = .classicBlack; settings.eyeTheme = .neonChartreuse }),
        ("暹罗", { PetLibrary.shared.select(nil); settings.coatTheme = .siamese; settings.eyeTheme = .siameseBlue }),
        ("大橘", { PetLibrary.shared.select(PetLibrary.shared.pet(id: "orange-tabby")) }),
        ("德文卷毛", { PetLibrary.shared.select(PetLibrary.shared.pet(id: "devon-rex")) })
    ]
    let step: (CatPhysics) -> Void = { $0.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
    let scenes: [(String, (CatPhysics) -> Void)] = [
        ("🎄 圣诞帽 + 小雪", { p in for _ in 0..<(60 * 4) { step(p) } }),
        ("深夜：还是圣诞帽", { p in p.debugNight = true; for _ in 0..<(60 * 4) { step(p) } }),
        ("🎁 圣诞礼盒", { p in for _ in 0..<(60 * 2) { step(p) }; p.offerGift(kind: .present); for _ in 0..<(60 * 2) { step(p) } }),
        ("🍬 拐杖糖", { p in for _ in 0..<(60 * 2) { step(p) }; p.offerGift(kind: .candyCane); for _ in 0..<(60 * 2) { step(p) } })
    ]
    let suite = "coolcat.preview.holiday"
    guard let store = UserDefaults(suiteName: suite) else { return }
    store.removePersistentDomain(forName: suite)
    let bond = BondLog(store: store, today: "2026-12-24")
    let cellW = 360, cellH = 320, scale = 2
    guard let ctx = CGContext(
        data: nil, width: cellW * scenes.count * scale, height: cellH * cats.count * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.translateBy(x: 0, y: CGFloat(cellH * cats.count * scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    ctx.setFillColor(NSColor(calibratedRed: 0.42, green: 0.50, blue: 0.62, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: cellW * scenes.count, height: cellH * cats.count))
    for (row, cat) in cats.enumerated() {
        cat.1()
        settings.accessory = .none
        for (col, scene) in scenes.enumerated() {
            let physics = CatPhysics()
            physics.debugBond = bond
            physics.debugHoliday = .preview
            scene.1(physics)
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(col * cellW), y: CGFloat(row * cellH))
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.25).cgColor)
            ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(cellW) - 1, height: CGFloat(cellH) - 1))
            CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: "\(cat.0) · \(scene.0)", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
            ]).draw(at: CGPoint(x: 10, y: 296))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
    }
    store.removePersistentDomain(forName: suite)
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

func renderBondPreviewSheet(to path: String) {
    let settings = CatSettings.shared
    let saved = (settings.coatTheme, settings.eyeTheme, settings.accessory)
    defer { (settings.coatTheme, settings.eyeTheme, settings.accessory) = saved }
    let coats: [(CatCoatTheme, EyeColorTheme)] = [
        (.classicBlack, .neonChartreuse), (.siamese, .siameseBlue),
        (.shorthair, .referenceHazel), (.orangeWhite, .warmAmber)
    ]
    // 预览用独立的存储，别动真实的亲密度
    let suite = "coolcat.preview.bond"
    guard let store = UserDefaults(suiteName: suite) else { return }
    store.removePersistentDomain(forName: suite)
    store.set(900, forKey: "CoolCat.Bond.Points")
    let bond = BondLog(store: store, today: "2026-11-24")
    let headPoint = CGPoint(x: 200, y: 104)
    let step: (CatPhysics) -> Void = { $0.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: idleInput(now: 100)) }
    // (名称, 装扮, 光标位置, 准备)
    let scenes: [(String, CatAccessory, CGPoint?, (CatPhysics) -> Void)] = [
        ("Lv2 🔔 铃铛项圈", .bell, nil, { p in for _ in 0..<30 { step(p) } }),
        ("Lv3 🧣 毛线围巾", .scarf, nil, { p in for _ in 0..<30 { step(p) } }),
        ("Lv4 🎀 蝴蝶结", .bow, nil, { p in for _ in 0..<30 { step(p) } }),
        ("Lv5 🕶️ 墨镜", .shades, nil, { p in for _ in 0..<30 { step(p) } }),
        ("送礼物：推到桌上", .scarf, nil, { p in
            p.offerGift(kind: [.mouseToy, .yarn, .flower, .feather][Int(p.time * 10) % 4])
            for _ in 0..<Int(0.45 * 60) { step(p) }
        }),
        ("礼物放好了", .bell, nil, { p in
            p.offerGift(kind: .feather)
            for _ in 0..<Int(2.5 * 60) { step(p) }
        }),
        ("光标停在头上：蹭蹭", .bow, headPoint, { p in
            p.debugCursorCanvas = headPoint
            for _ in 0..<Int(2.2 * 60) { step(p) }
        })
    ]
    let cellW = 360, cellH = 320, scale = 2
    let cols = scenes.count, rows = coats.count
    guard let ctx = CGContext(
        data: nil, width: cellW * cols * scale, height: cellH * rows * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.translateBy(x: 0, y: CGFloat(cellH * rows * scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    ctx.setFillColor(NSColor(calibratedRed: 0.66, green: 0.70, blue: 0.68, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: cellW * cols, height: cellH * rows))
    for (row, coat) in coats.enumerated() {
        settings.coatTheme = coat.0
        settings.eyeTheme = coat.1
        for (col, scene) in scenes.enumerated() {
            settings.accessory = scene.1
            let physics = CatPhysics()
            physics.debugBond = bond
            for _ in 0..<30 { step(physics) }
            scene.3(physics)
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(col * cellW), y: CGFloat(row * cellH))
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.25).cgColor)
            ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(cellW) - 1, height: CGFloat(cellH) - 1))
            CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
            if let c = scene.2 { drawMacCursor(in: ctx, at: c, clicking: false) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: scene.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
            ]).draw(at: CGPoint(x: 10, y: 296))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
    }
    store.removePersistentDomain(forName: suite)
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("写入预览失败: \(error)\n".utf8))
    }
}

/// 体型对比：坐在键盘前的小猫 vs 屏幕上同比例的侧身小猫（脚底对齐座位高度）
func renderRoamCompare(to path: String) {
    let k = CatRenderer.walkerArtScale
    let width: CGFloat = 360 + 4 * CatRenderer.walkerCanvas.width * k * 0.62, height: CGFloat = 320
    let scale: CGFloat = 2
    guard let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.translateBy(x: 0, y: height * scale)
    ctx.scaleBy(x: scale, y: -scale)
    ctx.setFillColor(NSColor(calibratedRed: 0.66, green: 0.70, blue: 0.68, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    CatRenderer.draw(in: ctx, physics: CatPhysics(), showPermissionPill: false)
    let seatY = CatPhysics.seatAnchor.y
    ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.2).cgColor)
    ctx.move(to: CGPoint(x: 0, y: seatY)); ctx.addLine(to: CGPoint(x: width, y: seatY)); ctx.strokePath()
    let poses: [RoamPose] = [.stand, .walk, .air, .sit]
    for (i, pose) in poses.enumerated() {
        ctx.saveGState()
        // 脚底放在座位那条线上
        let x = 360 + CGFloat(i) * CatRenderer.walkerCanvas.width * k * 0.62
        ctx.translateBy(x: x - CatRenderer.walkerFeet.x * k * 0.25, y: seatY - CatRenderer.walkerFeet.y * k)
        ctx.scaleBy(x: k, y: k)
        CatRenderer.drawWalker(in: ctx, pose: .init(pose: pose, phase: .pi / 2, facing: 1, air: 0.4, time: 0.3, blink: false))
        ctx.restoreGState()
    }
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

/// 满屏漫游的侧身小猫：每行一只猫，每列一个姿势
func renderWalkPreviewSheet(to path: String) {
    let settings = CatSettings.shared
    let saved = (settings.coatTheme, settings.eyeTheme, settings.customPetID, settings.accessory)
    defer { (settings.coatTheme, settings.eyeTheme, settings.customPetID, settings.accessory) = saved }
    settings.accessory = CatAccessory(rawValue: ProcessInfo.processInfo.environment["COOLCAT_ACCESSORY"] ?? "") ?? .none
    let cats: [(String, () -> Void)] = [
        ("小黑猫", { PetLibrary.shared.select(nil); settings.coatTheme = .classicBlack; settings.eyeTheme = .neonChartreuse }),
        ("暹罗", { PetLibrary.shared.select(nil); settings.coatTheme = .siamese; settings.eyeTheme = .siameseBlue }),
        ("美短", { PetLibrary.shared.select(nil); settings.coatTheme = .shorthair; settings.eyeTheme = .softAmber }),
        ("大橘", { PetLibrary.shared.select(PetLibrary.shared.pet(id: "orange-tabby")) }),
        ("奶牛猫", { PetLibrary.shared.select(PetLibrary.shared.pet(id: "tuxedo")) }),
        ("三花", { PetLibrary.shared.select(PetLibrary.shared.pet(id: "calico")) }),
        ("英短蓝猫", { PetLibrary.shared.select(PetLibrary.shared.pet(id: "british-blue")) }),
        ("德文卷毛", { PetLibrary.shared.select(PetLibrary.shared.pet(id: "devon-rex")) })
    ]
    // COOLCAT_WALK_SET=nap：只看打盹的几个阶段
    let napPoses: [(String, CatRenderer.WalkerPose)] = [
        ("刚趴下", .init(pose: .curl, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, curl: 0)),
        ("蜷一半", .init(pose: .curl, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, curl: 0.5)),
        ("睡着 1", .init(pose: .curl, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, curl: 1, asleep: true)),
        ("睡着 2", .init(pose: .curl, phase: 0, facing: 1, air: 0, time: 1.9, blink: false, curl: 1, asleep: true)),
        ("朝左睡", .init(pose: .curl, phase: 0, facing: -1, air: 0, time: 1.1, blink: false, curl: 1, asleep: true))
    ]
    let walkPoses: [(String, CatRenderer.WalkerPose)] = [
        ("站", .init(pose: .stand, phase: 0, facing: 1, air: 0, time: 0.3, blink: false)),
        ("走 1", .init(pose: .walk, phase: 0, facing: 1, air: 0, time: 0.3, blink: false)),
        ("走 2", .init(pose: .walk, phase: .pi / 2, facing: 1, air: 0, time: 0.6, blink: false)),
        ("走 3", .init(pose: .walk, phase: .pi, facing: 1, air: 0, time: 0.9, blink: false)),
        ("跑", .init(pose: .run, phase: .pi * 0.3, facing: 1, air: 0, time: 0.3, blink: false)),
        ("急刹", .init(pose: .land, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, landProgress: 0.35, skidding: true)),
        ("蹲", .init(pose: .crouch, phase: 0, facing: 1, air: 0, time: 0.3, blink: false)),
        ("起跳", .init(pose: .air, phase: 0, facing: 1, air: 0.15, time: 0.3, blink: false)),
        ("下落", .init(pose: .air, phase: 0, facing: 1, air: 0.85, time: 0.3, blink: false)),
        ("落地", .init(pose: .land, phase: 0, facing: 1, air: 0, time: 0.3, blink: false)),
        ("坐", .init(pose: .sit, phase: 0, facing: 1, air: 0, time: 0.3, blink: false)),
        ("底边下沉", .init(pose: .crouch, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, sink: 0.5)),
        ("底边偷看", .init(pose: .peek, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, peekEdge: .bottom, peekReveal: 1)),
        ("右边偷看", .init(pose: .peek, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, peekEdge: .right, peekReveal: 1)),
        ("左边偷看", .init(pose: .peek, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, peekEdge: .left, peekReveal: 1)),
        ("探出一半", .init(pose: .peek, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, peekEdge: .right, peekReveal: 0.5)),
        ("朝左走", .init(pose: .walk, phase: .pi / 2, facing: -1, air: 0, time: 0.6, blink: false))
    ]
    // COOLCAT_WALK_SET=walk：走路一个周期的 8 帧
    let walkCyclePoses: [(String, CatRenderer.WalkerPose)] = (0..<8).map { i in
        ("走 \(i)", .init(pose: .walk, phase: CGFloat(i) / 8 * 2 * .pi, facing: 1, air: 0, time: 0.3, blink: false,
                        runBlend: 0, moveBlend: 1))
    }
    // COOLCAT_WALK_SET=run：飞奔一个周期的 8 帧 + 急刹 + 转身
    let runPoses: [(String, CatRenderer.WalkerPose)] = (0..<8).map { i in
        ("飞奔 \(i)", .init(pose: .run, phase: CGFloat(i) / 8 * 2 * .pi, facing: 1, air: 0, time: 0.3, blink: false,
                         runBlend: 1, moveBlend: 1))
    } + [
        ("急刹 1", .init(pose: .land, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, landProgress: 0.25, skidding: true)),
        ("急刹 2", .init(pose: .land, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, landProgress: 0.65, skidding: true)),
        ("转身", .init(pose: .walk, phase: .pi / 2, facing: 1, air: 0, time: 0.3, blink: false, moveBlend: 1, turnScale: 0.45))
    ]
    // COOLCAT_WALK_SET=play：漫游时逗猫的几个姿势
    let playPoses: [(String, CatRenderer.WalkerPose)] = [
        ("盯上", .init(pose: .stand, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, hunting: true)),
        ("潜伏 1", .init(pose: .stalk, phase: 0, facing: 1, air: 0, time: 0.3, blink: false)),
        ("潜伏 2", .init(pose: .stalk, phase: .pi, facing: 1, air: 0, time: 0.6, blink: false)),
        ("扭屁股 1", .init(pose: .wiggle, phase: 0, facing: 1, air: 0, time: 0.1, blink: false)),
        ("扭屁股 2", .init(pose: .wiggle, phase: 0, facing: 1, air: 0, time: 0.2, blink: false)),
        ("扑", .init(pose: .air, phase: 0, facing: 1, air: 0.3, time: 0.3, blink: false, hunting: true)),
        ("爬（窗在右）", .init(pose: .climb, phase: 0, facing: 1, air: 0, time: 0.3, blink: false)),
        ("爬（窗在左）", .init(pose: .climb, phase: .pi, facing: -1, air: 0, time: 0.3, blink: false))
    ]
    // COOLCAT_WALK_SET=holiday：戴圣诞帽的几个漫游姿势
    let holidayPoses: [(String, CatRenderer.WalkerPose)] = [
        ("站", .init(pose: .stand, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, santaHat: true)),
        ("飞奔", .init(pose: .run, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, santaHat: true)),
        ("爬", .init(pose: .climb, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, santaHat: true)),
        ("打盹", .init(pose: .curl, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, curl: 1, asleep: true, santaHat: true)),
        ("偷看", .init(pose: .peek, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, peekEdge: .bottom, peekReveal: 1,
                     santaHat: true))
    ]
    // COOLCAT_WALK_SET=sign：举牌提醒
    let signPoses: [(String, CatRenderer.WalkerPose)] = [
        ("举牌（朝右）", .init(pose: .sign, phase: 0, facing: 1, air: 0, time: 0.3, blink: false,
                         signLines: ["Claude Code 等你批准", "CoolCat"])),
        ("举牌（朝左）", .init(pose: .sign, phase: 0, facing: -1, air: 0, time: 0.6, blink: false,
                         signLines: ["Codex 等你回复", "today-platform-ios"])),
        ("举牌 + 圣诞帽", .init(pose: .sign, phase: 0, facing: 1, air: 0, time: 0.9, blink: false, santaHat: true,
                          signLines: ["Claude Code 等你批准", "Faceplant"]))
    ]
    // COOLCAT_WALK_SET=snow：抖爪子、甩身子、沾雪的爪子
    let snowPoses: [(String, CatRenderer.WalkerPose)] = [
        ("沾雪走路", .init(pose: .walk, phase: .pi / 2, facing: 1, air: 0, time: 0.6, blink: false, pawSnow: 1)),
        ("抬爪", .init(pose: .pawShake, phase: 0, facing: 1, air: 0, time: 0.04, blink: false, shake: 0.25,
                      pawSnow: 0.8)),
        ("甩爪 1", .init(pose: .pawShake, phase: 0, facing: 1, air: 0, time: 0.1, blink: false, shake: 0.5,
                       pawSnow: 0.8)),
        ("甩爪 2", .init(pose: .pawShake, phase: 0, facing: 1, air: 0, time: 0.175, blink: false, shake: 0.5,
                       pawSnow: 0.8)),
        ("甩身子 1", .init(pose: .bodyShake, phase: 0, facing: 1, air: 0, time: 0.046, blink: false, shake: 0.5)),
        ("甩身子 2", .init(pose: .bodyShake, phase: 0, facing: 1, air: 0, time: 0.139, blink: false, shake: 0.5)),
        ("甩身子 + 帽", .init(pose: .bodyShake, phase: 0, facing: -1, air: 0, time: 0.046, blink: false, santaHat: true,
                          shake: 0.5))
    ]
    // COOLCAT_WALK_SET=knock：叼着东西走、跑，放下，拨爪
    let knockPoses: [(String, CatRenderer.WalkerPose)] = [
        ("叼笔走", .init(pose: .walk, phase: .pi / 2, facing: 1, air: 0, time: 0.6, blink: false, trinket: .pen)),
        ("叼橡皮跑", .init(pose: .run, phase: .pi * 0.3, facing: 1, air: 0, time: 0.3, blink: false, trinket: .eraser)),
        ("叼瓶盖跳", .init(pose: .air, phase: 0, facing: 1, air: 0.3, time: 0.3, blink: false, trinket: .bottleCap)),
        ("叼纸团爬", .init(pose: .climb, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, trinket: .paperBall)),
        ("叼发圈放下", .init(pose: .crouch, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, trinket: .hairTie)),
        ("拨 1", .init(pose: .knockTap, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, tap: 0.2)),
        ("拨 2", .init(pose: .knockTap, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, tap: 0.45)),
        ("拨 3", .init(pose: .knockTap, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, tap: 0.75)),
        ("朝左拨", .init(pose: .knockTap, phase: 0, facing: -1, air: 0, time: 0.3, blink: false, tap: 0.45))
    ]
    // COOLCAT_WALK_SET=kick：踢文件一脚的几个时刻（低踢 / 高踢 / 朝左）
    func kickPose(_ kickTime: CGFloat, angle: CGFloat = 0.7, facing: CGFloat = 1) -> CatRenderer.WalkerPose {
        .init(pose: .kick, phase: 0, facing: facing, air: 0, time: 0.3, blink: false, kickTime: kickTime,
              kickAngle: angle)
    }
    let kickPoses: [(String, CatRenderer.WalkerPose)] = [
        ("瞄准", kickPose(0.2)),
        ("蓄力", kickPose(0.6)),
        ("出脚", kickPose(0.74)),
        ("踢中", kickPose(0.8)),
        ("低踢", kickPose(0.95, angle: 0.21)),
        ("高踢", kickPose(0.95, angle: 1.19)),
        ("收腿", kickPose(1.35)),
        ("朝左踢", kickPose(0.8, angle: 0.9, facing: -1))
    ]
    let set = ProcessInfo.processInfo.environment["COOLCAT_WALK_SET"]
    let named = ["nap": napPoses, "walk": walkCyclePoses, "run": runPoses, "play": playPoses, "holiday": holidayPoses,
                 "sign": signPoses, "snow": snowPoses, "knock": knockPoses, "kick": kickPoses]
    let poses = set.flatMap { named[$0] } ?? walkPoses
    let cw = Int(CatRenderer.walkerCanvas.width), ch = Int(CatRenderer.walkerCanvas.height), scale = 2
    let labelW = 70
    guard let ctx = CGContext(
        data: nil, width: (labelW + cw * poses.count) * scale, height: ch * cats.count * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.translateBy(x: 0, y: CGFloat(ch * cats.count * scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    ctx.setFillColor(NSColor(calibratedRed: 0.66, green: 0.70, blue: 0.68, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: labelW + cw * poses.count, height: ch * cats.count))
    for (row, cat) in cats.enumerated() {
        cat.1()
        for (col, pose) in poses.enumerated() {
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(labelW + col * cw), y: CGFloat(row * ch))
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.2).cgColor)
            ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(cw) - 1, height: CGFloat(ch) - 1))
            // 地面线
            ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.15).cgColor)
            ctx.move(to: CGPoint(x: 0, y: CatRenderer.walkerFeet.y)); ctx.addLine(to: CGPoint(x: CGFloat(cw), y: CatRenderer.walkerFeet.y)); ctx.strokePath()
            CatRenderer.drawWalker(in: ctx, pose: pose.1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            if row == 0 {
                NSAttributedString(string: pose.0, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white]).draw(at: CGPoint(x: 6, y: 4))
            }
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSAttributedString(string: cat.0, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white]).draw(at: CGPoint(x: 8, y: CGFloat(row * ch + ch / 2 - 8)))
        NSGraphicsContext.restoreGraphicsState()
    }
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("写入预览失败: \(error)\n".utf8))
    }
}

/// 新猫总览：每只 PetSpec 猫两格（正脸 / 转头戴耳机），3 列排开
func renderPetsPreviewSheet(to path: String) {
    let settings = CatSettings.shared
    let saved = (settings.coatTheme, settings.eyeTheme, settings.customPetID, settings.keyboardTheme, settings.accessory)
    defer { (settings.coatTheme, settings.eyeTheme, settings.customPetID, settings.keyboardTheme, settings.accessory) = saved }
    settings.keyboardTheme = .classicMilk
    // COOLCAT_ACCESSORY=bell 等：检查装扮在各只猫身上是否合身
    settings.accessory = CatAccessory(rawValue: ProcessInfo.processInfo.environment["COOLCAT_ACCESSORY"] ?? "") ?? .none
    // COOLCAT_PET=<id> 只画这一只，方便细调
    let only = ProcessInfo.processInfo.environment["COOLCAT_PET"]
    let pets = PetLibrary.builtIns.filter { only == nil || $0.id == only }
    let poses: [(CatPhysics) -> Void] = [
        { _ in },
        { p in p.headphonesOn.value = 1; p.headYaw.value = -0.7; p.headPitch.value = -0.2; p.headTilt.value = -0.08 },
        { p in
            // 打字：两只前爪伸到键盘上
            let l = KeyboardLayout.canvasPoint(for: .f), r = KeyboardLayout.canvasPoint(for: .j)
            p.leftPaw.x.value = l.x; p.leftPaw.y.value = l.y
            p.rightPaw.x.value = r.x; p.rightPaw.y.value = r.y
            p.headPitch.value = 0.5
        }
    ]
    let cellW = 360, cellH = 320, scale = 2, perRow = only == nil ? 3 : 1
    let cols = perRow * poses.count, rows = (pets.count + perRow - 1) / perRow
    guard let ctx = CGContext(
        data: nil, width: cellW * cols * scale, height: cellH * rows * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.translateBy(x: 0, y: CGFloat(cellH * rows * scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    ctx.setFillColor(NSColor(calibratedRed: 0.66, green: 0.70, blue: 0.68, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: cellW * cols, height: cellH * rows))
    for (i, pet) in pets.enumerated() {
        PetLibrary.shared.select(pet)
        for (j, pose) in poses.enumerated() {
            let physics = CatPhysics()
            pose(physics)
            let col = (i % perRow) * poses.count + j, row = i / perRow
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(col * cellW), y: CGFloat(row * cellH))
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.25).cgColor)
            ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(cellW) - 1, height: CGFloat(cellH) - 1))
            CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: j == 0 ? pet.name : "", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white
            ]).draw(at: CGPoint(x: 10, y: 294))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
    }
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("写入预览失败: \(error)\n".utf8))
    }
}

/// 回归基准图：不跑物理（没有随机眨眼/粒子），直接摆姿态，保证每次逐像素一致。
/// 改渲染前后各渲染一张对比，确认内置毛色的画面没被改坏。
func renderGoldenSheet(to path: String) {
    let settings = CatSettings.shared
    let saved = (settings.coatTheme, settings.eyeTheme, settings.accessory, settings.keyboardTheme)
    defer { (settings.coatTheme, settings.eyeTheme, settings.accessory, settings.keyboardTheme) = saved }
    settings.keyboardTheme = .classicMilk
    let coats: [(CatCoatTheme, EyeColorTheme)] = [
        (.classicBlack, .neonChartreuse), (.siamese, .siameseBlue),
        (.shorthair, .referenceHazel), (.orangeWhite, .warmAmber)
    ]
    let poses: [(CatAccessory, (CatPhysics) -> Void)] = [
        (.none, { _ in }),
        (.bell, { p in p.headYaw.value = -0.8; p.headPitch.value = -0.3; p.headTilt.value = -0.08 }),
        (.scarf, { p in p.headYaw.value = 0.7; p.headPitch.value = 0.5; p.earFold.value = 0.6 }),
        (.bow, { p in p.headphonesOn.value = 1; p.headTilt.value = 0.1 }),
        (.shades, { p in p.nightCap.value = 1; p.bodySquash.value = 0.9; p.hindFootActive.value = 1 })
    ]
    let cellW = 360, cellH = 320, scale = 2
    guard let ctx = CGContext(
        data: nil, width: cellW * poses.count * scale, height: cellH * coats.count * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.translateBy(x: 0, y: CGFloat(cellH * coats.count * scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    ctx.setFillColor(NSColor(calibratedRed: 0.66, green: 0.70, blue: 0.68, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: cellW * poses.count, height: cellH * coats.count))
    for (row, coat) in coats.enumerated() {
        settings.coatTheme = coat.0
        settings.eyeTheme = coat.1
        for (col, pose) in poses.enumerated() {
            settings.accessory = pose.0
            let physics = CatPhysics()
            pose.1(physics)
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(col * cellW), y: CGFloat(row * cellH))
            CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
            ctx.restoreGState()
        }
    }
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("写入基准图失败: \(error)\n".utf8))
    }
}

/// 设置面板预览：不弹窗，离屏渲染每一页到 PNG
private final class PreviewSettingsHost: SettingsHost {
    let physics = CatPhysics()
    var petVisible = true
    var autoStartEnabled = true
    func applyScale(_ scale: CGFloat) {}
    func applyWindowBehavior() {}
    func audioSettingsChanged(resetPermission: Bool) {}
    func selectCoat(_ coat: CatCoatTheme) {}
    func resetPetPosition() {}
    func relaunch() {}
    func openInputMonitoring() {}
    func install(_ agent: CodingAgent) {}
    func uninstall(_ agent: CodingAgent) {}
    func runDemo(_ demo: SettingsDemo) {}
    var roamPlatformStatus: String { "现在有 2 处能跳" }
}

/// README 用的设置截图：在屏幕上开真实窗口（侧栏毛玻璃、选中态都正确），用 screencapture 按窗口截取
func captureSettingsShots(toDirectory dir: String) {
    _ = NSApplication.shared
    // 普通 App 才能被激活成前台，窗口才是"活跃"配色（选中蓝、开关蓝）
    NSApp.setActivationPolicy(.regular)
    NSApp.finishLaunching()
    let settings = CatSettings.shared
    let savedAccessory = settings.accessory
    defer { settings.accessory = savedAccessory }
    settings.accessory = .scarf
    let host = PreviewSettingsHost()
    let suite = "coolcat.readme.settings"
    if let store = UserDefaults(suiteName: suite) {
        store.removePersistentDomain(forName: suite)
        store.set(520, forKey: "CoolCat.Bond.Points")
        store.set("2026-11-03", forKey: "CoolCat.Bond.FirstDay")
        store.set(146, forKey: "CoolCat.Bond.Pets")
        store.set(87, forKey: "CoolCat.Bond.Catches")
        store.set(64, forKey: "CoolCat.Bond.Fish")
        host.physics.debugBond = BondLog(store: store, today: "2026-11-24")
    }
    // Claude 页：喂两条假会话
    let tracker = ClaudeActivityTracker.shared
    let now = CACurrentMediaTime()
    tracker.apply(event: "UserPromptSubmit", session: "a", tool: nil, notificationType: nil, project: "CoolCat", now: now - 134)
    tracker.apply(event: "PreToolUse", session: "a", tool: "Edit", notificationType: nil, project: "CoolCat", now: now - 3)
    tracker.apply(event: "UserPromptSubmit", session: "b", tool: nil, notificationType: nil, project: "api-server", now: now - 35)
    tracker.apply(event: "PreToolUse", session: "b", tool: "Bash", notificationType: nil, project: "api-server", now: now - 2)
    let store = SettingsStore(host: host)
    let preview = CatPreviewModel()
    preview.start()
    for pane in [SettingsPane.general, .appearance, .bond, .music, .claude] {
        let hosting = NSHostingController(rootView: SettingsRootView(store: store, preview: preview, initial: pane))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 860, height: 640))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        // App 自己没有屏幕录制权限：把窗口号写出去，由有权限的终端截图，截完放一个 .done 文件
        let base = URL(fileURLWithPath: dir).appendingPathComponent("settings-\(pane.rawValue)")
        do {
            try "\(window.windowNumber)".write(to: base.appendingPathExtension("wid"), atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("写窗口号失败: \(error)\n".utf8))
        }
        let done = base.appendingPathExtension("done").path
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: done) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        window.orderOut(nil)
    }
    preview.stop()
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
}

func renderSettingsPreview(toDirectory dir: String) {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let host = PreviewSettingsHost()
    let store = SettingsStore(host: host)
    let preview = CatPreviewModel()
    preview.start()
    for pane in SettingsPane.allCases {
        let view = SettingsRootView(store: store, preview: preview, initial: pane)
        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: 860, height: 640)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("settings-\(pane.rawValue).png")
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("写入失败: \(error)\n".utf8))
        }
        window.orderOut(nil)
    }
    preview.stop()
}

/// 预览用：键鼠长时间无操作的脚本输入
private func idleInput(now: CFTimeInterval) -> ScriptedFrameInput {
    ScriptedFrameInput(
        now: now, activeKeys: [], orderedKeys: [], mouseScreenPos: .zero, mouseVelocity: .zero,
        leftMouseDown: false, rightMouseDown: false,
        lastMouseMoveTime: 0, lastMouseClickTime: 0, lastKeyActivityTime: 0
    )
}

func renderPreviewSheet(to path: String, forceSiamese: Bool = false) {
    let prevCoat = CatSettings.shared.coatTheme
    let prevEye = CatSettings.shared.eyeTheme
    let prevKb = CatSettings.shared.keyboardTheme
    if forceSiamese {
        CatSettings.shared.coatTheme = .siamese
        CatSettings.shared.eyeTheme = .siameseBlue
        CatSettings.shared.keyboardTheme = .classicMilk
    } else {
        CatSettings.shared.coatTheme = .classicBlack
        CatSettings.shared.eyeTheme = .neonChartreuse
        CatSettings.shared.keyboardTheme = .classicMilk
    }
    defer {
        CatSettings.shared.coatTheme = prevCoat
        CatSettings.shared.eyeTheme = prevEye
        CatSettings.shared.keyboardTheme = prevKb
    }
    let cellW = 360
    let cellH = 320
    let scale = 2
    let cols = 3
    let rows = 2
    let totalW = cellW * cols * scale
    let totalH = cellH * rows * scale

    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: totalW,
        height: totalH,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }

    // Flip context to match top-down NSView coordinates
    ctx.translateBy(x: 0, y: CGFloat(totalH))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))

    // Soft desktop wallpaper backdrop matching reference aesthetic
    let bgColors = [
        NSColor(calibratedRed: 0.72, green: 0.74, blue: 0.71, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.54, green: 0.56, blue: 0.55, alpha: 1.0).cgColor
    ] as CFArray
    if let grad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: cellW * cols, y: cellH * rows), options: [])
    }

    let scenarios: [(String, (CatPhysics) -> Void)] = [
        ("1. Idle (Seamless Thick Neck)", { p in
            p.leftPaw.x.value = CatPhysics.leftPawRest.x
            p.leftPaw.y.value = CatPhysics.leftPawRest.y
            p.rightPaw.x.value = CatPhysics.rightPawRest.x
            p.rightPaw.y.value = CatPhysics.rightPawRest.y
            p.headYaw.value = 0
            p.headPitch.value = 0
            p.eyeGaze.x.value = 0
            p.eyeGaze.y.value = 0
        }),
        ("2. 2.5D Head Turn Left-Up", { p in
            p.leftPaw.x.value = CatPhysics.mouseBaseCenter.x + 2
            p.leftPaw.y.value = CatPhysics.mouseBaseCenter.y - 3
            p.bodyShiftX.value = -9
            p.bodyTilt.value = -0.07
            p.headYaw.value = -0.88
            p.headPitch.value = -0.62
            p.headTilt.value = -0.11
            p.eyeGaze.x.value = -0.78
            p.eyeGaze.y.value = -0.58
        }),
        ("3. 2.5D Head Turn Right-Down", { p in
            let burst: [PhysicalKey] = [.j, .o, .e, .a]
            for (i, k) in burst.enumerated() {
                p.triggerKeyDown(k)
                if i < p.floatingKeycaps.count {
                    p.floatingKeycaps[i].age = 0.22 + CGFloat(burst.count - 1 - i) * 0.12
                }
            }
            let ptL = KeyboardLayout.canvasPoint(for: .o) // viewer-left = cat's right hand (O)
            let ptR = KeyboardLayout.canvasPoint(for: .f) // viewer-right = cat's left hand (F)
            p.leftPaw.x.value = ptL.x; p.leftPaw.y.value = ptL.y
            p.rightPaw.x.value = ptR.x; p.rightPaw.y.value = ptR.y
            p.headYaw.value = 0.72
            p.headPitch.value = 0.78
            p.headTilt.value = 0.09
            p.eyeGaze.x.value = 0.65
            p.eyeGaze.y.value = 0.72
        }),
        ("4. Hunting Mode! (Round Boba Eyes)", { p in
            p.leftPaw.x.value = CatPhysics.mouseBaseCenter.x + 2
            p.leftPaw.y.value = CatPhysics.mouseBaseCenter.y - 3
            p.huntIntensity.value = 1.0
            p.bodySquash.value = 0.89
            p.headOffsetY.value = 10.5
            p.earFold.value = -0.18
            p.headYaw.value = -0.55
            p.headPitch.value = -0.25
            p.headTilt.value = -0.09
            p.eyeGaze.x.value = -0.50
            p.eyeGaze.y.value = -0.22
        }),
        ("5. Gaming 3-Key + Hind Foot!", { p in
            p.triggerKeyDown(.w)
            p.triggerKeyDown(.leftShift)
            p.triggerKeyDown(.space)
            for i in p.floatingKeycaps.indices { p.floatingKeycaps[i].age = 0.20 }
            let ptL = KeyboardLayout.canvasPoint(for: .space)
            let ptR = KeyboardLayout.canvasPoint(for: .w)
            let ptF = KeyboardLayout.canvasPoint(for: .leftShift)
            p.leftPaw.x.value = ptL.x; p.leftPaw.y.value = ptL.y
            p.rightPaw.x.value = ptR.x; p.rightPaw.y.value = ptR.y
            p.hindFoot.x.value = ptF.x; p.hindFoot.y.value = ptF.y
            p.hindFootActive.value = 1.0
            p.pupilScale.value = 1.24
            p.headPitch.value = 0.55
            p.eyeGaze.x.value = 0.15; p.eyeGaze.y.value = 0.60
        }),
        ("6. Petting (Happy Closed Eyes)", { p in
            p.leftPaw.x.value = CatPhysics.mouseBaseCenter.x + 2
            p.leftPaw.y.value = CatPhysics.mouseBaseCenter.y - 3
            p.bodyShiftX.value = -7
            p.bodyTilt.value = -0.05
            p.headYaw.value = -0.25
            p.headTilt.value = -0.08
            p.earFold.value = 0.65
            for _ in 0..<10 {
                p.registerPetStroke(canvasPoint: CGPoint(x: 184, y: 120), delta: 16, isHead: true)
            }
            p.triggerKeyDown(.s)
            p.floatingKeycaps[0].age = 0.22
        })
    ]

    for (index, (label, configure)) in scenarios.enumerated() {
        let col = index % cols
        let row = index / cols
        let ox = CGFloat(col * cellW)
        let oy = CGFloat(row * cellH)

        let physics = CatPhysics()
        configure(physics)

        ctx.saveGState()
        ctx.translateBy(x: ox, y: oy)

        // Subtle panel divider
        ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.25).cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(cellW) - 1, height: CGFloat(cellH) - 1))

        CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)

        // Label badge top-left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        ctx.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 0.72).cgColor)
        ctx.fill(CGRect(x: 8, y: 8, width: 215, height: 22))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSAttributedString(string: label, attributes: attrs).draw(at: CGPoint(x: 14, y: 11))
        NSGraphicsContext.restoreGraphicsState()

        ctx.restoreGState()
    }

    guard let cgImg = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: cgImg)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Live-Style Animated Demo Exporter (30fps frames -> GIF / MP4)

private func drawDemoBackdrop(in ctx: CGContext, width: CGFloat, height: CGFloat) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        NSColor(calibratedRed: 0.78, green: 0.80, blue: 0.77, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.62, green: 0.65, blue: 0.63, alpha: 1.0).cgColor
    ] as CFArray
    if let grad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: width, y: height), options: [])
    }
    // Soft subtle vignette / studio light glow behind cat
    let glowColors = [
        NSColor(calibratedWhite: 1.0, alpha: 0.22).cgColor,
        NSColor(calibratedWhite: 1.0, alpha: 0.0).cgColor
    ] as CFArray
    if let rad = CGGradient(colorsSpace: cs, colors: glowColors, locations: [0, 1]) {
        let c = CGPoint(x: width * 0.5, y: height * 0.46)
        ctx.drawRadialGradient(rad, startCenter: c, startRadius: 10, endCenter: c, endRadius: width * 0.58, options: [])
    }
}

func drawMacCursor(in ctx: CGContext, at pt: CGPoint, clicking: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: pt.x, y: pt.y)
    if clicking {
        ctx.setFillColor(NSColor(calibratedRed: 0.79, green: 0.95, blue: 0.25, alpha: 0.45).cgColor)
        ctx.fillEllipse(in: CGRect(x: -11, y: -11, width: 22, height: 22))
    }
    let scale: CGFloat = clicking ? 0.90 : 1.0
    ctx.scaleBy(x: scale, y: scale)

    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 0, y: 0))
    arrow.addLine(to: CGPoint(x: 0, y: 18))
    arrow.addLine(to: CGPoint(x: 4.6, y: 14.2))
    arrow.addLine(to: CGPoint(x: 7.8, y: 20.5))
    arrow.addLine(to: CGPoint(x: 10.6, y: 19.2))
    arrow.addLine(to: CGPoint(x: 7.4, y: 12.8))
    arrow.addLine(to: CGPoint(x: 13.0, y: 12.8))
    arrow.closeSubpath()

    ctx.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor)
    ctx.addPath(arrow)
    ctx.fillPath()
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(1.5)
    ctx.setLineJoin(.round)
    ctx.addPath(arrow)
    ctx.strokePath()
    ctx.restoreGState()
}

private func renderSequence(
    name: String,
    outRoot: String,
    durationSec: Double,
    fps: Int = 30,
    driver: (_ t: Double, _ dt: Double, _ physics: CatPhysics, _ state: inout ScriptedFrameInput, _ showCursor: inout Bool) -> Void
) {
    let dir = (outRoot as NSString).appendingPathComponent(name)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let outW = 540
    let outH = 480
    let canvasW = CatPhysics.canvasSize.width   // 360
    let canvasH = CatPhysics.canvasSize.height  // 320
    let scaleX = CGFloat(outW) / canvasW
    let scaleY = CGFloat(outH) / canvasH

    // Virtual window frame in screen coordinates (origin at 0,0, width=360, height=320)
    let winFrame = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
    let physics = CatPhysics()

    var state = ScriptedFrameInput(
        now: 100.0,
        activeKeys: [],
        orderedKeys: [],
        mouseScreenPos: CGPoint(x: 184, y: 196),
        mouseVelocity: .zero,
        leftMouseDown: false,
        rightMouseDown: false,
        lastMouseMoveTime: 0,
        lastMouseClickTime: 0,
        lastKeyActivityTime: 0
    )

    let totalFrames = Int(durationSec * Double(fps))
    let subSteps = 2
    let subDt = 1.0 / Double(fps * subSteps)
    let cs = CGColorSpaceCreateDeviceRGB()

    for frameIdx in 0..<totalFrames {
        var showCursor = false
        for s in 0..<subSteps {
            let t = (Double(frameIdx) + Double(s) / Double(subSteps)) / Double(fps)
            state.now = 100.0 + t
            driver(t, subDt, physics, &state, &showCursor)
            physics.step(dt: CGFloat(subDt), windowFrameInScreen: winFrame, scripted: state)
        }

        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { continue }

        ctx.translateBy(x: 0, y: CGFloat(outH))
        ctx.scaleBy(x: scaleX, y: -scaleY)

        drawDemoBackdrop(in: ctx, width: canvasW, height: canvasH)
        CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)

        if showCursor {
            // Convert bottom-up virtual screen coords to top-down canvas coords
            let cPt = CGPoint(x: state.mouseScreenPos.x, y: canvasH - state.mouseScreenPos.y)
            drawMacCursor(in: ctx, at: cPt, clicking: state.leftMouseDown || state.rightMouseDown)
        }

        if let cgImg = ctx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: cgImg)
            if let png = rep.representation(using: .png, properties: [:]) {
                let fn = String(format: "frame_%04d.png", frameIdx)
                try? png.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(fn)))
            }
        }
    }
}

func renderAllLiveDemos(to outDir: String) {
    // Preserve user's saved themes; use classic iconic Xiaohongshu look for the demos
    let prevEye = CatSettings.shared.eyeTheme
    let prevKb = CatSettings.shared.keyboardTheme
    let prevBadges = CatSettings.shared.showKeyBadges
    let prevFoot = CatSettings.shared.footEasterEgg

    CatSettings.shared.eyeTheme = .neonChartreuse
    CatSettings.shared.keyboardTheme = .classicMilk
    CatSettings.shared.showKeyBadges = true
    CatSettings.shared.footEasterEgg = true

    defer {
        CatSettings.shared.eyeTheme = prevEye
        CatSettings.shared.keyboardTheme = prevKb
        CatSettings.shared.showKeyBadges = prevBadges
        CatSettings.shared.footEasterEgg = prevFoot
    }

    // 1. Typing animation (3.4s)
    let typingEvents: [(Double, Double, PhysicalKey)] = [
        (0.20, 0.36, .h), (0.38, 0.54, .e), (0.56, 0.72, .l), (0.74, 0.90, .l), (0.92, 1.08, .o),
        (1.14, 1.30, .space),
        (1.34, 1.50, .k), (1.52, 1.68, .u), (1.70, 1.86, .r), (1.88, 2.04, .o),
        (2.12, 2.28, .c), (2.30, 2.46, .a), (2.48, 2.64, .t), (2.70, 2.92, .enter)
    ]
    var firedTyping = Set<Int>()
    renderSequence(name: "01_typing", outRoot: outDir, durationSec: 3.4) { t, _, physics, state, showCursor in
        showCursor = false
        var active = Set<PhysicalKey>()
        var ordered: [PhysicalKey] = []
        for (idx, (t0, t1, key)) in typingEvents.enumerated() {
            if t >= t0 && t < t1 {
                active.insert(key)
                ordered.append(key)
                if !firedTyping.contains(idx) {
                    firedTyping.insert(idx)
                    state.lastKeyActivityTime = state.now
                    physics.triggerKeyDown(key, at: state.now)
                }
            }
        }
        state.activeKeys = active
        state.orderedKeys = ordered
    }

    // 2. Fast mouse waving -> 2.5D head turn + gradually dilating HUGE round boba hunting eyes! (4.4s)
    var prevMouse2 = CGPoint(x: 184, y: 270)
    renderSequence(name: "02_hunting", outRoot: outDir, durationSec: 4.4) { t, dt, _, state, showCursor in
        showCursor = true
        let mx: CGFloat
        let my: CGFloat
        let speedBoostMultiplier: CGFloat
        if t < 1.15 {
            // Smooth curious sweep left -> right above cat's head to showcase 2.5D head turning
            let p = t / 1.15
            mx = 184 + CGFloat(sin(p * .pi * 2.0)) * 138
            my = 278 + CGFloat(cos(p * .pi * 2.0)) * 18 // top of frame (canvas y ~24..60, never blocks face!)
            speedBoostMultiplier = 0.4 // gentle gaze first, slits stay narrow!
        } else if t < 3.25 {
            // Rapid laser-pointer figure-8 darting! Smoothly dilates pupils into HUGE round boba hunting eyes!
            let p = t - 1.15
            mx = 184 + CGFloat(sin(p * 11.5)) * 145
            my = 276 + CGFloat(sin(p * 23.0)) * 22
            speedBoostMultiplier = 2.6 // maps crisp virtual canvas motion to real-screen brisk mouse waving
        } else {
            // Cursor slows & stops -> pupils smoothly shrink back from big boba -> sleek slits!
            let p = min(1.0, (t - 3.25) / 1.15)
            let ease = CGFloat(1.0 - p)
            mx = 184 + CGFloat(sin(2.1 * 11.5)) * 145 * ease
            my = 276
            speedBoostMultiplier = 0.2
        }
        let cur = CGPoint(x: mx, y: my)
        let vx = (cur.x - prevMouse2.x) / CGFloat(dt) * speedBoostMultiplier
        let vy = (cur.y - prevMouse2.y) / CGFloat(dt) * speedBoostMultiplier
        prevMouse2 = cur
        state.mouseScreenPos = cur
        state.mouseVelocity = CGVector(dx: vx, dy: vy)
        if hypot(vx, vy) > 15 {
            state.lastMouseMoveTime = state.now
        }
        state.activeKeys = []
        state.orderedKeys = []
    }

    // 3. Simultaneous typing/gaming + dragging & clicking mouse! (4.0s)
    let comboEvents: [(Double, Double, PhysicalKey)] = [
        (0.25, 0.85, .w), (0.55, 1.15, .d),
        (1.25, 1.85, .a), (1.45, 1.90, .leftShift),
        (2.05, 2.70, .w), (2.15, 2.65, .leftShift), (2.25, 2.75, .space), // 3-key hind foot!
        (2.90, 3.25, .s), (3.15, 3.45, .f)
    ]
    var firedCombo = Set<Int>()
    var prevMouse3 = CGPoint(x: 85, y: 278)
    var prevClick3 = false
    renderSequence(name: "03_typing_and_mouse", outRoot: outDir, durationSec: 4.0) { t, dt, physics, state, showCursor in
        showCursor = true
        // Smooth active gaming mouse aiming & dragging cleanly in the upper sky (never overlapping face!)
        let mx = 180 + CGFloat(sin(t * 2.6)) * 135
        let my = 278 + CGFloat(sin(t * 4.2)) * 22
        let cur = CGPoint(x: mx, y: my)
        let vx = (cur.x - prevMouse3.x) / CGFloat(dt)
        let vy = (cur.y - prevMouse3.y) / CGFloat(dt)
        prevMouse3 = cur
        state.mouseScreenPos = cur
        state.mouseVelocity = CGVector(dx: vx * 0.45, dy: vy * 0.45) // purposeful aim, not frantic hunt
        state.lastMouseMoveTime = state.now

        let clicking = (t > 0.45 && t < 0.65) || (t > 1.55 && t < 1.85) || (t > 2.40 && t < 2.65)
        state.leftMouseDown = clicking
        if clicking != prevClick3 {
            prevClick3 = clicking
            if clicking { state.lastMouseClickTime = state.now }
            physics.triggerMouseClick(button: 0, isDown: clicking)
        }

        var active = Set<PhysicalKey>()
        var ordered: [PhysicalKey] = []
        for (idx, (t0, t1, key)) in comboEvents.enumerated() {
            if t >= t0 && t < t1 {
                active.insert(key)
                ordered.append(key)
                if !firedCombo.contains(idx) {
                    firedCombo.insert(idx)
                    state.lastKeyActivityTime = state.now
                    physics.triggerKeyDown(key, at: state.now)
                }
            }
        }
        state.activeKeys = active
        state.orderedKeys = ordered
    }
}

// MARK: - Custom Background Full Showcase Video (Black Cat -> Typing -> Hunting -> Petting -> Skin Switch -> Siamese!)

private func drawOpenHandCursor(in ctx: CGContext, at pt: CGPoint) {
    ctx.saveGState()
    ctx.translateBy(x: pt.x, y: pt.y)

    // Crisp minimal macOS-style open petting hand silhouette (white fill, dark charcoal stroke)
    let hand = CGMutablePath()
    // Palm base
    hand.addRoundedRect(in: CGRect(x: -7.5, y: -1.5, width: 15, height: 12), cornerWidth: 5.5, cornerHeight: 5.5)
    // Four fingers + thumb
    hand.addRoundedRect(in: CGRect(x: -7.2, y: -10.5, width: 3.3, height: 10.5), cornerWidth: 1.6, cornerHeight: 1.6)
    hand.addRoundedRect(in: CGRect(x: -3.4, y: -12.5, width: 3.4, height: 12.5), cornerWidth: 1.7, cornerHeight: 1.7)
    hand.addRoundedRect(in: CGRect(x: 0.5,  y: -12.0, width: 3.4, height: 12.0), cornerWidth: 1.7, cornerHeight: 1.7)
    hand.addRoundedRect(in: CGRect(x: 4.3,  y: -9.5,  width: 3.1, height: 9.8),  cornerWidth: 1.5, cornerHeight: 1.5)
    hand.addRoundedRect(in: CGRect(x: -11.0, y: -1.0, width: 4.8, height: 3.4), cornerWidth: 1.6, cornerHeight: 1.6)

    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setStrokeColor(NSColor(calibratedWhite: 0.12, alpha: 1.0).cgColor)
    ctx.setLineWidth(1.5)
    ctx.addPath(hand)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()
}

private func drawToastPill(in ctx: CGContext, text: String, center: CGPoint, alpha: CGFloat, accent: NSColor) {
    guard alpha > 0.01 else { return }
    ctx.saveGState()
    ctx.setAlpha(alpha)

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
        .foregroundColor: NSColor.white
    ]
    let attrStr = NSAttributedString(string: text, attributes: attrs)
    let sz = attrStr.size()
    let padX: CGFloat = 18
    let padY: CGFloat = 9
    let rect = CGRect(
        x: center.x - (sz.width * 0.5 + padX),
        y: center.y - (sz.height * 0.5 + padY),
        width: sz.width + padX * 2,
        height: sz.height + padY * 2
    )
    let path = CGPath(roundedRect: rect, cornerWidth: rect.height * 0.5, cornerHeight: rect.height * 0.5, transform: nil)

    ctx.setFillColor(NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 0.88).cgColor)
    ctx.addPath(path)
    ctx.fillPath()

    ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
    ctx.setLineWidth(1.6)
    ctx.addPath(path)
    ctx.strokePath()

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    attrStr.draw(at: CGPoint(x: center.x - sz.width * 0.5, y: center.y - sz.height * 0.5 - 0.5))
    NSGraphicsContext.restoreGraphicsState()

    ctx.restoreGState()
}

func renderCustomShowcaseVideo(bgPath: String, outDir: String) {
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    guard let bgNSImage = NSImage(contentsOfFile: bgPath),
          let bgCGImage = bgNSImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fputs("Failed to load background image: \(bgPath)\n", stderr)
        return
    }

    let prevCoat = CatSettings.shared.coatTheme
    let prevEye = CatSettings.shared.eyeTheme
    let prevKb = CatSettings.shared.keyboardTheme
    let prevBadges = CatSettings.shared.showKeyBadges
    let prevFoot = CatSettings.shared.footEasterEgg

    CatSettings.shared.coatTheme = .classicBlack
    CatSettings.shared.eyeTheme = .neonChartreuse
    CatSettings.shared.keyboardTheme = .classicMilk
    CatSettings.shared.showKeyBadges = true
    CatSettings.shared.footEasterEgg = true

    defer {
        CatSettings.shared.coatTheme = prevCoat
        CatSettings.shared.eyeTheme = prevEye
        CatSettings.shared.keyboardTheme = prevKb
        CatSettings.shared.showKeyBadges = prevBadges
        CatSettings.shared.footEasterEgg = prevFoot
    }

    // Output resolution matches uploaded background cleanly (even dims for H.264!)
    let outW = 1024
    let outH = 780
    let fps = 30
    let durationSec = 16.5
    let totalFrames = Int(durationSec * Double(fps))
    let subSteps = 2
    let subDt = 1.0 / Double(fps * subSteps)

    // Place the cat cleanly in the lower-right desktop region (scale 1.18 -> 424.8 x 377.6)
    let catScale: CGFloat = 1.18
    let catW = CatPhysics.canvasSize.width * catScale
    let catH = CatPhysics.canvasSize.height * catScale
    let catOriginX: CGFloat = CGFloat(outW) - catW - 18.0    // ~581
    let catOriginYTop: CGFloat = CGFloat(outH) - catH - 16.0 // ~386 (top-down canvas Y)

    // Virtual macOS bottom-up screen frame for eye/head tracking math
    let winFrameBottomUp = CGRect(
        x: catOriginX,
        y: CGFloat(outH) - (catOriginYTop + catH),
        width: catW,
        height: catH
    )

    let physics = CatPhysics()
    var state = ScriptedFrameInput(
        now: 100.0,
        activeKeys: [],
        orderedKeys: [],
        mouseScreenPos: CGPoint(x: 420, y: 460),
        mouseVelocity: .zero,
        leftMouseDown: false,
        rightMouseDown: false,
        lastMouseMoveTime: 0,
        lastMouseClickTime: 0,
        lastKeyActivityTime: 0
    )

    // Act 1 (0.2s - 3.2s): Black Cat typing burst
    let act1Keys: [(Double, Double, PhysicalKey)] = [
        (0.25, 0.43, .l), (0.45, 0.63, .i), (0.65, 0.83, .f), (0.85, 1.03, .e),
        (1.08, 1.26, .space),
        (1.30, 1.48, .k), (1.50, 1.68, .l), (1.70, 1.88, .i), (1.90, 2.08, .n), (2.10, 2.28, .e),
        (2.36, 2.58, .enter), (2.68, 2.90, .a), (2.82, 3.05, .s)
    ]
    // Act 5a (10.6s - 12.8s): Siamese multitasking (mouse drag + WASD + 3-key hind foot!)
    let act5Keys: [(Double, Double, PhysicalKey)] = [
        (10.65, 11.15, .w), (10.90, 11.40, .d),
        (11.45, 11.95, .a), (11.60, 12.00, .leftShift),
        (12.05, 12.65, .w), (12.12, 12.60, .leftShift), (12.20, 12.70, .space)
    ]
    var firedAct1 = Set<Int>()
    var firedAct5 = Set<Int>()
    var switchedToSiamese = false

    // Track screen-space cursor (top-down for easy choreography, converted to bottom-up for physics)
    var prevCursorTop = CGPoint(x: 360, y: 310)
    var prevPetCanvasPt: CGPoint? = nil
    var prevClick = false

    let cs = CGColorSpaceCreateDeviceRGB()

    for frameIdx in 0..<totalFrames {
        var cursorTop = prevCursorTop
        var cursorVisible = false
        var cursorIsHand = false
        var toastText: String? = nil
        var toastAlpha: CGFloat = 0
        var skinBurstProgress: CGFloat = -1 // 0..1 right at 9.5s

        for s in 0..<subSteps {
            let t = (Double(frameIdx) + Double(s) / Double(subSteps)) / Double(fps)
            state.now = 100.0 + t

            var active = Set<PhysicalKey>()
            var ordered: [PhysicalKey] = []
            var clicking = false
            var speedMult: CGFloat = 1.0

            // --- ACT 1 (0.0 - 3.3s): Black Cat Typing ---
            if t < 3.3 {
                cursorVisible = false
                cursorTop = CGPoint(x: 420, y: 340)
                for (idx, (t0, t1, k)) in act1Keys.enumerated() {
                    if t >= t0 && t < t1 {
                        active.insert(k)
                        ordered.append(k)
                        if !firedAct1.contains(idx) {
                            firedAct1.insert(idx)
                            state.lastKeyActivityTime = state.now
                            physics.triggerKeyDown(k, at: state.now)
                        }
                    }
                }
            }
            // --- ACT 2 (3.3 - 6.9s): Mouse Follow (2.5D Head Turn) + Rapid Waving (Hunting Boba Eyes!) ---
            else if t < 6.9 {
                cursorVisible = true
                if t < 4.5 {
                    // Graceful sweep over K-line chart to showcase 2.5D head tracking
                    let p = (t - 3.3) / 1.2
                    cursorTop = CGPoint(
                        x: 420 + CGFloat(sin(p * .pi * 1.6)) * 280,
                        y: 260 - CGFloat(cos(p * .pi * 1.6)) * 120
                    )
                    speedMult = 0.35
                } else if t < 6.2 {
                    // Rapid laser-pointer darting across upper-left/mid chart -> FULL BOBA HUNTING EYES!
                    let p = t - 4.5
                    cursorTop = CGPoint(
                        x: 430 + CGFloat(sin(p * 12.5)) * 290,
                        y: 210 + CGFloat(sin(p * 25.0)) * 75
                    )
                    speedMult = 2.0
                } else {
                    // Ease gently toward the cat's head to prepare for petting
                    let p = CGFloat((t - 6.2) / 0.7)
                    let targetX = catOriginX + 184 * catScale
                    let targetY = catOriginYTop + 115 * catScale
                    cursorTop = CGPoint(
                        x: 430 + (targetX - 430) * p,
                        y: 210 + (targetY - 210) * p
                    )
                    speedMult = 0.25
                }
            }
            // --- ACT 3 (6.9 - 9.3s): Petting Black Cat's Head -> Happy Closed Lime Eyes! ---
            else if t < 9.3 {
                cursorVisible = true
                cursorIsHand = true
                let p = t - 6.9
                let headCanvasX: CGFloat = 184 + CGFloat(sin(p * 7.2)) * 26
                let headCanvasY: CGFloat = 114 + CGFloat(cos(p * 14.4)) * 7
                cursorTop = CGPoint(
                    x: catOriginX + headCanvasX * catScale,
                    y: catOriginYTop + headCanvasY * catScale
                )
                let curPetPt = CGPoint(x: headCanvasX, y: headCanvasY)
                if let prev = prevPetCanvasPt {
                    let d = hypot(curPetPt.x - prev.x, curPetPt.y - prev.y)
                    if d > 0.4 {
                        physics.registerPetStroke(canvasPoint: curPetPt, delta: d * 1.35, isHead: true, at: state.now)
                    }
                }
                prevPetCanvasPt = curPetPt
                speedMult = 0.15
            }
            // --- ACT 4 (9.3 - 10.6s): Skin Switch -> 挖煤暹罗猫! ---
            else if t < 10.6 {
                prevPetCanvasPt = nil
                cursorVisible = true
                let p = t - 9.3
                cursorTop = CGPoint(x: 470, y: 300)
                speedMult = 0.1
                if t >= 9.6 && !switchedToSiamese {
                    switchedToSiamese = true
                    CatSettings.shared.coatTheme = .siamese
                    CatSettings.shared.eyeTheme = .siameseBlue
                    physics.bodySquash.velocity -= 2.2
                    physics.earTwitch.velocity += 5.0
                }
                if t >= 9.45 && t <= 10.55 {
                    skinBurstProgress = CGFloat(max(0, min(1, (t - 9.6) / 0.6)))
                    toastText = "🐱 切换皮肤：挖煤暹罗猫"
                    let fadeIn = min(1.0, (t - 9.45) / 0.18)
                    let fadeOut = min(1.0, (10.55 - t) / 0.22)
                    toastAlpha = CGFloat(min(fadeIn, fadeOut))
                }
                _ = p
            }
            // --- ACT 5a (10.6 - 12.8s): Siamese Multitasking (Dragging Mouse + WASD + 3-Key Foot!) ---
            else if t < 12.8 {
                cursorVisible = true
                let p = t - 10.6
                cursorTop = CGPoint(
                    x: 340 + CGFloat(sin(p * 3.1)) * 220,
                    y: 250 + CGFloat(cos(p * 4.4)) * 95
                )
                speedMult = 0.32
                clicking = (p > 0.3 && p < 0.65) || (p > 1.25 && p < 1.65)

                for (idx, (t0, t1, k)) in act5Keys.enumerated() {
                    if t >= t0 && t < t1 {
                        active.insert(k)
                        ordered.append(k)
                        if !firedAct5.contains(idx) {
                            firedAct5.insert(idx)
                            state.lastKeyActivityTime = state.now
                            physics.triggerKeyDown(k, at: state.now)
                        }
                    }
                }
            }
            // --- ACT 5b (12.8 - 14.7s): Siamese Hunting Mode (Huge Sapphire-Ring Boba Eyes!) ---
            else if t < 14.7 {
                cursorVisible = true
                let p = t - 12.8
                if p < 1.35 {
                    cursorTop = CGPoint(
                        x: 420 + CGFloat(sin(p * 13.0)) * 295,
                        y: 200 + CGFloat(sin(p * 26.0)) * 70
                    )
                    speedMult = 2.1
                } else {
                    let q = CGFloat((p - 1.35) / 0.55)
                    let targetX = catOriginX + 184 * catScale
                    let targetY = catOriginYTop + 114 * catScale
                    cursorTop = CGPoint(
                        x: 420 + (targetX - 420) * q,
                        y: 200 + (targetY - 200) * q
                    )
                    speedMult = 0.2
                }
            }
            // --- ACT 5c (14.7 - 16.5s): Petting Siamese Head -> Happy Closed Blue Eyes! ---
            else {
                cursorVisible = true
                cursorIsHand = true
                let p = t - 14.7
                let headCanvasX: CGFloat = 184 + CGFloat(sin(p * 7.0)) * 25
                let headCanvasY: CGFloat = 114 + CGFloat(cos(p * 14.0)) * 6
                cursorTop = CGPoint(
                    x: catOriginX + headCanvasX * catScale,
                    y: catOriginYTop + headCanvasY * catScale
                )
                let curPetPt = CGPoint(x: headCanvasX, y: headCanvasY)
                if let prev = prevPetCanvasPt {
                    let d = hypot(curPetPt.x - prev.x, curPetPt.y - prev.y)
                    if d > 0.4 {
                        physics.registerPetStroke(canvasPoint: curPetPt, delta: d * 1.35, isHead: true, at: state.now)
                    }
                }
                prevPetCanvasPt = curPetPt
                speedMult = 0.12
            }

            // Convert top-down cursor -> bottom-up macOS screen coords & velocity
            let vx = (cursorTop.x - prevCursorTop.x) / CGFloat(subDt) * speedMult
            let vy = -(cursorTop.y - prevCursorTop.y) / CGFloat(subDt) * speedMult
            prevCursorTop = cursorTop

            state.mouseScreenPos = CGPoint(x: cursorTop.x, y: CGFloat(outH) - cursorTop.y)
            state.mouseVelocity = CGVector(dx: vx, dy: vy)
            if cursorVisible && hypot(vx, vy) > 12 {
                state.lastMouseMoveTime = state.now
            }

            state.leftMouseDown = clicking
            if clicking != prevClick {
                prevClick = clicking
                if clicking { state.lastMouseClickTime = state.now }
                physics.triggerMouseClick(button: 0, isDown: clicking)
            }

            state.activeKeys = active
            state.orderedKeys = ordered

            physics.step(dt: CGFloat(subDt), windowFrameInScreen: winFrameBottomUp, scripted: state)
        }

        // Render composited frame (User's K-Line Screenshot + Live Cat + Cursor + Skin Toast)
        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { continue }

        // 1. Draw background image cleanly right-side-up (CGContext default is bottom-up)
        ctx.draw(bgCGImage, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        // 2. Flip to top-down coordinates for CatRenderer & overlays
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(outH))
        ctx.scaleBy(x: 1.0, y: -1.0)

        // Draw Cat in lower-right desktop area
        ctx.saveGState()
        ctx.translateBy(x: catOriginX, y: catOriginYTop)
        ctx.scaleBy(x: catScale, y: catScale)
        CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
        ctx.restoreGState()

        // Magical ring pop right at skin switch moment
        if skinBurstProgress > 0 && skinBurstProgress < 1 {
            let center = CGPoint(x: catOriginX + 184 * catScale, y: catOriginYTop + 175 * catScale)
            let radius = 40 + skinBurstProgress * 130
            let alpha = (1.0 - skinBurstProgress) * 0.65
            ctx.saveGState()
            ctx.setStrokeColor(EyeColorTheme.siameseBlue.primaryColor.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(4.0 * (1.0 - skinBurstProgress))
            ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            ctx.restoreGState()
        }

        // Skin-switch translucent macOS toast pill above the cat
        if let text = toastText, toastAlpha > 0.01 {
            drawToastPill(
                in: ctx,
                text: text,
                center: CGPoint(x: catOriginX + 184 * catScale, y: catOriginYTop + 26),
                alpha: toastAlpha,
                accent: EyeColorTheme.siameseBlue.primaryColor
            )
        }

        // Realistic cursor (arrow or open petting hand!)
        if cursorVisible {
            if cursorIsHand {
                drawOpenHandCursor(in: ctx, at: cursorTop)
            } else {
                drawMacCursor(in: ctx, at: cursorTop, clicking: state.leftMouseDown)
            }
        }

        ctx.restoreGState()

        if let cgImg = ctx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: cgImg)
            if let png = rep.representation(using: .png, properties: [:]) {
                let fn = String(format: "frame_%04d.png", frameIdx)
                try? png.write(to: URL(fileURLWithPath: (outDir as NSString).appendingPathComponent(fn)))
            }
        }
    }
}

// 从改名前的 KuroCat 迁移设置（必须早于任何 CatSettings / InputEngine 读取偏好）
LegacyMigration.runIfNeeded()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
