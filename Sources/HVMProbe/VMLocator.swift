// VM 定位器 —— <vm> 参数解析成 VMBundle
//
// 支持两种写法:
//   1. bundle 名字 (推荐, 如 "Windows11") → 拼成
//      ~/Library/Application Support/HellVM/VMs/Windows11.hellvm
//   2. 绝对路径(含 .hellvm 后缀)

import Foundation
import HVMBundle

enum VMLocator {
    static func resolve(_ input: String) throws -> VMBundle {
        let fm = FileManager.default
        // 绝对路径(以 / 开头或含 .hellvm)
        let asPath = (input as NSString).expandingTildeInPath
        if asPath.hasPrefix("/") || asPath.hasSuffix(".hellvm") {
            let url = URL(fileURLWithPath: asPath)
            guard fm.fileExists(atPath: url.path) else {
                throw ProbeError.vmNotFound("bundle 路径不存在: \(url.path)")
            }
            return VMBundle(url: url)
        }
        // 否则当 bundle 名字
        let libURL = VMBundle.defaultLibraryURL
        let bundleURL = libURL.appendingPathComponent("\(input).hellvm")
        guard fm.fileExists(atPath: bundleURL.path) else {
            throw ProbeError.vmNotFound("找不到 VM '\(input)': \(bundleURL.path)")
        }
        return VMBundle(url: bundleURL)
    }
}

enum ProbeError: LocalizedError {
    case vmNotFound(String)
    case vmNotRunning(String)
    case socketConnectFailed(String)
    case protocolError(String)
    case pngEncodeFailed(String)
    case unknownKey(String)

    var errorDescription: String? {
        switch self {
        case .vmNotFound(let s):           return "VM 未找到: \(s)"
        case .vmNotRunning(let s):         return "VM 未运行: \(s)"
        case .socketConnectFailed(let s):  return "socket 连接失败: \(s)"
        case .protocolError(let s):        return "协议错误: \(s)"
        case .pngEncodeFailed(let s):      return "PNG 编码失败: \(s)"
        case .unknownKey(let s):           return "未知键名: \(s)"
        }
    }
}
