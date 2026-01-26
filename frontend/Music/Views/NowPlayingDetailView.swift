//
//  NowPlayingDetailView.swift
//  Music
//
//  Inline Now Playing view for macOS (no sheet, lives in detail area)
//

import SwiftUI

struct NowPlayingDetailView: View {
    var playerService: PlayerService
    var musicService: MusicService
    var cacheService: CacheService?
    @Binding var showingPlayer: Bool
    var onNavigateToArtist: (Artist) -> Void
    var onNavigateToAlbum: (Album, Artist?) -> Void

    // Look up Artist object by album_artist name
    private var currentArtist: Artist? {
        guard let albumArtist = playerService.currentTrack?.albumArtist else { return nil }
        return musicService.artists.first { $0.name == albumArtist }
    }

    // Look up Album object by album name within the current artist
    private var currentAlbumObject: Album? {
        guard let albumName = playerService.currentTrack?.album else { return nil }
        // First try to find within current artist's albums
        if let artist = currentArtist {
            if let album = artist.albums.first(where: { $0.name == albumName }) {
                return album
            }
        }
        // Fall back to searching all albums
        return musicService.albums.first { $0.name == albumName }
    }

    var body: some View {
        VStack(spacing: 32) {
            // Back button
            HStack {
                Button {
                    showingPlayer = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal)

            Spacer()

            // Album Artwork
            ArtworkImage(
                url: playerService.currentArtworkUrl,
                size: 280,
                systemImage: "music.note",
                localURL: playerService.currentLocalArtworkURL,
                cacheService: cacheService
            )
            .shadow(radius: 20)

            // Track Info
            VStack(spacing: 8) {
                Text(playerService.currentTrack?.title ?? "Not Playing")
                    .font(.title2)
                    .fontWeight(.bold)
                    .lineLimit(1)

                // Artist button -> triggers navigation callback
                if let artist = currentArtist {
                    Button {
                        onNavigateToArtist(artist)
                    } label: {
                        Text(artist.name)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    #endif
                } else if let artistName = playerService.currentTrack?.albumArtist ?? playerService.currentTrack?.artist {
                    Text(artistName)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Album button -> triggers navigation callback
                if let album = currentAlbumObject {
                    Button {
                        onNavigateToAlbum(album, currentArtist)
                    } label: {
                        Text(album.name)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    #endif
                } else if let albumName = playerService.currentTrack?.album {
                    Text(albumName)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            // Progress Bar
            VStack(spacing: 8) {
                Slider(value: Binding(
                    get: { playerService.progress },
                    set: { playerService.seek(to: $0) }
                ))
                .tint(.primary)

                HStack {
                    Text(playerService.formattedCurrentTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Text(playerService.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 20)

            // Playback Controls
            HStack(spacing: 40) {
                // Shuffle
                Button {
                    playerService.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.title2)
                        .foregroundStyle(playerService.isShuffled ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playerService.isShuffled ? "Shuffle on" : "Shuffle off")

                // Previous
                Button {
                    playerService.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous track")

                // Play/Pause
                Button {
                    playerService.togglePlayPause()
                } label: {
                    Image(systemName: playerService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 70))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playerService.isPlaying ? "Pause" : "Play")

                // Next
                Button {
                    playerService.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next track")

                // Repeat
                Button {
                    playerService.cycleRepeatMode()
                } label: {
                    Image(systemName: repeatIcon)
                        .font(.title2)
                        .foregroundStyle(playerService.repeatMode != .off ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(repeatAccessibilityLabel)
            }

            Spacer()
        }
        .padding()
    }

    private var repeatIcon: String {
        switch playerService.repeatMode {
        case .off, .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatAccessibilityLabel: String {
        switch playerService.repeatMode {
        case .off:
            return "Repeat off"
        case .all:
            return "Repeat all"
        case .one:
            return "Repeat one"
        }
    }
}

#Preview {
    NowPlayingDetailView(
        playerService: PlayerService(),
        musicService: MusicService(),
        cacheService: nil,
        showingPlayer: .constant(true),
        onNavigateToArtist: { _ in },
        onNavigateToAlbum: { _, _ in }
    )
}
