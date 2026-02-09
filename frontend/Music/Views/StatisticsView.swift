//
//  StatisticsView.swift
//  Music
//

import SwiftUI
import Charts

struct StatisticsView: View {
    var musicService: MusicService
    var playerService: PlayerService

    @State private var selectedPeriod: TimePeriod = .month
    @State private var stats: ListeningStats?
    @State private var isLoading = true

    var body: some View {
        List {
            // Period Picker
            Section {
                Picker("Time Period", selection: $selectedPeriod) {
                    ForEach(TimePeriod.allCases) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }

            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading statistics...")
                        Spacer()
                    }
                }
            } else if let stats = stats, stats.totalPlays > 0 {
                // Summary Cards
                Section("Overview") {
                    HStack(spacing: 16) {
                        StatCard(title: "Plays", value: "\(stats.totalPlays)", icon: "play.fill")
                        StatCard(title: "Time", value: stats.formattedListeningTime, icon: "clock.fill")
                        StatCard(title: "Tracks", value: "\(stats.uniqueTracks)", icon: "music.note")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 8)
                }

                // Genre Breakdown Chart
                if !stats.topGenres.isEmpty {
                    Section("Top Genres") {
                        GenreChart(genres: stats.topGenres)
                            .frame(height: CGFloat(stats.topGenres.count * 36 + 20))
                    }
                }

                // Listening Activity Chart (only for week/month)
                if selectedPeriod != .allTime && !stats.playsByDay.isEmpty {
                    Section("Listening Activity") {
                        ActivityChart(data: stats.playsByDay, period: selectedPeriod)
                            .frame(height: 150)
                    }
                }

                // Top Artists
                if !stats.topArtists.isEmpty {
                    Section("Top Artists") {
                        ForEach(stats.topArtists.prefix(5)) { artist in
                            HStack {
                                Text(artist.artistName)
                                    .font(.headline)
                                Spacer()
                                Text("\(artist.playCount) plays")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                // Empty state
                Section {
                    ContentUnavailableView(
                        "No Listening Data",
                        systemImage: "chart.bar",
                        description: Text("Play some music to see your statistics")
                    )
                }
            }
        }
        .navigationTitle("Statistics")
        .task {
            await loadStats()
        }
        .onChange(of: selectedPeriod) { _, _ in
            Task { await loadStats() }
        }
    }

    private func loadStats() async {
        isLoading = true

        let songs = musicService.songs
        let period = selectedPeriod

        let computed = await StatisticsService.computeStats(for: period, songs: songs)
        stats = computed
        isLoading = false
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.appAccent)
            Text(value)
                .font(.title2.bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        #if os(iOS)
        .background(Color(.systemGray6))
        #else
        .background(Color.secondary.opacity(0.1))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Genre Chart

struct GenreChart: View {
    let genres: [GenreStats]

    var body: some View {
        Chart(genres) { genre in
            BarMark(
                x: .value("Plays", genre.playCount),
                y: .value("Genre", genre.genre)
            )
            .foregroundStyle(Color.appAccent.gradient)
            .annotation(position: .trailing) {
                Text("\(genre.playCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel()
            }
        }
    }
}

// MARK: - Activity Chart

struct ActivityChart: View {
    let data: [(date: Date, count: Int)]
    let period: TimePeriod

    var body: some View {
        Chart(data, id: \.date) { item in
            BarMark(
                x: .value("Date", item.date, unit: .day),
                y: .value("Plays", item.count)
            )
            .foregroundStyle(Color.appAccent.gradient)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: period == .week ? 1 : 7)) { _ in
                AxisValueLabel(format: period == .week ? .dateTime.weekday(.abbreviated) : .dateTime.day())
            }
        }
    }
}

#Preview {
    NavigationStack {
        StatisticsView(
            musicService: MusicService(),
            playerService: PlayerService()
        )
    }
}
