//
//  PlaylistView.swift
//  Music

import SwiftUI

struct PlaylistView: View {
    @Binding var showingSearch: Bool
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    var body: some View {
        NavigationStack {
            List {
                Section("Auto Playlists") {
                    NavigationLink {
                        Top100View(
                            musicService: musicService,
                            playerService: playerService,
                            cacheService: cacheService
                        )
                    } label: {
                        Label("Top 100", systemImage: "chart.line.uptrend.xyaxis")
                    }
                }

                Section("Insights") {
                    NavigationLink {
                        StatisticsView(
                            musicService: musicService,
                            playerService: playerService,
                            cacheService: cacheService
                        )
                    } label: {
                        Label("Statistics", systemImage: "chart.bar.fill")
                    }
                }
            }
            .navigationTitle("Playlists")
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
}

struct Top100View: View {
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    @State private var selectedPeriod: TimePeriod = .allTime

    private var topTracks: [(track: Track, playCount: Int)] {
        // Fetch top tracks from Core Data + CloudKit with time filtering
        let topTrackData = AnalyticsStore.shared.fetchTopTracks(limit: 100, period: selectedPeriod)

        // Match to actual Track objects
        var results: [(track: Track, playCount: Int)] = []
        for (s3Key, count) in topTrackData {
            if let track = musicService.songs.first(where: { $0.s3Key == s3Key }) {
                results.append((track: track, playCount: count))
            }
        }
        return results
    }

    var body: some View {
        Group {
            if topTracks.isEmpty {
                ContentUnavailableView(
                    "No Play History",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Songs you play will appear here ranked by play count")
                )
            } else {
                List {
                    // Time Period Picker
                    Section {
                        Picker("Time Period", selection: $selectedPeriod) {
                            ForEach(TimePeriod.allCases) { period in
                                Text(period.rawValue).tag(period)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .listRowBackground(Color.clear)

                    // Track List
                    ForEach(Array(topTracks.enumerated()), id: \.element.track.id) { index, item in
                        let isPlayable = playerService.isTrackPlayable(item.track)
                        Button {
                            if isPlayable {
                                let tracks = topTracks.map { $0.track }
                                playerService.play(track: item.track, queue: tracks)
                            }
                        } label: {
                            Top100Row(
                                rank: index + 1,
                                track: item.track,
                                playCount: item.playCount,
                                playerService: playerService,
                                cacheService: cacheService,
                                isPlayable: isPlayable
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!isPlayable)
                    }
                }
                .refreshable {
                    await musicService.loadCatalog()
                }
            }
        }
        .navigationTitle("Top 100")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task {
                        await musicService.loadCatalog()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh catalog")
            }
        }
    }
}

struct Top100Row: View {
    let rank: Int
    let track: Track
    let playCount: Int
    var playerService: PlayerService
    var cacheService: CacheService?
    var isPlayable: Bool = true

    private var isCurrentTrack: Bool {
        playerService.currentTrack?.id == track.id
    }

    var body: some View {
        HStack {
            // Rank number
            Text("\(rank)")
                .font(.headline)
                .foregroundStyle(isCurrentTrack ? Color.appAccent : .secondary)
                .frame(width: 30)

            // Album artwork with now playing indicator
            ZStack {
                ArtworkImage(
                    url: track.embeddedArtworkUrl,
                    size: 44,
                    systemImage: "music.note",
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

            VStack(alignment: .leading) {
                Text(track.title)
                    .font(.headline)
                    .foregroundStyle(isCurrentTrack ? Color.appAccent : (isPlayable ? .primary : .secondary))
                HStack {
                    if let artist = track.artist {
                        Text(artist)
                    }
                    Text("•")
                    Text("\(playCount) plays")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

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
    PlaylistView(
        showingSearch: .constant(false),
        musicService: MusicService(),
        playerService: PlayerService()
    )
}
