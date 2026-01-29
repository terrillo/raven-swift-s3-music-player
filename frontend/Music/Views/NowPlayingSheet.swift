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

enum QueueSegment: String, CaseIterable {
    case previous = "Previous"
    case next = "Next"
}

struct NowPlayingSheet: View {
    @Environment(\.dismiss) private var dismiss
    var playerService: PlayerService
    var musicService: MusicService
    var cacheService: CacheService?

    @State private var artworkColor: Color = Color(white: 0.3)
    @State private var selectedSegment: QueueSegment = .next
    @State private var showQueue: Bool = false

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
            ScrollView {
                VStack(spacing: 32) {
                    // Album Artwork (hidden when queue is shown)
                    if !showQueue {
                        ArtworkImage(
                            url: playerService.currentArtworkUrl,
                            size: 280,
                            systemImage: "music.note",
                            localURL: playerService.currentLocalArtworkURL,
                            cacheService: cacheService
                        )
                        .shadow(radius: 20)
                    }

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

                    // Shuffle, Queue & Repeat Controls
                    HStack(spacing: 40) {
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

                        // Queue
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showQueue.toggle()
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.title2)
                                .foregroundStyle(showQueue ? artworkColor.contrastingForeground : artworkColor.contrastingSecondary)
                        }
                        .accessibilityLabel(showQueue ? "Hide queue" : "Show queue")
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

                // Queue Section (shown when queue button is toggled)
                if showQueue {
                    VStack(spacing: 12) {
                        Picker("Queue", selection: $selectedSegment) {
                            ForEach(QueueSegment.allCases, id: \.self) { segment in
                                Text(segment.rawValue).tag(segment)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)

                        if selectedSegment == .previous {
                            QueueListView(
                                tracks: playerService.previousTracks,
                                accentColor: artworkColor,
                                emptyTitle: "No History",
                                emptyMessage: "Songs you've played will appear here"
                            ) { track in
                                playerService.play(track: track, queue: playerService.queue)
                            }
                        } else {
                            if playerService.isShuffled {
                                VStack(spacing: 8) {
                                    Image(systemName: "shuffle")
                                        .font(.title2)
                                        .foregroundStyle(artworkColor.labelSecondary)
                                    Text("Shuffle Active")
                                        .font(.headline)
                                        .foregroundStyle(artworkColor.labelPrimary)
                                    Text("Next track selected based on your listening habits")
                                        .font(.caption)
                                        .foregroundStyle(artworkColor.labelSecondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                            } else {
                                QueueListView(
                                    tracks: playerService.upNextTracks,
                                    accentColor: artworkColor,
                                    emptyTitle: "Queue Empty",
                                    emptyMessage: "No upcoming tracks in queue"
                                ) { track in
                                    playerService.play(track: track, queue: playerService.queue)
                                }
                            }
                        }
                    }
                    .padding(.top, 16)
                }
            }
            .padding(.vertical, 32)
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

// MARK: - Preview

private struct NowPlayingSheetPreview: View {
    @State private var playerService = PlayerService()
    private let musicService = MusicService()

    var body: some View {
        NowPlayingSheet(playerService: playerService, musicService: musicService)
            .task {
                // Create sample tracks for preview
                let sampleTracks = [
                    Track.preview(title: "Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera", trackNumber: 1, duration: 354),
                    Track.preview(title: "Don't Stop Me Now", artist: "Queen", album: "Jazz", trackNumber: 2, duration: 209),
                    Track.preview(title: "Somebody to Love", artist: "Queen", album: "A Day at the Races", trackNumber: 3, duration: 296),
                    Track.preview(title: "We Will Rock You", artist: "Queen", album: "News of the World", trackNumber: 4, duration: 122),
                    Track.preview(title: "We Are the Champions", artist: "Queen", album: "News of the World", trackNumber: 5, duration: 179),
                    Track.preview(title: "Under Pressure", artist: "Queen", album: "Hot Space", trackNumber: 6, duration: 248),
                    Track.preview(title: "Radio Ga Ga", artist: "Queen", album: "The Works", trackNumber: 7, duration: 343),
                    Track.preview(title: "I Want to Break Free", artist: "Queen", album: "The Works", trackNumber: 8, duration: 259),
                ]

                // Previous tracks (simulating play history - first 3 tracks were played)
                let historyTracks = Array(sampleTracks[0..<3])

                // Set up the player with sample data
                // Current track is index 3 "We Will Rock You"
                // Previous: tracks 0-2 (Bohemian Rhapsody, Don't Stop Me Now, Somebody to Love)
                // Next: tracks 4-7 (We Are the Champions, Under Pressure, Radio Ga Ga, I Want to Break Free)
                playerService.setupPreviewData(
                    queue: sampleTracks,
                    currentIndex: 3,
                    playHistory: historyTracks
                )
            }
    }
}

#Preview("Now Playing") {
    NowPlayingSheetPreview()
}
