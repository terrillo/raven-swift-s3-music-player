//
//  NowPlayingSheet.swift
//  Music
//

import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct NowPlayingSheet: View {
    @Environment(\.dismiss) private var dismiss
    var playerService: PlayerService
    var musicService: MusicService
    var cacheService: CacheService?

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
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Album Artwork
                ArtworkImage(
                    url: playerService.currentArtworkUrl,
                    size: 320,
                    systemImage: "music.note",
                    localURL: playerService.currentLocalArtworkURL,
                    cacheService: cacheService
                )
                .shadow(radius: 20)

                // Track Info
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Text(playerService.currentTrack?.title ?? "Not Playing")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(artworkColor.labelPrimary)
                            .lineLimit(1)

                        if let track = playerService.currentTrack {
                            Button {
                                FavoritesStore.shared.toggleTrackFavorite(track)
                            } label: {
                                Image(systemName: FavoritesStore.shared.isTrackFavorite(track.s3Key) ? "heart.fill" : "heart")
                                    .font(.title2)
                                    .foregroundStyle(FavoritesStore.shared.isTrackFavorite(track.s3Key) ? .red : artworkColor.labelSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Artist button -> navigates to ArtistDetailView
                    if let artist = currentArtist {
                        NavigationLink {
                            ArtistDetailView(artist: artist, musicService: musicService, playerService: playerService, cacheService: cacheService)
                        } label: {
                            Text(artist.name)
                                .font(.title3)
                                .foregroundStyle(artworkColor.labelSecondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else if let artistName = playerService.currentTrack?.albumArtist ?? playerService.currentTrack?.artist {
                        Text(artistName)
                            .font(.title3)
                            .foregroundStyle(artworkColor.labelSecondary)
                            .lineLimit(1)
                    }

                    // Album button -> navigates to AlbumDetailView
                    if let album = currentAlbumObject {
                        NavigationLink {
                            AlbumDetailView(album: album, musicService: musicService, playerService: playerService, cacheService: cacheService)
                        } label: {
                            Text(album.name)
                                .font(.subheadline)
                                .foregroundStyle(artworkColor.labelTertiary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
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
                        // Previous
                        Button {
                            playerService.previous()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.title)
                                .foregroundStyle(artworkColor.contrastingForeground)
                        }
                        .accessibilityLabel("Previous track")
                        .buttonStyle(.plain)

                        // Play/Pause
                        Button {
                            playerService.togglePlayPause()
                        } label: {
                            Image(systemName: playerService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 70))
                                .foregroundStyle(artworkColor.contrastingForeground)
                        }
                        .accessibilityLabel(playerService.isPlaying ? "Pause" : "Play")
                        .buttonStyle(.plain)

                        // Next
                        Button {
                            playerService.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.title)
                                .foregroundStyle(artworkColor.contrastingForeground)
                        }
                        .accessibilityLabel("Next track")
                        .buttonStyle(.plain)
                    }

                    // Shuffle & Repeat Controls
                    HStack(spacing: 60) {
                        // Shuffle
                        Button {
                            playerService.toggleShuffle()
                        } label: {
                            Image(systemName: "shuffle")
                                .font(.title2)
                                .foregroundStyle(playerService.isShuffled ? artworkColor.contrastingForeground : artworkColor.contrastingSecondary)
                        }
                        .accessibilityLabel(playerService.isShuffled ? "Shuffle on" : "Shuffle off")
                        .buttonStyle(.plain)

                        // Repeat
                        Button {
                            playerService.cycleRepeatMode()
                        } label: {
                            Image(systemName: repeatIcon)
                                .font(.title2)
                                .foregroundStyle(playerService.repeatMode != .off ? artworkColor.contrastingForeground : artworkColor.contrastingSecondary)
                        }
                        .accessibilityLabel(repeatAccessibilityLabel)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                #if os(iOS)
                .frame(maxWidth: UIScreen.main.bounds.width - 40)
                #endif
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(artworkColor)
                        .shadow(color: artworkColor.opacity(0.3), radius: 10, y: 5)
                        .glassEffect(in: .rect(cornerRadius: 24))
                )
                #if os(macOS)
                .padding(.horizontal, 24)
                #endif

                Spacer()
            }
            .onAppear {
                extractArtworkColor()
            }
            .onChange(of: playerService.currentTrack?.s3Key) { _, _ in
                extractArtworkColor()
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.title3)
                            .foregroundStyle(artworkColor.labelPrimary)
                    }
                }
            }
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
    NowPlayingSheet(playerService: PlayerService(), musicService: MusicService())
}
