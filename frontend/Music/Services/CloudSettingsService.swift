//
//  CloudSettingsService.swift
//  Music
//
//  Centralized service for iCloud Key-Value storage settings.
//  Manages CDN configuration that syncs between macOS uploader and iOS app.
//

import Foundation

@MainActor
@Observable
class CloudSettingsService {
    static let shared = CloudSettingsService()

    private let store = NSUbiquitousKeyValueStore.default

    static let defaultCDNBase = "https://terrillo.sfo3.cdn.digitaloceanspaces.com"
    static let defaultCDNPrefix = "music"

    var cdnBaseURL: String {
        get { store.string(forKey: "cdnBaseURL") ?? Self.defaultCDNBase }
        set { store.set(newValue, forKey: "cdnBaseURL"); store.synchronize() }
    }

    var cdnPrefix: String {
        get { store.string(forKey: "cdnPrefix") ?? Self.defaultCDNPrefix }
        set { store.set(newValue, forKey: "cdnPrefix"); store.synchronize() }
    }

    /// Constructs the catalog URL with cache-busting timestamp
    var catalogURL: URL? {
        let timestamp = Int(Date().timeIntervalSince1970)
        return URL(string: "\(cdnBaseURL)/\(cdnPrefix)/catalog.json?\(timestamp)")
    }

    /// Force sync with iCloud
    func synchronize() {
        store.synchronize()
    }

    private init() {
        // Register for external change notifications (when another device updates)
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { _ in
            // Synchronize on main actor when external changes occur
            Task { @MainActor in
                CloudSettingsService.shared.synchronize()
            }
        }
    }
}
