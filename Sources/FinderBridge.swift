import AppKit
import QuickLookThumbnailing

// MARK: - Finder Bridge

/// 踢飞文件时和 Finder 打交道的几件事：照 Finder 的样子取缩略图、请 Finder 把文件移到废纸篓（顺便问桌面上的图标在哪）。
/// 移文件走 osascript 子进程（Apple Events），第一次会弹「CoolCat 想控制 Finder」的授权
enum FinderBridge {
    /// 和 Finder 里看到的一样的图标：内容缩略图（文本前几行、图片 / PDF 预览，带页角和边框），没有就是类型图标。
    /// 几个文件一起生成，最多等 0.8 秒，等不到的用类型图标
    static func thumbnails(for urls: [URL], size: CGFloat, completion: @escaping ([NSImage?]) -> Void) {
        var icons: [NSImage?] = urls.map { NSWorkspace.shared.icon(forFile: $0.path) }
        var pending = urls.count
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            completion(icons)
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for (index, url) in urls.enumerated() {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                       scale: scale, representationTypes: .all)
            request.iconMode = true
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                DispatchQueue.main.async {
                    if let image = thumbnail?.nsImage { icons[index] = image }
                    pending -= 1
                    if pending == 0 { finish() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { finish() }
    }

    enum Failure: Error, Equatable {
        /// 你没允许 CoolCat 控制 Finder（-1743）
        case notAuthorized
        case failed
    }

    /// Finder 删一个文件的结果：删之前它在桌面上的位置（屏幕坐标，只有桌面上的才有）、在废纸篓里的位置
    struct Trashed {
        var desktopSpot: CGPoint?
        var inTrash: URL?
        var trashed: Bool
    }

    /// 先问一下 Finder 的名字：没授权就在这一步整个失败（-1743），不会被下面每个文件的 try 吞掉。
    /// 每个文件输出一行「桌面位置<tab>废纸篓里的路径」，拿不到的写「-」
    private static let trashScript = """
    on run argv
        set out to ""
        tell application "Finder"
            set probe to name
            repeat with p in argv
                set spot to "-"
                set gone to "-"
                try
                    set f to (POSIX file (contents of p)) as alias
                    try
                        set pos to desktop position of f
                        set spot to ((item 1 of pos) as text) & "," & ((item 2 of pos) as text)
                    end try
                    set trashed to delete f
                    set gone to POSIX path of (trashed as alias)
                end try
                set out to out & spot & tab & gone & linefeed
            end repeat
        end tell
        return out
    end run
    """

    /// 请 Finder 把这些文件一次移到废纸篓（和 ⌘⌫ 一样，能「放回原处」），顺便问桌面上的文件图标在哪。
    /// 用 osascript 子进程发，不卡主线程；第一次会弹「CoolCat 想控制 Finder」的授权
    static func trash(_ urls: [URL]) -> Result<[Trashed], Failure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", trashScript] + urls.map(\.path)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failure(.failed)
        }
        // 先读完输出再等它退出：输出多了管道会塞满，两边互相等
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failure(message.contains("-1743") ? .notAuthorized : .failed)
        }
        return .success(parse(text, for: urls))
    }

    /// 一行对应一个文件；只认桌面上的文件的位置（别处的 desktop position 没意义）
    private static func parse(_ text: String, for urls: [URL]) -> [Trashed] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop").standardizedFileURL
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return urls.enumerated().map { index, url in
            let fields = index < lines.count ? lines[index].components(separatedBy: "\t") : []
            let gone = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : "-"
            let onDesktop = url.deletingLastPathComponent().standardizedFileURL == desktop
            let spot = onDesktop ? fields.first.flatMap(screenPoint(fromFinderDesktop:)) : nil
            let inTrash = gone == "-" ? nil : URL(fileURLWithPath: gone)
            return Trashed(desktopSpot: spot, inTrash: inTrash, trashed: inTrash != nil)
        }
    }

    /// Finder 的桌面坐标（原点在所有屏幕拼起来的左上角、y 向下，是图标中心）→ 屏幕坐标
    private static func screenPoint(fromFinderDesktop text: String) -> CGPoint? {
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        let frames = NSScreen.screens.map(\.frame)
        guard let top = frames.map(\.maxY).max(), let left = frames.map(\.minX).min() else { return nil }
        return CGPoint(x: left + CGFloat(parts[0]), y: top - CGFloat(parts[1]))
    }
}
