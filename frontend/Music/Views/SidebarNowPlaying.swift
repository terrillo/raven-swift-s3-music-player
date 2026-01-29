//
//  SidebarNowPlaying.swift
//  Music
//

import SwiftUI

struct SidebarNowPlaying: View {
    var playerService: PlayerService
    var cacheService: CacheService?
    @Binding var showingPlayer: Bool

    var body: some View {
        if let track = playerService.currentTrack {
            VStack(spacing: 8) {
                // Track info row (tappable to open player)
                Button {
                    showingPlayer = true
                } label: {
                    HStack(spacing: 10) {
                        // Album artwork
                        ArtworkImage(
                            url: playerService.currentArtworkUrl,
                            size: 40,
                            systemImage: "music.note",
                            localURL: playerService.currentLocalArtworkURL,
                            cacheService: cacheService
                        )

                        // Track info
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)

                            if let artist = track.artist {
                                Text(artist)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                // Playback controls row
                HStack(spacing: 16) {
                    Button {
                        playerService.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.body)
                    }
                    .buttonStyle(.plain)

                    Button {
                        playerService.togglePlayPause()
                    } label: {
                        Image(systemName: playerService.isPlaying ? "pause.fill" : "play.fill")
                            .font(.body)
                    }
                    .buttonStyle(.plain)

                    Button {
                        playerService.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.body)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        FavoritesStore.shared.toggleTrackFavorite(track)
                    } label: {
                        Image(systemName: FavoritesStore.shared.isTrackFavorite(track.s3Key) ? "heart.fill" : "heart")
                            .font(.body)
                            .foregroundStyle(FavoritesStore.shared.isTrackFavorite(track.s3Key) ? .pink : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}

#Preview {
    SidebarNowPlaying(
        playerService: PlayerService(),
        showingPlayer: .constant(false)
    )
    .frame(width: 200)
}
