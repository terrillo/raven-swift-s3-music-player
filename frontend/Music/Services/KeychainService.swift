//
//  KeychainService.swift
//  Music
//
//  Secure storage for S3 credentials using macOS Keychain.
//

import Foundation
import Security

// MARK: - S3 Credentials

struct S3Credentials: Codable, Equatable {
    var accessKey: String
    var secretKey: String
    var bucket: String
    var region: String
    var prefix: String
    var lastFMApiKey: String

    var isValid: Bool {
        !accessKey.isEmpty && !secretKey.isEmpty && !bucket.isEmpty && !region.isEmpty
    }

    /// The endpoint URL for DigitalOcean Spaces (virtual-hosted style with bucket in hostname)
    var endpoint: String {
        "https://\(bucket).\(region).digitaloceanspaces.com"
    }

    /// The CDN URL base for public files
    var cdnBaseUrl: String {
        "https://\(bucket).\(region).cdn.digitaloceanspaces.com/\(prefix)"
    }

    static let empty = S3Credentials(
        accessKey: "",
        secretKey: "",
        bucket: "",
        region: "sfo3",
        prefix: "music",
        lastFMApiKey: ""
    )
}

// MARK: - KeychainService

#if os(macOS)

/// Service for securely storing S3 credentials in macOS Keychain.
@MainActor
@Observable
class KeychainService {
    private let serviceName = "com.terrillo.music.s3credentials"
    private let accountName = "default"

    private(set) var credentials: S3Credentials = .empty
    private(set) var isLoaded: Bool = false

    init() {
        loadCredentials()
    }

    // MARK: - Public Methods

    /// Save credentials to Keychain
    func saveCredentials(_ credentials: S3Credentials) throws {
        let data = try JSONEncoder().encode(credentials)

        // Delete existing item if present
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToSave(status: status)
        }

        self.credentials = credentials
    }

    /// Load credentials from Keychain
    func loadCredentials() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        isLoaded = true

        if status == errSecSuccess, let data = result as? Data {
            if let decoded = try? JSONDecoder().decode(S3Credentials.self, from: data) {
                self.credentials = decoded
                return
            }
        }

        self.credentials = .empty
    }

    /// Delete credentials from Keychain
    func deleteCredentials() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unableToDelete(status: status)
        }

        self.credentials = .empty
    }

    /// Check if credentials are configured
    var hasCredentials: Bool {
        credentials.isValid
    }
}

// MARK: - Keychain Errors

enum KeychainError: LocalizedError {
    case unableToSave(status: OSStatus)
    case unableToDelete(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unableToSave(let status):
            return "Unable to save to Keychain (status: \(status))"
        case .unableToDelete(let status):
            return "Unable to delete from Keychain (status: \(status))"
        }
    }
}

#else

// iOS stub - credentials are macOS only
@MainActor
@Observable
class KeychainService {
    private(set) var credentials: S3Credentials = .empty
    private(set) var isLoaded: Bool = true

    var hasCredentials: Bool { false }

    func saveCredentials(_ credentials: S3Credentials) throws {
        // No-op on iOS
    }

    func loadCredentials() {
        // No-op on iOS
    }

    func deleteCredentials() throws {
        // No-op on iOS
    }
}

#endif
