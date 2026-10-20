import Darwin
import Foundation
import Security

/// What the inspector shows for one process. Read on demand, never during a scan:
/// the signature check alone can take tens of milliseconds.
public struct ProcessDetails: Codable, Sendable, Equatable {
    public var pid: Int32
    public var arguments: [String]
    public var workingDirectory: String?
    public var user: String?
    public var signature: Signature?

    public struct Signature: Codable, Sendable, Equatable {
        public var identifier: String?
        public var teamID: String?
        /// "Apple", "Developer ID", "App Store", "Ad hoc" or "Unsigned".
        public var authority: String
        public var sandboxed: Bool
        public var hardenedRuntime: Bool
        public var valid: Bool
    }

    public static func read(pid: Int32, signature wantsSignature: Bool = true) -> ProcessDetails {
        var details = ProcessDetails(pid: pid, arguments: arguments(pid: pid) ?? [], workingDirectory: workingDirectory(pid: pid))
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, let pw = getpwuid(info.pbsi_uid) {
            details.user = String(cString: pw.pointee.pw_name)
        }
        if wantsSignature { details.signature = signature(pid: pid) }
        return details
    }

    /// argv from KERN_PROCARGS2. Only works for processes this user owns.
    public static func arguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        // The executable path comes first, then padding NULs, then argv.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    public static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    public static func signature(pid: Int32) -> Signature? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }

        var raw: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &raw) == errSecSuccess, let info = raw as? [String: Any] else {
            return Signature(identifier: nil, teamID: nil, authority: "Unsigned", sandboxed: false, hardenedRuntime: false, valid: false)
        }
        let valid = SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess
        let codeFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let leaf = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? ""
        let isPlatform = (info[kSecCodeInfoPlatformIdentifier as String] as? NSNumber) != nil

        let authority: String
        if isPlatform || leaf.hasPrefix("Software Signing") {
            authority = "Apple"
        } else if certificates.isEmpty {
            authority = (codeFlags & 0x2) != 0 ? "Ad hoc" : "Unsigned"
        } else if leaf.hasPrefix("Developer ID") {
            authority = "Developer ID"
        } else if leaf.contains("Apple Mac OS Application Signing") || leaf.hasPrefix("Apple iPhone OS Application Signing") {
            authority = "App Store"
        } else {
            authority = leaf.isEmpty ? "Unknown" : leaf
        }

        return Signature(identifier: info[kSecCodeInfoIdentifier as String] as? String,
                         teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
                         authority: authority,
                         sandboxed: (entitlements?["com.apple.security.app-sandbox"] as? Bool) ?? false,
                         hardenedRuntime: (codeFlags & 0x10000) != 0,
                         valid: valid)
    }
}
