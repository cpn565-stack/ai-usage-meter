import Foundation
import CommonCrypto

enum Crypto {
    /// PBKDF2-HMAC-SHA1 → 派生金鑰。
    static func pbkdf2SHA1(password: Data, salt: Data, rounds: Int, keyLength: Int) -> Data {
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { (dPtr: UnsafeMutableRawBufferPointer) -> Int32 in
            password.withUnsafeBytes { (pPtr: UnsafeRawBufferPointer) -> Int32 in
                salt.withUnsafeBytes { (sPtr: UnsafeRawBufferPointer) -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pPtr.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                        sPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(rounds),
                        dPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : Data()
    }

    /// AES-128-CBC 解密(PKCS7 padding)。
    static func aesCBCDecrypt(cipher: Data, key: Data, iv: Data) -> Data? {
        let bufSize = cipher.count + kCCBlockSizeAES128
        var out = Data(count: bufSize)
        var moved = 0
        let status = out.withUnsafeMutableBytes { (oPtr: UnsafeMutableRawBufferPointer) -> Int32 in
            cipher.withUnsafeBytes { (cPtr: UnsafeRawBufferPointer) -> Int32 in
                key.withUnsafeBytes { (kPtr: UnsafeRawBufferPointer) -> Int32 in
                    iv.withUnsafeBytes { (ivPtr: UnsafeRawBufferPointer) -> Int32 in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            kPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            cPtr.baseAddress, cipher.count,
                            oPtr.baseAddress, bufSize, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    /// AES-128-CBC 加密(PKCS7 padding)。
    static func aesCBCEncrypt(plain: Data, key: Data, iv: Data) -> Data? {
        let bufSize = plain.count + kCCBlockSizeAES128
        var out = Data(count: bufSize)
        var moved = 0
        let status = out.withUnsafeMutableBytes { (oPtr: UnsafeMutableRawBufferPointer) -> Int32 in
            plain.withUnsafeBytes { (pPtr: UnsafeRawBufferPointer) -> Int32 in
                key.withUnsafeBytes { (kPtr: UnsafeRawBufferPointer) -> Int32 in
                    iv.withUnsafeBytes { (ivPtr: UnsafeRawBufferPointer) -> Int32 in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            kPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            pPtr.baseAddress, plain.count,
                            oPtr.baseAddress, bufSize, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    /// 反向:把明文加密成 Electron safeStorage 的 v10 base64 字串。
    static func encryptElectronV10(plaintext: Data, keychainPassword: Data) -> String? {
        let key = pbkdf2SHA1(password: keychainPassword, salt: Data("saltysalt".utf8), rounds: 1003, keyLength: 16)
        let iv = Data(repeating: 0x20, count: 16)
        guard let ct = aesCBCEncrypt(plain: plaintext, key: key, iv: iv) else { return nil }
        return (Data("v10".utf8) + ct).base64EncodedString()
    }

    /// 解 Electron safeStorage 的 v10 blob:base64 → 去掉 "v10" → AES-128-CBC。
    static func decryptElectronV10(base64Value: String, keychainPassword: Data) throws -> Data {
        guard let raw = Data(base64Encoded: base64Value) else {
            throw ProviderError.decrypt("base64 解碼失敗")
        }
        guard raw.count > 3, raw.prefix(3) == Data("v10".utf8) else {
            throw ProviderError.decrypt("非 v10 前綴")
        }
        let cipher = raw.dropFirst(3)
        let key = pbkdf2SHA1(password: keychainPassword, salt: Data("saltysalt".utf8), rounds: 1003, keyLength: 16)
        let iv = Data(repeating: 0x20, count: 16)
        guard let pt = aesCBCDecrypt(cipher: Data(cipher), key: key, iv: iv) else {
            throw ProviderError.decrypt("AES 解密失敗")
        }
        return pt
    }
}
