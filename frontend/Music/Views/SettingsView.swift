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
    @AppStorage("autoCacheArtwork") private var autoCacheArtwork = true
    @State private var showingCacheSheet = false
    @State private var showingClearConfirmation = false
    @State private var showingClearArtworkConfirmation = false
    @State private var showingDeleteAllConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                if musicService.isOffline {
                    Section {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Offline Mode")
                                if let lastUpdated = musicService.lastUpdated {
                                    Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "wifi.slash")
                                .foregroundStyle(.orange)
                        }
                    }
                }

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
                    .disabled(musicService.isOffline)
                }

                Section("Storage") {
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

                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                    }
                }

                Section("Images") {
                    Toggle(isOn: $autoCacheArtwork) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Auto-Cache Artwork")
                                Text("Save images when browsing")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "photo.on.rectangle")
                        }
                    }

                    HStack {
                        Label("Cached Images", systemImage: "photo.stack")
                        Spacer()
                        Text("\(cacheService.cachedArtworkCount())")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Artwork Size", systemImage: "square.stack.3d.up")
                        Spacer()
                        Text(cacheService.formattedArtworkCacheSize())
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        showingClearArtworkConfirmation = true
                    } label: {
                        Label("Clear Artwork Cache", systemImage: "trash")
                    }
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
                    artworkUrls: collectArtworkUrls(),
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
            .confirmationDialog("Clear Artwork Cache", isPresented: $showingClearArtworkConfirmation) {
                Button("Clear Artwork", role: .destructive) {
                    Task {
                        await cacheService.clearArtworkCache()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all cached artwork images. They will be re-downloaded as you browse.")
            }
            .confirmationDialog("Delete All Data", isPresented: $showingDeleteAllConfirmation) {
                Button("Delete All Data", role: .destructive) {
                    Task {
                        await cacheService.clearCache()
                        await musicService.clearAllData()
                        AnalyticsStore.shared.clearAllData()
                        FavoritesStore.shared.clearAllData()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all cached music, artwork, and listening history from this device AND iCloud. This affects all devices using this iCloud account. This action cannot be undone.")
            }
        }
    }

    private func collectArtworkUrls() -> [String] {
        var urls: Set<String> = []

        for artist in musicService.artists {
            if let url = artist.imageUrl {
                urls.insert(url)
            }
            for album in artist.albums {
                if let url = album.imageUrl {
                    urls.insert(url)
                }
            }
        }

        for track in musicService.songs {
            if let url = track.embeddedArtworkUrl {
                urls.insert(url)
            }
        }

        return Array(urls)
    }
}

#Preview {
    do {
        let container = try ModelContainer(for: CachedTrack.self, CachedArtwork.self, CachedCatalog.self)
        return SettingsView(
            showingSearch: .constant(false),
            cacheService: CacheService(modelContext: container.mainContext),
            musicService: MusicService()
        )
    } catch {
        return Text("Preview unavailable: \(error.localizedDescription)")
    }
}
