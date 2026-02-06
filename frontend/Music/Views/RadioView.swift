//
//  RadioView.swift
//  Music
//
//  UI for radio mode: quick start options, seed selection, and current radio status.
//

import SwiftUI

struct RadioView: View {
    @Binding var showingSearch: Bool
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    @State private var cachedAvailableGenres: [String] = []
    @State private var cachedAvailableMoods: [String] = []

    private var availableGenres: [String] { cachedAvailableGenres }
    private var availableMoods: [String] { cachedAvailableMoods }

    private func updateAvailableGenresAndMoods() {
        cachedAvailableGenres = Array(Set(musicService.songs.compactMap { Genre.normalize($0.genre) })).sorted()
        cachedAvailableMoods = Array(Set(musicService.songs.compactMap { $0.mood })).sorted()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Current Radio Status
                    if playerService.isRadioMode {
                        currentRadioSection
                    }

                    // Quick Start Section
                    quickStartSection

                    // Start from Genre
                    genreSection

                    // Start from Mood
                    moodSection

                    // Start from Favorites
                    favoritesSection

                    // Start from Top Played
                    topPlayedSection
                }
                .padding()
            }
            .navigationTitle("Radio")
            .overlay {
                if musicService.isLoading {
                    ProgressView("Loading...")
                }
            }
            .onAppear {
                if cachedAvailableGenres.isEmpty { updateAvailableGenresAndMoods() }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            #endif
        }
    }

    // MARK: - Current Radio Section

    private var currentRadioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text("Radio Active")
                    .font(.headline)
                Spacer()
                Button("Stop") {
                    playerService.stopRadio()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            if let seed = playerService.radioService?.currentSeed {
                HStack {
                    Text(seed.displayType)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(seed.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                if let count = playerService.radioService?.generatedCount {
                    Text("\(count) tracks generated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.red.opacity(0.1))
        }
    }

    // MARK: - Quick Start Section

    private var quickStartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Start")
                .font(.headline)

            if let currentTrack = playerService.currentTrack {
                Button {
                    playerService.startRadio(from: .track(currentTrack), musicService: musicService)
                } label: {
                    HStack {
                        Image(systemName: "music.note")
                            .frame(width: 24)
                        VStack(alignment: .leading) {
                            Text("Radio from current track")
                                .font(.subheadline)
                            Text(currentTrack.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.gray.opacity(0.15))
                    }
                }
                .buttonStyle(.plain)
            }

            // Random radio
            Button {
                if let randomTrack = musicService.songs.filter({ playerService.isTrackPlayable($0) }).randomElement() {
                    playerService.startRadio(from: .track(randomTrack), musicService: musicService)
                }
            } label: {
                HStack {
                    Image(systemName: "shuffle")
                        .frame(width: 24)
                    Text("Surprise Me")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.gray.opacity(0.15))
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Genre Section

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By Genre")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(availableGenres, id: \.self) { genre in
                        Button {
                            playerService.startRadio(from: .genre(genre), musicService: musicService)
                        } label: {
                            Text(genre)
                                .font(.subheadline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background {
                                    Capsule()
                                        .fill(Color.gray.opacity(0.15))
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Mood Section

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By Mood")
                .font(.headline)

            if availableMoods.isEmpty {
                Text("No mood data available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(availableMoods, id: \.self) { mood in
                            Button {
                                playerService.startRadio(from: .mood(mood), musicService: musicService)
                            } label: {
                                Text(mood)
                                    .font(.subheadline)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background {
                                        Capsule()
                                            .fill(Color.gray.opacity(0.15))
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Favorites Section

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("From Favorites")
                .font(.headline)

            let favoriteArtists = musicService.artists.filter { FavoritesStore.shared.isArtistFavorite($0.id) }

            if favoriteArtists.isEmpty {
                Text("No favorite artists yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(favoriteArtists.prefix(10), id: \.id) { artist in
                            Button {
                                playerService.startRadio(from: .artist(artist), musicService: musicService)
                            } label: {
                                VStack {
                                    ArtworkImage(
                                        url: artist.imageUrl,
                                        size: 80,
                                        systemImage: "person.fill",
                                        cacheService: cacheService
                                    )
                                    .clipShape(Circle())

                                    Text(artist.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(width: 80)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Top Played Section

    private var topPlayedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Played Artists")
                .font(.headline)

            let topTracks = AnalyticsStore.shared.fetchTopTracks(limit: 50)
            let topArtistNames = topTracks.compactMap { musicService.trackByS3Key[$0.s3Key]?.artist }
            let uniqueArtists = Array(Set(topArtistNames)).prefix(5)
            let artistObjects = uniqueArtists.compactMap { name in
                musicService.artistByName[name]
            }

            if artistObjects.isEmpty {
                Text("Start playing music to see your top artists")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(artistObjects, id: \.id) { artist in
                            Button {
                                playerService.startRadio(from: .artist(artist), musicService: musicService)
                            } label: {
                                VStack {
                                    ArtworkImage(
                                        url: artist.imageUrl,
                                        size: 80,
                                        systemImage: "person.fill",
                                        cacheService: cacheService
                                    )
                                    .clipShape(Circle())

                                    Text(artist.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(width: 80)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    RadioView(
        showingSearch: .constant(false),
        musicService: MusicService(),
        playerService: PlayerService()
    )
}
