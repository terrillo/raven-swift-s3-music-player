//
//  GenreView.swift
//  Music
//

import SwiftUI

struct GenreView: View {
    @Binding var showingSearch: Bool
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    // Get unique genres with song counts, sorted alphabetically
    private var genresWithCounts: [(genre: String, count: Int)] {
        var genreCounts: [String: Int] = [:]
        for track in musicService.songs {
            if let normalized = Genre.normalize(track.genre) {
                genreCounts[normalized, default: 0] += 1
            }
        }
        return genreCounts
            .map { (genre: $0.key, count: $0.value) }
            .sorted { $0.genre.localizedCaseInsensitiveCompare($1.genre) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Genres")
                .toolbar {
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

    @ViewBuilder
    private var content: some View {
        if musicService.isLoading {
            ProgressView("Loading...")
        } else if genresWithCounts.isEmpty {
            ContentUnavailableView(
                "No Genres",
                systemImage: "guitars",
                description: Text("Your genres will appear here")
            )
        } else {
            List {
                ForEach(genresWithCounts, id: \.genre) { item in
                    NavigationLink {
                        GenreDetailView(
                            genre: item.genre,
                            musicService: musicService,
                            playerService: playerService,
                            cacheService: cacheService
                        )
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.genre)
                                    .font(.headline)
                                Text("\(item.count) songs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                    }
                }
            }
            .refreshable {
                await musicService.loadCatalog(forceRefresh: true)
            }
        }
    }
}

// MARK: - Genre Detail View

struct GenreDetailView: View {
    let genre: String
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    private var songsInGenre: [Track] {
        musicService.songs.filter { Genre.normalize($0.genre) == genre }
    }

    private var firstPlayableTrack: Track? {
        songsInGenre.first { playerService.isTrackPlayable($0) }
    }

    private var hasPlayableTracks: Bool {
        firstPlayableTrack != nil
    }

    var body: some View {
        List {
            // Shuffle button
            Button {
                playerService.shufflePlay(queue: songsInGenre)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!hasPlayableTracks)
            .listRowBackground(Color.clear)

            // Songs list
            ForEach(songsInGenre) { track in
                let isPlayable = playerService.isTrackPlayable(track)
                Button {
                    if isPlayable {
                        playerService.play(track: track, queue: songsInGenre)
                    }
                } label: {
                    SongRow(track: track, playerService: playerService, cacheService: cacheService, isPlayable: isPlayable)
                }
                .buttonStyle(.plain)
                .disabled(!isPlayable)
            }
        }
        .navigationTitle(genre)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
    }
}

#Preview {
    GenreView(showingSearch: .constant(false), musicService: MusicService(), playerService: PlayerService())
}
