// VMConfig 编解码与后端路由测试
import Testing
import Foundation
@testable import HVMCore

@Test
func vmConfigRoundTrip() throws {
    let original = VMConfig(
        name: "ubuntu-test",
        architecture: .aarch64,
        cpuCount: 4,
        memoryMB: 4096,
        disks: [DiskConfig(relativePath: "disks/main.qcow2", sizeGB: 40)]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(VMConfig.self, from: data)

    #expect(decoded.name == "ubuntu-test")
    #expect(decoded.architecture == .aarch64)
    #expect(decoded.cpuCount == 4)
    #expect(decoded.memoryMB == 4096)
    #expect(decoded.disks.count == 1)
    #expect(decoded.disks.first?.relativePath == "disks/main.qcow2")
}

@Test
func vmStateIsStable() {
    #expect(VMState.stopped.isStable)
    #expect(VMState.running.isStable)
    #expect(!VMState.starting.isStable)
    #expect(!VMState.stopping.isStable)
}
