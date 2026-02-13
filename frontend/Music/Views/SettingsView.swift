//
//  SettingsView.swift
//  Music
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Binding var showingSearch: Bool
    var cacheService: CacheService
    var musicService: MusicService

    @AppStorage("streamingModeEnabled") private var streamingModeEnabled = false
    @AppStorage("autoDownloadFavoritesEnabled") private var autoDownloadFavoritesEnabled = true
    @AppStorage("autoImageCachingEnabled") private var autoImageCachingEnabled = true
    @AppStorage("maxCacheSizeGB") private var maxCacheSizeGB: Int = 0
    @State private var cdnPrefix: String = NSUbiquitousKeyValueStore.default.string(forKey: "cdnPrefix") ?? MusicService.defaultCDNPrefix
    @State private var iCloudObserver: NSObjectProtocol?
    @State private var showingCacheSheet = false
    @State private var showingClearConfirmation = false
    @State private var showingDeleteAllConfirmation = false
    @State private var showingClearImageCacheConfirmation = false

    var body: some View {
        #if os(macOS)
        macOSContent
        #else
        iOSContent
        #endif
    }

    #if os(macOS)
    private var macOSContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Playback Section
                SettingsSection(title: "Playback", icon: "play.circle") {
                    Toggle(isOn: $streamingModeEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Streaming Mode")
                            Text("Play uncached tracks when online")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                // Storage Section
                SettingsSection(title: "Storage", icon: "internaldrive") {
                    HStack(spacing: 32) {
                        StorageStatView(icon: "music.note", value: "\(cacheService.cachedTrackCount())", label: "Cached")
                        StorageStatView(icon: "chart.pie", value: cacheService.formattedCacheSize(), label: "Size")
                        StorageStatView(icon: "music.note.list", value: "\(musicService.songs.count)", label: "Total")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                    Divider()
                        .padding(.vertical, 4)

                    HStack {
                        Text("Max Cache Size")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("0", value: $maxCacheSizeGB, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("GB")
                            .foregroundStyle(.secondary)
                    }

                    Text("Set to 0 for unlimited. Most played tracks are kept when limit is reached.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)

                    Divider()
                        .padding(.vertical, 4)

                    Toggle(isOn: $autoDownloadFavoritesEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Download Favorites")
                            Text("Automatically cache favorited songs for offline when streaming")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()
                        .padding(.vertical, 4)

                    HStack(spacing: 12) {
                        Button {
                            showingCacheSheet = true
                        } label: {
                            Label("Cache All Music", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            showingClearConfirmation = true
                        } label: {
                            Label("Clear Music Cache", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // Image Cache Section
                SettingsSection(title: "Image Cache", icon: "photo.stack") {
                    Toggle(isOn: $autoImageCachingEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Cache Images")
                            Text("Save artwork for offline viewing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()
                        .padding(.vertical, 4)

                    HStack(spacing: 32) {
                        StorageStatView(icon: "photo.on.rectangle", value: "\(cacheService.cachedArtworkCount())", label: "Images")
                        StorageStatView(icon: "externaldrive", value: cacheService.formattedArtworkCacheSize(), label: "Size")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                    Button(role: .destructive) {
                        showingClearImageCacheConfirmation = true
                    } label: {
                        Label("Clear Image Cache", systemImage: "photo.badge.minus")
                    }
                    .buttonStyle(.bordered)
                }

                // Sync Section
                SettingsSection(title: "Sync", icon: "arrow.triangle.2.circlepath") {
                    HStack {
                        Button {
                            Task {
                                await musicService.loadCatalog(forceRefresh: true)
                            }
                        } label: {
                            HStack {
                                Label("Sync Catalog", systemImage: "arrow.triangle.2.circlepath")
                                if musicService.isLoading {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(musicService.isLoading)

                        Spacer()
                    }

                    HStack {
                        Text("CDN Prefix")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("music", text: $cdnPrefix)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                            .onChange(of: cdnPrefix) { _, newValue in
                                NSUbiquitousKeyValueStore.default.set(newValue, forKey: "cdnPrefix")
                                NSUbiquitousKeyValueStore.default.synchronize()
                            }
                    }
                    .padding(.top, 8)

                    Text("Auto-synced from macOS uploader. Only change if you need to override.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }

                // Danger Zone Section
                SettingsSection(title: "Danger Zone", icon: "exclamationmark.triangle", iconColor: .red) {
                    Button(role: .destructive) {
                        showingDeleteAllConfirmation = true
                    } label: {
                        Label("Delete All Data", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.bordered)

                    Text("Deletes all cached music, artwork, and listening history from this device and iCloud.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            .padding(24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
        .sheet(isPresented: $showingCacheSheet) {
            CacheDownloadView(
                cacheService: cacheService,
                tracks: musicService.songs,
                artworkUrls: musicService.allArtworkUrls,
                catalog: musicService.catalog
            )
        }
        .confirmationDialog("Clear Cache", isPresented: $showingClearConfirmation) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await cacheService.clearCache()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all cached music and artwork. You'll need to download them again for offline playback.")
        }
        .confirmationDialog("Delete All Data", isPresented: $showingDeleteAllConfirmation) {
            Button("Delete All Data", role: .destructive) {
                Task {
                    await cacheService.clearAllData()
                    AnalyticsStore.shared.clearAllData()
                    musicService.invalidateCaches()
                    musicService.catalog = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all cached music, artwork, catalog data, and listening history from this device AND iCloud. This affects all devices using this iCloud account. This action cannot be undone.")
        }
        .confirmationDialog("Clear Image Cache", isPresented: $showingClearImageCacheConfirmation) {
            Button("Clear Image Cache", role: .destructive) {
                Task {
                    await cacheService.clearArtworkCache()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all cached images. They will be re-downloaded as you browse.")
        }
        .onChange(of: autoImageCachingEnabled) { _, enabled in
            if !enabled {
                showingClearImageCacheConfirmation = true
            } else {
                cacheService.updateArtworkBackupExclusion()
            }
        }
        .onChange(of: maxCacheSizeGB) { _, newValue in
            let clamped = max(0, newValue)
            if clamped != newValue {
                maxCacheSizeGB = clamped
            }
            cacheService.updateTrackBackupExclusion()
        }
        .onAppear {
            iCloudObserver = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: NSUbiquitousKeyValueStore.default,
                queue: .main
            ) { _ in
                if let newPrefix = NSUbiquitousKeyValueStore.default.string(forKey: "cdnPrefix") {
                    cdnPrefix = newPrefix
                }
            }
        }
        .onDisappear {
            if let observer = iCloudObserver {
                NotificationCenter.default.removeObserver(observer)
                iCloudObserver = nil
            }
        }
    }
    #endif

    private var iOSContent: some View {
        NavigationStack {
            List {
                Section("Playback") {
                    Toggle(isOn: $streamingModeEnabled) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Streaming Mode")
                                Text("Play uncached tracks when online")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                    }
                }

                Section {
                    Button {
                        showingCacheSheet = true
                    } label: {
                        HStack {
                            Label("Cache All Music", systemImage: "arrow.down.circle")
                            Spacer()
                            Text("\(musicService.songs.count) songs")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    HStack {
                        Label("Cached", systemImage: "internaldrive")
                        Spacer()
                        Text("\(cacheService.cachedTrackCount()) songs")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Cache Size", systemImage: "chart.pie")
                        Spacer()
                        Text(cacheService.formattedCacheSize())
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Max Cache", systemImage: "gauge.with.dots.needle.bottom.50percent")
                        Spacer()
                        TextField("0", value: $maxCacheSizeGB, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                        Text("GB")
                            .foregroundStyle(.secondary)
                    }

                    Toggle(isOn: $autoDownloadFavoritesEnabled) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Auto-Download Favorites")
                                Text("Automatically cache favorited songs for offline when streaming")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "heart.circle")
                        }
                    }

                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Set Max Cache to 0 for unlimited. Most played tracks are kept when limit is reached.")
                }

                Section("Images") {
                    Toggle(isOn: $autoImageCachingEnabled) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Auto-Cache Images")
                                Text("Save artwork for offline viewing")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "photo.stack")
                        }
                    }

                    HStack {
                        Label("Cached Images", systemImage: "photo.on.rectangle")
                        Spacer()
                        Text("\(cacheService.cachedArtworkCount()) images")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Image Cache Size", systemImage: "externaldrive")
                        Spacer()
                        Text(cacheService.formattedArtworkCacheSize())
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        showingClearImageCacheConfirmation = true
                    } label: {
                        Label("Clear Image Cache", systemImage: "photo.badge.minus")
                    }
                }

                Section {
                    Button {
                        Task {
                            await musicService.loadCatalog(forceRefresh: true)
                        }
                    } label: {
                        HStack {
                            Label("Sync Catalog", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if musicService.isLoading {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(musicService.isLoading)

                    HStack {
                        Label("CDN Prefix", systemImage: "cloud")
                        Spacer()
                        TextField("music", text: $cdnPrefix)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: cdnPrefix) { _, newValue in
                                NSUbiquitousKeyValueStore.default.set(newValue, forKey: "cdnPrefix")
                                NSUbiquitousKeyValueStore.default.synchronize()
                            }
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Auto-synced from macOS. Only change if you need to override.")
                }

                Section {
                    Button(role: .destructive) {
                        showingDeleteAllConfirmation = true
                    } label: {
                        Label("Delete All Data", systemImage: "exclamationmark.triangle")
                    }
                } header: {
                    Text("Danger Zone")
                } footer: {
                    Text("Deletes all cached music, artwork, and listening history from this device and iCloud.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            .sheet(isPresented: $showingCacheSheet) {
                CacheDownloadView(
                    cacheService: cacheService,
                    tracks: musicService.songs,
                    artworkUrls: musicService.allArtworkUrls,
                    catalog: musicService.catalog
                )
            }
            .confirmationDialog("Clear Cache", isPresented: $showingClearConfirmation) {
                Button("Clear Cache", role: .destructive) {
                    Task {
                        await cacheService.clearCache()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all cached music and artwork. You'll need to download them again for offline playback.")
            }
            .confirmationDialog("Delete All Data", isPresented: $showingDeleteAllConfirmation) {
                Button("Delete All Data", role: .destructive) {
                    #if os(iOS)
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    #endif
                    Task {
                        await cacheService.clearAllData()
                        AnalyticsStore.shared.clearAllData()
                        musicService.invalidateCaches()
                        musicService.catalog = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all cached music, artwork, catalog data, and listening history from this device AND iCloud. This affects all devices using this iCloud account. This action cannot be undone.")
            }
            .confirmationDialog("Clear Image Cache", isPresented: $showingClearImageCacheConfirmation) {
                Button("Clear Image Cache", role: .destructive) {
                    Task {
                        await cacheService.clearArtworkCache()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all cached images. They will be re-downloaded as you browse.")
            }
            .onChange(of: autoImageCachingEnabled) { _, enabled in
                if !enabled {
                    showingClearImageCacheConfirmation = true
                } else {
                    cacheService.updateArtworkBackupExclusion()
                }
            }
            .onChange(of: maxCacheSizeGB) { _, newValue in
                let clamped = max(0, newValue)
                if clamped != newValue {
                    maxCacheSizeGB = clamped
                }
                cacheService.updateTrackBackupExclusion()
            }
            .onAppear {
                iCloudObserver = NotificationCenter.default.addObserver(
                    forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                    object: NSUbiquitousKeyValueStore.default,
                    queue: .main
                ) { _ in
                    if let newPrefix = NSUbiquitousKeyValueStore.default.string(forKey: "cdnPrefix") {
                        cdnPrefix = newPrefix
                    }
                }
            }
            .onDisappear {
                if let observer = iCloudObserver {
                    NotificationCenter.default.removeObserver(observer)
                    iCloudObserver = nil
                }
            }
        }
    }

}

// MARK: - macOS Helper Components

#if os(macOS)
private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    var iconColor: Color = .appAccent
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct StorageStatView: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
#endif

#Preview {
    do {
        let container = try ModelContainer(for: CachedTrack.self, CachedArtwork.self)
        return SettingsView(
            showingSearch: .constant(false),
            cacheService: CacheService(modelContext: container.mainContext),
            musicService: MusicService()
        )
    } catch {
        return Text("Preview unavailable: \(error.localizedDescription)")
    }
}
