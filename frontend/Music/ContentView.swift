//
//  ContentView.swift
//  Music
//
//  Created by Terrillo Walls on 1/17/26.
//

import SwiftUI
import SwiftData

enum Tab: String, CaseIterable {
    case home = "Home"
    case artists = "Artists"
    case songs = "Songs"
    case playlists = "Playlists"
    case radio = "Radio"
    #if os(macOS)
    case genres = "Genres"
    case search = "Search"
    case upload = "Upload"
    case settings = "Cloud"
    #endif

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .artists: return "person.3.sequence.fill"
        case .songs: return "music.note"
        case .playlists: return "music.note.square.stack"
        case .radio: return "antenna.radiowaves.left.and.right"
        #if os(macOS)
        case .genres: return "guitars"
        case .search: return "magnifyingglass"
        case .upload: return "arrow.up.circle"
        case .settings: return "icloud.fill"
        #endif
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .home
    @State private var showingSearch = false
    @State private var showingPlayer = false
    @State private var showingSettings = false
    @State private var musicService = MusicService()
    @State private var playerService = PlayerService()
    @State private var cacheService: CacheService?
    @State private var pendingNavigation: NavigationDestination? = nil
    @State private var favoritesStore = FavoritesStore.shared

    /// Empty state shown when no music has been uploaded yet
    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Music Yet", systemImage: "music.note")
        } description: {
            #if os(macOS)
            Text("Upload music or sync your catalog from Settings.")
            #else
            Text("Open Settings to sync your catalog from the cloud.")
            #endif
        } actions: {
            #if os(iOS)
            Button {
                showingSettings = true
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
            .buttonStyle(.borderedProminent)
            #else
            Button("Sync Catalog") {
                selectedTab = .settings
            }
            .buttonStyle(.borderedProminent)

            Button("Go to Upload") {
                selectedTab = .upload
            }
            #endif
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            if musicService.isLoading || (musicService.loadingStage == .failed && musicService.isEmpty) || (musicService.catalog == nil && musicService.loadingStage == .idle) {
                CatalogLoadingView(musicService: musicService)
            } else if musicService.isEmpty {
                emptyStateView
                    .transition(.opacity)
            } else {
                TabView(selection: $selectedTab) {
                    HomeView(
                        showingSearch: $showingSearch,
                        showingSettings: $showingSettings,
                        musicService: musicService,
                        playerService: playerService,
                        cacheService: cacheService
                    )
                    .tabItem {
                        Label("Home", systemImage: "house.fill")
                    }
                    .tag(Tab.home)

                    SongsView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                        .tabItem {
                            Label("Songs", systemImage: "music.note")
                        }
                        .tag(Tab.songs)

                    ArtistsView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService, pendingNavigation: .constant(nil))
                        .tabItem {
                            Label("Artists", systemImage: "person.3.sequence.fill")
                        }
                        .tag(Tab.artists)

                    PlaylistView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                        .tabItem {
                            Label("Playlists", systemImage: "music.note.square.stack")
                        }
                        .tag(Tab.playlists)

                    RadioView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                        .tabItem {
                            Label("Radio", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .tag(Tab.radio)
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
                .sheet(isPresented: $showingSettings) {
                    if let cacheService {
                        NavigationStack {
                            SettingsView(showingSearch: $showingSearch, cacheService: cacheService, musicService: musicService)
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("Done") { showingSettings = false }
                                    }
                                }
                        }
                    }
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
                        .help("Reload catalog from local storage")
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if playerService.hasTrack {
                        SidebarNowPlaying(playerService: playerService, cacheService: cacheService, showingPlayer: $showingPlayer)
                    }
                }
            } detail: {
                if musicService.isLoading || (musicService.loadingStage == .failed && musicService.isEmpty) || (musicService.catalog == nil && musicService.loadingStage == .idle) {
                    CatalogLoadingView(musicService: musicService)
                } else {
                    switch selectedTab {
                    case .home:
                        if musicService.isEmpty {
                            emptyStateView
                        } else {
                            HomeView(
                                showingSearch: $showingSearch,
                                showingSettings: $showingSettings,
                                musicService: musicService,
                                playerService: playerService,
                                cacheService: cacheService
                            )
                        }
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
                    case .radio:
                        if musicService.isEmpty {
                            emptyStateView
                        } else {
                            RadioView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                        }
                    case .search:
                        SearchView(musicService: musicService, playerService: playerService, cacheService: cacheService)
                    case .upload:
                        UploadView()
                    case .settings:
                        if let cacheService {
                            SettingsView(showingSearch: $showingSearch, cacheService: cacheService, musicService: musicService)
                        } else {
                            ProgressView("Loading...")
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if playerService.hasTrack {
                        Button {
                            showingPlayer.toggle()
                        } label: {
                            Image(systemName: showingPlayer ? "play.circle.fill" : "play.circle")
                        }
                        .help(showingPlayer ? "Hide Now Playing" : "Show Now Playing")
                    }
                }
            }
            .onChange(of: showingSearch) { _, newValue in
                if newValue {
                    selectedTab = .search
                    showingSearch = false
                }
            }
            .onChange(of: showingSettings) { _, newValue in
                if newValue {
                    selectedTab = .settings
                    showingSettings = false
                }
            }
            .inspector(isPresented: $showingPlayer) {
                NowPlayingSheet(
                    playerService: playerService,
                    musicService: musicService,
                    cacheService: cacheService,
                    onNavigate: { destination in
                        selectedTab = .artists
                        pendingNavigation = destination
                    },
                    onDismiss: {
                        showingPlayer = false
                    }
                )
                .inspectorColumnWidth(min: 340, ideal: 380, max: 440)
            }
            #endif
        }
        .animation(.easeInOut(duration: 0.3), value: musicService.isLoading)
        .animation(.easeInOut(duration: 0.3), value: musicService.loadingStage)
        .task {
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
            // Prefetch all artwork in background after catalog loads
            if !musicService.isEmpty {
                cacheService?.prefetchAllArtwork(urls: musicService.allArtworkUrls)
                // Auto-download favorited tracks for offline use
                await cacheService?.autoDownloadFavoriteTracks(musicService: musicService)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                playerService.savePlaybackState()
            }
        }
        .onChange(of: favoritesStore.favoriteTrackKeys) { _, _ in
            guard let cacheService, !musicService.isEmpty else { return }
            Task {
                await cacheService.autoDownloadFavoriteTracks(musicService: musicService)
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [CachedTrack.self, CachedArtwork.self], inMemory: true)
}
