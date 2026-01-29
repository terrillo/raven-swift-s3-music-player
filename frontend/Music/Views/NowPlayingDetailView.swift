//
//  NowPlayingDetailView.swift
//  Music
//
//  Inline Now Playing view for macOS (no sheet, lives in detail area)
//

import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct NowPlayingDetailView: View {
    var playerService: PlayerService
    var musicService: MusicService
    var cacheService: CacheService?
    @Binding var showingPlayer: Bool
    var onNavigateToArtist: (Artist) -> Void
    var onNavigateToAlbum: (Album, Artist?) -> Void

    @State private var artworkColor: Color = Color(white: 0.3)

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

    private func extractArtworkColor() {
        // Try local artwork first
        if let localURL = playerService.currentLocalArtworkURL {
            extractColor(from: localURL)
            return
        }

        // Try to load from cache service
        if let urlString = playerService.currentArtworkUrl,
           let cacheService = cacheService,
           let localURL = cacheService.localArtworkURL(for: urlString) {
            extractColor(from: localURL)
            return
        }

        // Fall back to downloading if we have a URL
        if let urlString = playerService.currentArtworkUrl,
           let url = URL(string: urlString) {
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    await MainActor.run {
                        #if os(iOS)
                        if let image = UIImage(data: data), let color = image.averageColor {
                            withAnimation(.easeInOut(duration: 0.5)) {
                                artworkColor = color
                            }
                        }
                        #else
                        if let image = NSImage(data: data), let color = image.averageColor {
                            withAnimation(.easeInOut(duration: 0.5)) {
                                artworkColor = color
                            }
                        }
                        #endif
                    }
                } catch {
                    // Silently fail - keep default color
                }
            }
        }
    }

    private func extractColor(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        #if os(iOS)
        if let image = UIImage(data: data), let color = image.averageColor {
            withAnimation(.easeInOut(duration: 0.5)) {
                artworkColor = color
            }
        }
        #else
        if let image = NSImage(data: data), let color = image.averageColor {
            withAnimation(.easeInOut(duration: 0.5)) {
                artworkColor = color
            }
        }
        #endif
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
                    .foregroundStyle(artworkColor.labelPrimary)
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
                    .foregroundStyle(artworkColor.labelPrimary)
                    .lineLimit(1)

                // Artist button -> triggers navigation callback
                if let artist = currentArtist {
                    Button {
                        onNavigateToArtist(artist)
                    } label: {
                        Text(artist.name)
                            .font(.title3)
                            .foregroundStyle(artworkColor.labelSecondary)
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
                        .foregroundStyle(artworkColor.labelSecondary)
                        .lineLimit(1)
                }

                // Album button -> triggers navigation callback
                if let album = currentAlbumObject {
                    Button {
                        onNavigateToAlbum(album, currentArtist)
                    } label: {
                        Text(album.name)
                            .font(.subheadline)
                            .foregroundStyle(artworkColor.labelTertiary)
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
                        .foregroundStyle(artworkColor.labelTertiary)
                        .lineLimit(1)
                }
            }

            // Controls Container with Album Art Color Background
            VStack(spacing: 20) {
                // Progress Bar
                VStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { playerService.progress },
                        set: { playerService.seek(to: $0) }
                    ))
                    .tint(artworkColor.contrastingForeground)

                    HStack {
                        Text(playerService.formattedCurrentTime)
                            .font(.caption)
                            .foregroundStyle(artworkColor.contrastingSecondary)
                            .monospacedDigit()
                        Spacer()
                        Text(playerService.formattedDuration)
                            .font(.caption)
                            .foregroundStyle(artworkColor.contrastingSecondary)
                            .monospacedDigit()
                    }
                }

                // Playback Controls
                HStack(spacing: 40) {
                    // Shuffle
                    Button {
                        playerService.toggleShuffle()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.title2)
                            .foregroundStyle(playerService.isShuffled ? artworkColor.contrastingForeground : artworkColor.contrastingSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playerService.isShuffled ? "Shuffle on" : "Shuffle off")

                    // Previous
                    Button {
                        playerService.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.title)
                            .foregroundStyle(artworkColor.contrastingForeground)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous track")

                    // Play/Pause
                    Button {
                        playerService.togglePlayPause()
                    } label: {
                        Image(systemName: playerService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 70))
                            .foregroundStyle(artworkColor.contrastingForeground)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playerService.isPlaying ? "Pause" : "Play")

                    // Next
                    Button {
                        playerService.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title)
                            .foregroundStyle(artworkColor.contrastingForeground)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next track")

                    // Repeat
                    Button {
                        playerService.cycleRepeatMode()
                    } label: {
                        Image(systemName: repeatIcon)
                            .font(.title2)
                            .foregroundStyle(playerService.repeatMode != .off ? artworkColor.contrastingForeground : artworkColor.contrastingSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(repeatAccessibilityLabel)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(artworkColor)
                    .shadow(color: artworkColor.opacity(0.3), radius: 10, y: 5)
            )
            .padding(.horizontal)
            .glassEffect(in: .rect(cornerRadius: 24))

            Spacer()
        }
        .padding()
        .onAppear {
            extractArtworkColor()
        }
        .onChange(of: playerService.currentTrack?.s3Key) { _, _ in
            extractArtworkColor()
        }
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
