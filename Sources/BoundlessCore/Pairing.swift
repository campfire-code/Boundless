import CommonCrypto
import Foundation

/// 配对码：12 位（约 59 bit 熵），去掉易混淆的 I/L/O/0/1
public enum Pairing {
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    private static let length = 12

    public static func generateCode() -> String {
        var rng = SystemRandomNumberGenerator()
        let chars = (0..<length).map { _ in alphabet.randomElement(using: &rng)! }
        return format(chars)
    }

    /// 规范化用户输入（忽略大小写、空格、横线），不合法返回 nil
    public static func normalize(_ input: String) -> String? {
        let chars = Array(input.uppercased().filter { !$0.isWhitespace && $0 != "-" })
        guard chars.count == length, chars.allSatisfy(alphabet.contains) else { return nil }
        return format(chars)
    }

    /// 由配对码派生 TLS 预共享密钥（PBKDF2-SHA256，提高离线暴力破解成本）
    public static func presharedKey(for code: String) -> Data {
        let password = normalize(code) ?? code
        let salt = Array("boundless-pairing-v1".utf8)
        var key = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
            salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
            &key, key.count)
        precondition(status == kCCSuccess, "PBKDF2 失败：\(status)")
        return Data(key)
    }

    private static func format(_ chars: [Character]) -> String {
        stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }
}
