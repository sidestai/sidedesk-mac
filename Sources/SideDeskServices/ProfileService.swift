import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SideDeskCore
import UniformTypeIdentifiers

/// 本人资料同步（昵称/头像）。对应 C# `FriendService` 的第 10/11 节
/// （UpdateMyProfileAsync / UploadAvatarToCacheAsync / PutBytesToOssAsync），
/// STS 凭证接口取自 `CloudDriveService.RequestStsTokenAsync`（云盘整体未移植，仅搬头像所需的最小片段）。
public final class ProfileService {

    private let api = BackendApiClient(logTag: "[Profile]", timeout: 30)
    private var ossCacheConfig: OssCacheConfig?

    public init() {}

    /// PUT /api/friend/profile — { nickName?, avatar? }，变更后后端实时通知好友。
    /// 返回 (ok, msg)；传输失败时 msg 为网络错误占位（与 C# NetError 同口径）。
    public func updateMyProfile(nickName: String?, avatar: String?) async -> (Bool, String) {
        var body: [String: JSONValue] = [:]
        if let nickName { body["nickName"] = .string(nickName) }
        if let avatar { body["avatar"] = .string(avatar) }
        let r = await api.send("PUT", "/api/friend/profile", body: .object(body))
        return (r.ok, r.transportFailed ? "network error" : r.msg)
    }

    /// 头像图片直传 OSS 缓存区（STS 凭证 → V1 签名直传），返回公读访问 URL；失败返回 nil。
    /// ossKey 格式：{avatarPrefix}/{yyyyMMddHHmmssfff}_{随机}.jpg
    public func uploadAvatarToCache(_ imageBytes: Data) async -> String? {
        guard !imageBytes.isEmpty else { return nil }
        guard let cfg = await getOssCacheConfig(), !cfg.domain.isEmpty else { return nil }
        guard let sts = await requestStsToken(), !sts.accessKeyId.isEmpty else { return nil }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMddHHmmssSSS"
        let prefix = cfg.avatarPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let ossKey = "\(prefix)/\(fmt.string(from: Date()))_\(Int.random(in: 1000..<10000)).jpg"
        // 上传目标 bucket/region 以后端 ossCache 配置为准（STS 响应里的仅作兜底）
        let bucket = cfg.bucket.isEmpty ? sts.bucket : cfg.bucket
        let region = cfg.region.isEmpty ? sts.region : cfg.region
        // bucket 为私有 ACL 时，头像对象须单独设 public-read 才能匿名访问
        guard await putBytesToOss(sts: sts, bucket: bucket, region: region, ossKey: ossKey,
                                  data: imageBytes, contentType: "image/jpeg", publicRead: true) else { return nil }
        return cfg.domain.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + ossKey
    }

    /// 把图片文件缩放为不超过 256px 的 JPEG 并转 base64（对应 C# `AccountSeam.PrepareAvatarBase64`，
    /// WPF BitmapImage 换 ImageIO 缩略图 + JPEG 编码）。失败返回 nil。
    public static func prepareAvatarBase64(filePath: String) -> String? {
        let url = URL(fileURLWithPath: filePath)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data).base64EncodedString()
    }

    // MARK: - OSS 直传内部

    /// 云盘缓存配置（后端 ossCache 配置下发，结果缓存）
    private struct OssCacheConfig: Decodable {
        var bucket = ""
        var region = ""
        var domain = ""
        var avatarPrefix = "cache/avatar"
    }

    private func getOssCacheConfig() async -> OssCacheConfig? {
        if let ossCacheConfig { return ossCacheConfig }
        let cfg: OssCacheConfig? = await api.sendObject("GET", "/api/friend/ossCacheConfig")
        ossCacheConfig = cfg
        return cfg
    }

    /// STS 临时凭证（OSS 直传）。对应 C# `CloudDriveService.RequestStsTokenAsync`。
    private struct StsToken: Decodable {
        var accessKeyId = ""
        var accessKeySecret = ""
        var securityToken = ""
        var bucket = ""
        var region = ""
    }

    private func requestStsToken() async -> StsToken? {
        let corp = BackendApiClient.queryValue(Seam.settings.SelectedCorpId ?? "")
        return await api.sendObject("POST", "/api/common/upload/request-sts-token?corpid=" + corp)
    }

    /// OSS V1 签名直传（publicRead=true 时对象 ACL 设公读）。第三方协议不走统一信封，用裸客户端。
    private func putBytesToOss(sts: StsToken, bucket: String, region: String, ossKey: String,
                               data: Data, contentType: String, publicRead: Bool) async -> Bool {
        guard let url = URL(string: "https://\(bucket).\(region).aliyuncs.com/\(ossKey)") else { return false }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = fmt.string(from: Date())

        // x-oss-* 头须按字典序拼接参与签名（object-acl 在 security-token 之前）
        let ossHeaders = publicRead
            ? "x-oss-object-acl:public-read\nx-oss-security-token:\(sts.securityToken)\n"
            : "x-oss-security-token:\(sts.securityToken)\n"
        let stringToSign = "PUT\n\n\(contentType)\n\(date)\n\(ossHeaders)/\(bucket)/\(ossKey)"
        let key = SymmetricKey(data: Data(sts.accessKeySecret.utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        let signature = Data(mac).base64EncodedString()

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.httpBody = data
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue(date, forHTTPHeaderField: "Date")
        req.setValue("OSS \(sts.accessKeyId):\(signature)", forHTTPHeaderField: "Authorization")
        if publicRead { req.setValue("public-read", forHTTPHeaderField: "x-oss-object-acl") }
        req.setValue(sts.securityToken, forHTTPHeaderField: "x-oss-security-token")

        do {
            let (body, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                RuntimeLog.debug("[Profile] 头像 OSS 上传失败: HTTP \(status) - \(String(data: body, encoding: .utf8) ?? "")")
                return false
            }
            return true
        } catch {
            RuntimeLog.debug("[Profile] 头像 OSS 上传异常: \(error.localizedDescription)")
            return false
        }
    }
}