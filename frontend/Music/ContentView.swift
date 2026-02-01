//
//  ContentView.swift
//  Music
//
//  Created by Terrillo Walls on 1/17/26.
//

import SwiftUI
import SwiftData

enum Tab: String, CaseIterable {
    case artists = "Artists"
    case genres = "Genres"
    case songs = "Songs"
    case playlists = "Playlists"
    #if os(macOS)
    case search = "Search"
    case upload = "Upload"
    #endif
    case settings = "Cloud"

    var icon: String {
        switch self {
        case .artists: return "person.3.sequence.fill"
        case .genres: return "guitars"
        case .songs: return "music.note"
        case .playlists: return "music.note.square.stack"
        #if os(macOS)
        case .search: return "magnifyingglass"
        case .upload: return "arrow.up.circle"
        #endif
        case .settings: return "icloud.fill"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .artists
    @State private var showingSearch = false
    @State private var showingPlayer = false
    @State private var musicService = MusicService()
    @State private var playerService = PlayerService()
    @State private var cacheService: CacheService?
    @State private var pendingNavigation: NavigationDestination? = nil

    /// Empty state shown when no music has been uploaded yet
    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Music Yet", systemImage: "music.note")
        } description: {
            #if os(macOS)
            Text("Go to the Upload tab to add your music library.")
            #else
            Text("Use the macOS app to upload your music library.")
            #endif
        } actions: {
            Button {
                Task {
                    await musicService.loadCatalog()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            #if os(macOS)
            Button("Go to Upload") {
                selectedTab = .upload
            }
            .buttonStyle(.borderedProminent)
            #endif
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            if musicService.isLoading {
                ProgressView("Loading catalog...")
            } else if musicService.isEmpty {
                emptyStateView
            } else {
                TabView(selection: $selectedTab) {
                ArtistsView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService, pendingNavigation: .constant(nil))
                    .tabItem {
                        Image(systemName: "person.3.sequence.fill")
                    }
                    .tag(Tab.artists)

                GenreView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                    .tabItem {
                        Image(systemName: "guitars")
                    }
                    .tag(Tab.genres)

                SongsView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                    .tabItem {
                        Image(systemName: "music.note")
                    }
                    .tag(Tab.songs)

                PlaylistView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                    .tabItem {
                        Image(systemName: "music.note.square.stack")
                    }
                    .tag(Tab.playlists)

                SettingsView(showingSearch: $showingSearch, cacheService: cacheService ?? CacheService(modelContext: modelContext), musicService: musicService)
                    .tabItem {
                        Image(systemName: "icloud.fill")
                    }
                    .tag(Tab.settings)
            }
            .tabViewBottomAccessory {
                if playerService.hasTrack {
                    NowPlayingAccessory(playerService: playerService, cacheService: cacheService, showingPlayer: $showingPlayer)
                }
            }
            .sheet(isPresented: $showingSearch) {
                SearchView(musicService: musicService, playerService: playerService, cacheService: cacheService)
            }
            .sheet(isPresented: $showingPlayer) {
                NowPlayingSheet(playerService: playerService, musicService: musicService, cacheService: cacheService)
            }
            }  // end else (has content)
            #else
            NavigationSplitView {
                List(Tab.allCases, id: \.self, selection: $selectedTab) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            Task {
                                await musicService.loadCatalog()
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh catalog")
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if playerService.hasTrack {
                        SidebarNowPlaying(playerService: playerService, cacheService: cacheService, showingPlayer: $showingPlayer)
                    }
                }
            } detail: {
                if musicService.isLoading {
                    ProgressView("Loading catalog...")
                } else {
                    switch selectedTab {
                    case .artists:
                        if musicService.isEmpty {
                            emptyStateView
                        } else {
                            ArtistsView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService, pendingNavigation: $pendingNavigation)
                        }
                    case .genres:
                        if musicService.isEmpty {
                            emptyStateView
                        } else {
                            GenreView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                        }
                    case .songs:
                        if musicService.isEmpty {
                            emptyStateView
                        } else {
                            SongsView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                        }
                    case .playlists:
                        if musicService.isEmpty {
                            emptyStateView
                        } else {
                            PlaylistView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                        }
                    case .search:
                        SearchView(musicService: musicService, playerService: playerService, cacheService: cacheService)
                    case .upload:
                        UploadView()
                    case .settings:
                        SettingsView(showingSearch: $showingSearch, cacheService: cacheService ?? CacheService(modelContext: modelContext), musicService: musicService)
                    }
                }
            }
            .onChange(of: showingSearch) { _, newValue in
                if newValue {
                    selectedTab = .search
                    showingSearch = false
                }
            }
            .sheet(isPresented: $showingPlayer) {
                NowPlayingSheet(playerService: playerService, musicService: musicService, cacheService: cacheService)
                    .frame(minWidth: 400, minHeight: 600)
            }
            #endif
        }
        .task {
            // Sync iCloud settings (CDN prefix from macOS)
            MusicService.syncCloudSettings()

            if cacheService == nil {
                cacheService = CacheService(modelContext: modelContext)
                playerService.cacheService = cacheService
            }
            musicService.configure(modelContext: modelContext)
            await musicService.loadCatalog()
            // Restore playback state after catalog loads
            if musicService.catalog != nil {
                playerService.restorePlaybackState(from: musicService)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await musicService.loadCatalog()
                }
            } else if newPhase == .background {
                playerService.savePlaybackState()
            }
        }
        .alert("Unable to Load Music", isPresented: .constant(musicService.error != nil)) {
            Button("Retry") {
                musicService.error = nil
                Task { await musicService.loadCatalog() }
            }
            Button("OK", role: .cancel) {
                musicService.error = nil
            }
        } message: {
            Text(musicService.error?.localizedDescription ?? "An unknown error occurred")
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Item.self, CachedTrack.self, CachedArtwork.self], inMemory: true)
}
