//
//  HomeView.swift
//  Music
//
//  Home screen with curated content sections for iOS.
//

import SwiftUI

struct HomeView: View {
    @Binding var showingSearch: Bool
    @Binding var showingSettings: Bool
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    @State private var navigationPath = NavigationPath()
    @State private var cachedTopTracks: [(track: Track, playCount: Int)] = []
    @State private var cachedRecentlyPlayed: [(track: Track, playedAt: Date)] = []
    @State private var cachedTopGenres: [String] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    topTracksSection
                    recentlyPlayedSection
                    recentlyAddedSection
                    genreBrowseSection
                }
                .padding()
            }
            .task {
                if cachedTopTracks.isEmpty { updateTopTracks() }
                if cachedRecentlyPlayed.isEmpty { updateRecentlyPlayed() }
                if cachedTopGenres.isEmpty { updateTopGenres() }
            }
            .navigationTitle("Home")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 16) {
                        Button {
                            showingSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }

                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "icloud.fill")
                        }
                    }
                }
            }
            #endif
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

    // MARK: - Top Tracks Section

    private var topTracksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top Tracks")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                NavigationLink {
                    Top100View(
                        musicService: musicService,
                        playerService: playerService,
                        cacheService: cacheService
                    )
                } label: {
                    Text("See All")
                        .font(.subheadline)
                }
            }

            if topTracks.isEmpty {
                Text("Play some music to see your top tracks")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(topTracks.prefix(5).enumerated()), id: \.element.track.s3Key) { index, item in
                    let isPlayable = playerService.isTrackPlayable(item.track)
                    Button {
                        if isPlayable {
                            let tracks = topTracks.map { $0.track }
                            playerService.play(track: item.track, queue: tracks)
                        }
                    } label: {
                        SongRow(
                            track: item.track,
                            leadingStyle: .artwork,
                            subtitleStyle: .playCount(item.playCount),
                            playerService: playerService,
                            cacheService: cacheService,
                            musicService: musicService,
                            isPlayable: isPlayable,
                            onNavigate: navigate
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isPlayable)

                    if index < min(topTracks.count, 5) - 1 {
                        Divider()
                            .padding(.leading, 60)
                    }
                }
            }
        }
    }

    private var topTracks: [(track: Track, playCount: Int)] { cachedTopTracks }

    private func updateTopTracks() {
        let data = AnalyticsStore.shared.fetchTopTracks(limit: 5, period: .allTime)
        cachedTopTracks = data.compactMap { (s3Key, count) in
            guard let track = musicService.trackByS3Key[s3Key] else { return nil }
            return (track: track, playCount: count)
        }
    }

    // MARK: - Recently Played Section

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recently Played")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                NavigationLink {
                    RecentlyPlayedView(
                        musicService: musicService,
                        playerService: playerService,
                        cacheService: cacheService
                    )
                } label: {
                    Text("See All")
                        .font(.subheadline)
                }
            }

            if cachedRecentlyPlayed.isEmpty {
                Text("Play some music to see your history")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(cachedRecentlyPlayed.prefix(5).enumerated()), id: \.element.track.s3Key) { index, item in
                    let isPlayable = playerService.isTrackPlayable(item.track)
                    Button {
                        if isPlayable {
                            let tracks = cachedRecentlyPlayed.map { $0.track }
                            playerService.play(track: item.track, queue: tracks)
                        }
                    } label: {
                        SongRow.recentlyPlayed(
                            track: item.track,
                            playedAt: item.playedAt,
                            playerService: playerService,
                            cacheService: cacheService,
                            musicService: musicService,
                            isPlayable: isPlayable,
                            onNavigate: navigate
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isPlayable)

                    if index < min(cachedRecentlyPlayed.count, 5) - 1 {
                        Divider()
                            .padding(.leading, 60)
                    }
                }
            }
        }
    }

    private func updateRecentlyPlayed() {
        let data = AnalyticsStore.shared.fetchRecentlyPlayedTracks(limit: 5)
        cachedRecentlyPlayed = data.compactMap { (s3Key, playedAt) in
            guard let track = musicService.trackByS3Key[s3Key] else { return nil }
            return (track: track, playedAt: playedAt)
        }
    }

    // MARK: - Recently Added Section

    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recently Added")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                NavigationLink {
                    RecentlyAddedView(
                        musicService: musicService,
                        playerService: playerService,
                        cacheService: cacheService
                    )
                } label: {
                    Text("See All")
                        .font(.subheadline)
                }
            }

            let recentTracks = Array(musicService.recentlyAddedSongs.prefix(5))

            if recentTracks.isEmpty {
                Text("Upload music to see recently added tracks")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(recentTracks.enumerated()), id: \.element.s3Key) { index, track in
                    let isPlayable = playerService.isTrackPlayable(track)
                    Button {
                        if isPlayable {
                            playerService.play(track: track, queue: musicService.recentlyAddedSongs)
                        }
                    } label: {
                        SongRow.recentlyAdded(
                            track: track,
                            playerService: playerService,
                            cacheService: cacheService,
                            musicService: musicService,
                            isPlayable: isPlayable,
                            onNavigate: navigate
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isPlayable)

                    if index < recentTracks.count - 1 {
                        Divider()
                            .padding(.leading, 60)
                    }
                }
            }
        }
    }

    // MARK: - Genre Browse Section

    private var genreBrowseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse by Genre")
                .font(.title2)
                .fontWeight(.bold)

            if topGenres.isEmpty {
                Text("No genres available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(topGenres, id: \.self) { genre in
                            NavigationLink {
                                GenreDetailView(
                                    genre: genre,
                                    musicService: musicService,
                                    playerService: playerService,
                                    cacheService: cacheService
                                )
                            } label: {
                                Text(genre)
                                    .font(.subheadline)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background {
                                        #if os(iOS)
                                        if #available(iOS 26.0, *) {
                                            Capsule().glassEffect(.regular.interactive())
                                        } else {
                                            Capsule().fill(.ultraThinMaterial)
                                        }
                                        #else
                                        Capsule().fill(.ultraThinMaterial)
                                        #endif
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var topGenres: [String] { cachedTopGenres }

    private func updateTopGenres() {
        var genreCounts: [String: Int] = [:]
        for track in musicService.songs {
            if let normalized = Genre.normalize(track.genre) {
                genreCounts[normalized, default: 0] += 1
            }
        }
        cachedTopGenres = genreCounts
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { $0.key }
    }
}

#Preview {
    HomeView(
        showingSearch: .constant(false),
        showingSettings: .constant(false),
        musicService: MusicService(),
        playerService: PlayerService()
    )
}
