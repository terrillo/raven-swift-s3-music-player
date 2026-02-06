//
//  ContentView.swift
//  Music
//
//  Created by Terrillo Walls on 1/17/26.
//

import SwiftUI
import SwiftData

enum Tab: String, CaseIterable {
    #if os(iOS)
    case home = "Home"
    #endif
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
        #if os(iOS)
        case .home: return "house.fill"
        #endif
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
    #if os(iOS)
    @State private var selectedTab: Tab = .home
    #else
    @State private var selectedTab: Tab = .artists
    #endif
    @State private var showingSearch = false
    @State private var showingPlayer = false
    @State private var showingSettings = false
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
            if musicService.isLoading || musicService.loadingStage == .failed {
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
                        Image(systemName: "house.fill")
                    }
                    .tag(Tab.home)

                    SongsView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                        .tabItem {
                            Image(systemName: "music.note")
                        }
                        .tag(Tab.songs)

                    ArtistsView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService, pendingNavigation: .constant(nil))
                        .tabItem {
                            Image(systemName: "person.3.sequence.fill")
                        }
                        .tag(Tab.artists)

                    PlaylistView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                        .tabItem {
                            Image(systemName: "music.note.square.stack")
                        }
                        .tag(Tab.playlists)

                    RadioView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                        .tabItem {
                            Image(systemName: "antenna.radiowaves.left.and.right")
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
                    NavigationStack {
                        SettingsView(showingSearch: $showingSearch, cacheService: cacheService ?? CacheService(modelContext: modelContext), musicService: musicService)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { showingSettings = false }
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
                if musicService.isLoading || musicService.loadingStage == .failed {
                    CatalogLoadingView(musicService: musicService)
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
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [CachedTrack.self, CachedArtwork.self], inMemory: true)
}
