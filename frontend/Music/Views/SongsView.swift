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

    private var firstPlayableTrack: Track? {
        musicService.songs.first { playerService.isTrackPlayable($0) }
    }

    private var hasPlayableTracks: Bool {
        firstPlayableTrack != nil
    }

    var body: some View {
        NavigationStack {
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
        }
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
                            SongRow(track: track, playerService: playerService, cacheService: cacheService, isPlayable: isPlayable)
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
            .refreshable {
                await musicService.loadCatalog()
            }
        }
    }
}

struct SongRow: View {
    let track: Track
    var playerService: PlayerService
    var cacheService: CacheService?
    var isPlayable: Bool = true
    var showFavoriteButton: Bool = true

    private var isCurrentTrack: Bool {
        playerService.currentTrack?.id == track.id
    }

    private var isFavorite: Bool {
        FavoritesStore.shared.isTrackFavorite(track.s3Key)
    }

    private var localArtworkURL: URL? {
        guard let urlString = track.embeddedArtworkUrl else { return nil }
        return cacheService?.localArtworkURL(for: urlString)
    }

    var body: some View {
        HStack {
            // Album artwork with now playing indicator overlay
            ZStack {
                ArtworkImage(
                    url: track.embeddedArtworkUrl,
                    size: 44,
                    systemImage: "music.note",
                    localURL: localArtworkURL,
                    cacheService: cacheService
                )

                if isCurrentTrack {
                    Color.black.opacity(0.4)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Image(systemName: playerService.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.headline)
                    .foregroundStyle(isCurrentTrack ? Color.appAccent : (isPlayable ? .primary : .secondary))
                    .lineLimit(1)
                if let artist = track.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let album = track.album {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            if showFavoriteButton {
                Button {
                    FavoritesStore.shared.toggleTrackFavorite(track)
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? .red : .secondary)
                }
                .buttonStyle(.plain)
            }

            if !isPlayable {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Text(track.formattedDuration)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(isPlayable ? 1.0 : 0.5)
    }
}

#Preview {
    SongsView(showingSearch: .constant(false), musicService: MusicService(), playerService: PlayerService())
}
