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

                    // Play/Pause button
                    Button {
                        playerService.togglePlayPause()
                    } label: {
                        Image(systemName: playerService.isPlaying ? "pause.fill" : "play.fill")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
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
