import Foundation
import CommonCrypto
import Security

struct SlackCredentials: Equatable {
    let token: String      // xoxc-...
    let cookieD: String    // xoxd-... (decrypted d cookie value)
}

enum SlackExtractError: LocalizedError {
    case slackDirNotFound
    case noTokenFound
    case cookiesDBNotFound
    case cookieRowNotFound
    case unexpectedCookieFormat(String)
    case keychainAccessDenied
    case decryptionFailed
    case sqliteCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case .slackDirNotFound:
            return "Slack のデータディレクトリが見つかりません (Slack 未インストール?)"
        case .noTokenFound:
            return "Slack の認証トークンが見つかりません (Slack に未ログイン?)"
        case .cookiesDBNotFound:
            return "Slack の Cookies DB が見つかりません"
        case .cookieRowNotFound:
            return "Slack の認証クッキー (d) が見つかりません"
        case .unexpectedCookieFormat(let s):
            return "Cookie の形式が想定外: \(s)"
        case .keychainAccessDenied:
            return "「Slack Safe Storage」キーチェーン項目へのアクセスが拒否されました"
        case .decryptionFailed:
            return "Cookie の復号に失敗 (Slack バージョンが新しい可能性)"
        case .sqliteCommandFailed(let s):
            return "sqlite3 コマンド失敗: \(s)"
        }
    }
}

/// Reads Slack's xoxc token + decrypted `d` cookie from the local desktop install.
/// Works for Slack Electron apps using the standard Chromium cookie encryption
/// (PBKDF2-HMAC-SHA1 / AES-128-CBC, key from macOS Keychain "Slack Safe Storage").
final class SlackCredentialExtractor {
    private let slackDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Slack")

    func extract() throws -> SlackCredentials {
        guard FileManager.default.fileExists(atPath: slackDir.path) else {
            throw SlackExtractError.slackDirNotFound
        }
        let token = try extractToken()
        let cookieD = try extractCookieD()
        return SlackCredentials(token: token, cookieD: cookieD)
    }

    // MARK: - Token (from LevelDB)

    private func extractToken() throws -> String {
        let leveldbDir = slackDir.appendingPathComponent("Local Storage/leveldb")
        guard FileManager.default.fileExists(atPath: leveldbDir.path) else {
            throw SlackExtractError.noTokenFound
        }
        let regex = try NSRegularExpression(pattern: #"xoxc-[0-9]+-[0-9]+-[0-9]+-[a-f0-9]+"#)

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: leveldbDir, includingPropertiesForKeys: nil
        )) ?? []
        // Try .log files first (most recent writes), then .ldb files
        let prioritized = urls.sorted { a, b in
            let aExt = a.pathExtension == "log" ? 0 : 1
            let bExt = b.pathExtension == "log" ? 0 : 1
            if aExt != bExt { return aExt < bExt }
            return a.lastPathComponent > b.lastPathComponent
        }

        for url in prioritized {
            let ext = url.pathExtension
            guard ext == "ldb" || ext == "log" else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            // Treat bytes as Latin-1 so all bytes map 1:1 to characters
            guard let str = String(data: data, encoding: .isoLatin1) else { continue }
            let nsstr = str as NSString
            let range = NSRange(location: 0, length: nsstr.length)
            if let match = regex.firstMatch(in: str, range: range) {
                return nsstr.substring(with: match.range)
            }
        }
        throw SlackExtractError.noTokenFound
    }

    // MARK: - Cookie (d) via sqlite3 + Keychain + AES-128-CBC

    private func extractCookieD() throws -> String {
        let cookiesPath = slackDir.appendingPathComponent("Cookies").path
        guard FileManager.default.fileExists(atPath: cookiesPath) else {
            throw SlackExtractError.cookiesDBNotFound
        }

        // Shell out to sqlite3 to read the encrypted_value as hex
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = [
            cookiesPath,
            "SELECT hex(encrypted_value) FROM cookies WHERE name='d' LIMIT 1"
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            throw SlackExtractError.sqliteCommandFailed(error.localizedDescription)
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? "exit \(task.terminationStatus)"
            throw SlackExtractError.sqliteCommandFailed(errStr)
        }
        let hexStr = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !hexStr.isEmpty else { throw SlackExtractError.cookieRowNotFound }
        guard let encrypted = Data(hexString: hexStr) else {
            throw SlackExtractError.unexpectedCookieFormat("not hex")
        }
        // Must start with "v10"
        let v10 = Data([0x76, 0x31, 0x30])
        guard encrypted.starts(with: v10) else {
            throw SlackExtractError.unexpectedCookieFormat("missing v10 prefix")
        }
        let ciphertext = encrypted.subdata(in: 3..<encrypted.count)

        // Key from macOS Keychain
        guard let kcPassword = getSlackSafeStoragePassword() else {
            throw SlackExtractError.keychainAccessDenied
        }
        guard let key = pbkdf2SHA1(password: kcPassword, salt: "saltysalt",
                                   iterations: 1003, keyLength: 16) else {
            throw SlackExtractError.decryptionFailed
        }

        // AES-128-CBC, IV = 16 spaces
        let iv = Data(repeating: 0x20, count: 16)
        guard let decrypted = aesDecryptCBC(ciphertext, key: key, iv: iv) else {
            throw SlackExtractError.decryptionFailed
        }

        // Newer macOS prepends a 32-byte SHA-256 of the cookie name+value as integrity.
        // If the plaintext doesn't start with "xoxd-" but skipping 32 bytes does, strip it.
        var plain = decrypted
        let xoxdPrefix = Data("xoxd-".utf8)
        if !plain.starts(with: xoxdPrefix), plain.count > 32 {
            let candidate = plain.subdata(in: 32..<plain.count)
            if candidate.starts(with: xoxdPrefix) {
                plain = candidate
            }
        }
        guard let s = String(data: plain, encoding: .utf8), !s.isEmpty else {
            throw SlackExtractError.decryptionFailed
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Keychain access (Security framework, no subprocess)

    private func getSlackSafeStoragePassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Slack Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Crypto helpers

    private func pbkdf2SHA1(password: String, salt: String,
                            iterations: Int, keyLength: Int) -> Data? {
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array(salt.utf8)
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes, passwordBytes.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            UInt32(iterations),
            &derived, keyLength
        )
        guard status == kCCSuccess else { return nil }
        return Data(derived)
    }

    private func aesDecryptCBC(_ ciphertext: Data, key: Data, iv: Data) -> Data? {
        var outBuf = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = ciphertext.withUnsafeBytes { ctPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress, key.count,
                        ivPtr.baseAddress,
                        ctPtr.baseAddress, ciphertext.count,
                        &outBuf, outBuf.count,
                        &outLen
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(bytes: outBuf, count: outLen)
    }
}

private extension Data {
    init?(hexString: String) {
        let cleaned = hexString.filter { $0.isHexDigit }
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        self = data
    }
}
