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
    case settings = "Cloud"

    var icon: String {
        switch self {
        case .artists: return "person.3.sequence.fill"
        case .genres: return "guitars"
        case .songs: return "music.note"
        case .playlists: return "music.note.square.stack"
        case .settings: return "icloud.fill"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab: Tab = .artists
    @State private var showingSearch = false
    @State private var showingPlayer = false
    @State private var musicService = MusicService()
    @State private var playerService = PlayerService()
    @State private var cacheService: CacheService?

    var body: some View {
        VStack(spacing: 0) {
            // Offline banner
            if musicService.isOffline {
                HStack {
                    Image(systemName: "wifi.slash")
                    Text("Offline Mode")
                    if let lastUpdated = musicService.lastUpdated {
                        Text("• Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.orange.opacity(0.2))
            }

            Group {
                #if os(iOS)
                TabView(selection: $selectedTab) {
                ArtistsView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
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
                SearchView()
            }
            .sheet(isPresented: $showingPlayer) {
                NowPlayingSheet(playerService: playerService, musicService: musicService, cacheService: cacheService)
            }
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
                switch selectedTab {
                case .artists:
                    ArtistsView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                case .genres:
                    GenreView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                case .songs:
                    SongsView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                case .playlists:
                    PlaylistView(showingSearch: $showingSearch, musicService: musicService, playerService: playerService, cacheService: cacheService)
                case .settings:
                    SettingsView(showingSearch: $showingSearch, cacheService: cacheService ?? CacheService(modelContext: modelContext), musicService: musicService)
                }
            }
            .sheet(isPresented: $showingSearch) {
                SearchView()
            }
            .sheet(isPresented: $showingPlayer) {
                NowPlayingSheet(playerService: playerService, musicService: musicService, cacheService: cacheService)
            }
            #endif
            }
        }
        .task {
            if cacheService == nil {
                cacheService = CacheService(modelContext: modelContext)
                playerService.cacheService = cacheService
            }
            musicService.configure(modelContext: modelContext)
            await musicService.loadCatalog()
            // Sync initial online status
            playerService.isOnline = !musicService.isOffline
        }
        .onChange(of: musicService.isOffline) { _, isOffline in
            playerService.isOnline = !isOffline
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
        .modelContainer(for: [Item.self, CachedTrack.self, CachedArtwork.self, CachedCatalog.self], inMemory: true)
}
