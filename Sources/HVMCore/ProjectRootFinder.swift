// 开发模式下从可执行文件向上回溯定位项目根
//
// swift run/build 的产物通常在 .build/<triple>/<config>/<binary>, 从这里向上回溯若干层
// 即可到达仓库根. 运行生产 .app 时不会走到这里 —— 调用方有更优先的 Bundle.main 路径分支.
import Foundation

public enum ProjectRootFinder {
    /// 从可执行文件所在目录向上回溯, 查找含 marker 的祖先目录.
    ///
    /// - Parameters:
    ///   - marker: 用作识别的相对路径, 例如 "Vendor/qemu/bin/qemu-img"
    ///   - maxLevels: 最多向上回溯的层数. 默认 6, 对 `.build/<triple>/<config>/bin` 这种
    ///                三层深度有冗余. 过大没用, 过小会在个别 swift build 产物位置漏检.
    ///   - isExecutable: true 时要求 marker 是可执行文件(脚本/二进制); false 时只要存在即可.
    /// - Returns: 找到的祖先目录 URL, 找不到返回 nil.
    public static func ancestor(
        containing marker: String,
        maxLevels: Int = 6,
        isExecutable: Bool = true
    ) -> URL? {
        let fm = FileManager.default
        var cursor = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<maxLevels {
            let probe = cursor.appendingPathComponent(marker)
            let hit = isExecutable
                ? fm.isExecutableFile(atPath: probe.path)
                : fm.fileExists(atPath: probe.path)
            if hit {
                return cursor
            }
            cursor = cursor.deletingLastPathComponent()
        }
        return nil
    }
}
