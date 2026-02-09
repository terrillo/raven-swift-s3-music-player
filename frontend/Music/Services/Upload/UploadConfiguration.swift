//
//  UploadConfiguration.swift
//  Music
//
//  Configuration and credentials for upload services.
//  Credentials are stored securely in the macOS Keychain.
//

import Foundation

#if os(macOS)
import Security

struct UploadConfiguration: Codable, Equatable {
    var spacesKey: String
    var spacesSecret: String
    var spacesBucket: String
    var spacesRegion: String
    var spacesPrefix: String
    var lastFMApiKey: String
    var musicBrainzContact: String

    static let defaultRegion = "sfo3"
    static let defaultPrefix = "music"

    init(
        spacesKey: String = "",
        spacesSecret: String = "",
        spacesBucket: String = "",
        spacesRegion: String = defaultRegion,
        spacesPrefix: String = defaultPrefix,
        lastFMApiKey: String = "",
        musicBrainzContact: String = ""
    ) {
        self.spacesKey = spacesKey
        self.spacesSecret = spacesSecret
        self.spacesBucket = spacesBucket
        self.spacesRegion = spacesRegion
        self.spacesPrefix = spacesPrefix
        self.lastFMApiKey = lastFMApiKey
        self.musicBrainzContact = musicBrainzContact
    }

    var isValid: Bool {
        !spacesKey.isEmpty &&
        !spacesSecret.isEmpty &&
        !spacesBucket.isEmpty &&
        !spacesRegion.isEmpty
    }

    /// Virtual-hosted style endpoint (bucket in hostname)
    var spacesEndpoint: String {
        "https://\(spacesBucket).\(spacesRegion).digitaloceanspaces.com"
    }

    var cdnBaseURL: String {
        "https://\(spacesBucket).\(spacesRegion).cdn.digitaloceanspaces.com/\(spacesPrefix)"
    }

    /// CDN base URL without the prefix path (for iCloud storage and catalog fetch)
    var cdnBaseURLWithoutPrefix: String {
        "https://\(spacesBucket).\(spacesRegion).cdn.digitaloceanspaces.com"
    }

    // MARK: - Keychain Storage

    private static let keychainService = "com.music.upload"
    private static let keychainAccount = "configuration"

    /// Save configuration to Keychain
    func saveToKeychain() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Load configuration from Keychain
    static func loadFromKeychain() throws -> UploadConfiguration? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.invalidData
            }
            let decoder = JSONDecoder()
            return try decoder.decode(UploadConfiguration.self, from: data)

        case errSecItemNotFound:
            return nil

        default:
            throw KeychainError.loadFailed(status)
        }
    }

    /// Delete configuration from Keychain
    static func deleteFromKeychain() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

// MARK: - Keychain Errors

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save to Keychain (status: \(status))"
        case .loadFailed(let status):
            return "Failed to load from Keychain (status: \(status))"
        case .deleteFailed(let status):
            return "Failed to delete from Keychain (status: \(status))"
        case .invalidData:
            return "Invalid data in Keychain"
        }
    }
}

#endif
