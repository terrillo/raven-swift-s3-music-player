//
//  SongsView.swift
//  Music
//

import SwiftUI

struct SongsView: View {
    @Binding var showingSearch: Bool
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    @State private var navigationPath = NavigationPath()

    private var firstPlayableTrack: Track? {
        musicService.songs.first { playerService.isTrackPlayable($0) }
    }

    private var hasPlayableTracks: Bool {
        firstPlayableTrack != nil
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .navigationTitle("Songs")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
                .navigationDestination(for: NavigationDestination.self) { destination in
                    switch destination {
                    case .artist(let artist):
                        ArtistDetailView(artist: artist, musicService: musicService, playerService: playerService, cacheService: cacheService)
                    case .album(let album, _):
                        AlbumDetailView(album: album, musicService: musicService, playerService: playerService, cacheService: cacheService)
                    }
                }
        }
    }

    private func navigate(to destination: NavigationDestination) {
        navigationPath.append(destination)
    }

    @ViewBuilder
    private var content: some View {
        if musicService.isLoading {
            ProgressView("Loading...")
        } else if musicService.songs.isEmpty {
            ContentUnavailableView(
                "No Songs",
                systemImage: "music.note.list",
                description: Text("Your songs will appear here")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Shuffle button
                    Button {
                        playerService.shufflePlay(queue: musicService.songs)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasPlayableTracks)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    Divider()

                    // Songs list - LazyVStack only creates visible rows
                    ForEach(musicService.songs) { track in
                        let isPlayable = playerService.isTrackPlayable(track)
                        Button {
                            if isPlayable {
                                playerService.play(track: track, queue: musicService.songs)
                            }
                        } label: {
                            SongRow.songs(
                                track: track,
                                playerService: playerService,
                                cacheService: cacheService,
                                musicService: musicService,
                                isPlayable: isPlayable,
                                onNavigate: navigate
                            )
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .disabled(!isPlayable)

                        Divider()
                            .padding(.leading, 60)
                    }
                }
            }
        }
    }
}

#Preview {
    SongsView(showingSearch: .constant(false), musicService: MusicService(), playerService: PlayerService())
}
