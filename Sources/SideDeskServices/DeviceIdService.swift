import CryptoKit
import Foundation
import IOKit
import SideDeskCore

/// 设备唯一标识服务。对应 C# `Services.DeviceIdService`（Windows 用 CPU ID + MAC 哈希；
/// macOS 无 WMI，改用 IOPlatformUUID 硬件标识，同样 SHA256 为 64 位十六进制小写串）。
/// 值在进程内只计算一次并缓存；读取失败回退主机名，保证始终返回非空 ID。
public enum DeviceIdService {

    /// 设备唯一 ID（SHA256 十六进制小写串，64 位）
    public static let deviceId: String = buildDeviceId()

    private static func buildDeviceId() -> String {
        let uuid = platformUUID() ?? ""
        let raw = uuid.isEmpty ? ProcessInfo.processInfo.hostName : uuid
        let hash = SHA256.hash(data: Data(raw.utf8))
        let id = hash.map { String(format: "%02x", $0) }.joined()
        RuntimeLog.debug("[DeviceId] device unique ID: \(id)")
        return id
    }

    /// 读 IOPlatformExpertDevice 的 IOPlatformUUID（主板级稳定标识，重装系统不变）
    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString,
                                                         kCFAllocatorDefault, 0) else { return nil }
        return prop.takeRetainedValue() as? String
    }
}