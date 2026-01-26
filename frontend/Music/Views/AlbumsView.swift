//
//  AlbumsView.swift
//  Music
//

import SwiftUI

struct AlbumsView: View {
    @Binding var showingSearch: Bool
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    @AppStorage("albumsViewMode") private var viewMode: ViewMode = .list

    private let gridColumns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if musicService.isLoading {
                    ProgressView("Loading...")
                } else if musicService.albums.isEmpty {
                    ContentUnavailableView(
                        "No Albums",
                        systemImage: "square.stack",
                        description: Text("Your albums will appear here")
                    )
                } else {
                    switch viewMode {
                    case .list:
                        albumListView
                    case .grid:
                        albumGridView
                    }
                }
            }
            .navigationTitle("Albums")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Picker("View", selection: $viewMode) {
                            ForEach(ViewMode.allCases, id: \.self) { mode in
                                Image(systemName: mode.icon)
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 80)
                    }
                }
                .sharedBackgroundVisibility(.hidden)
                
                ToolbarSpacer(.fixed, placement: .primaryAction)
                
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
        }
    }

    private var albumListView: some View {
        List(musicService.albums) { album in
            NavigationLink {
                AlbumDetailView(album: album, musicService: musicService, playerService: playerService, cacheService: cacheService)
            } label: {
                HStack(spacing: 12) {
                    ArtworkImage(
                        url: album.imageUrl,
                        size: 64,
                        systemImage: "square.stack",
                        localURL: cacheService?.localArtworkURL(for: album.imageUrl ?? ""),
                        cacheService: cacheService
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.name)
                            .font(.headline)

                        if let artist = album.tracks.first?.artist {
                            Text(artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 4) {
                            Text("\(album.tracks.count) songs")
                            if let releaseDate = album.releaseDate {
                                Text("·")
                                Text(String(releaseDate))
                            }
                            let totalDuration = album.tracks.compactMap { $0.duration }.reduce(0, +)
                            if totalDuration > 0 {
                                Text("·")
                                Text(formatDuration(totalDuration))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var albumGridView: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(musicService.albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album, musicService: musicService, playerService: playerService, cacheService: cacheService)
                    } label: {
                        AlbumGridCard(
                            album: album,
                            artistName: album.tracks.first?.artist,
                            localArtworkURL: cacheService?.localArtworkURL(for: album.imageUrl ?? ""),
                            cacheService: cacheService
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes) min"
    }
}

#Preview {
    AlbumsView(showingSearch: .constant(false), musicService: MusicService(), playerService: PlayerService())
}
