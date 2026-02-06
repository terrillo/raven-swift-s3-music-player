//
//  NowPlayingAccessory.swift
//  Music
//

import SwiftUI

struct NowPlayingAccessory: View {
    var playerService: PlayerService
    var cacheService: CacheService?
    @Binding var showingPlayer: Bool

    var body: some View {
        if let track = playerService.currentTrack {
            HStack(spacing: 12) {
                // Album artwork
                ArtworkImage(
                    url: playerService.currentArtworkUrl,
                    size: 44,
                    systemImage: "music.note",
                    localURL: playerService.currentLocalArtworkURL,
                    cacheService: cacheService
                )

                // Track info
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if let artist = track.artist {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Play/Pause button
                Button {
                    playerService.togglePlayPause()
                } label: {
                    Image(systemName: playerService.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playerService.isPlaying ? "Pause" : "Play")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                showingPlayer = true
            }
            .accessibilityLabel("Now Playing: \(track.title) by \(track.artist ?? "")")
        }
    }
}

#Preview {
    NowPlayingAccessory(
        playerService: PlayerService(),
        showingPlayer: .constant(false)
    )
}
