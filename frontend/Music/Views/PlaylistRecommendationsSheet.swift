//
//  PlaylistRecommendationsSheet.swift
//  Music
//
//  Sheet displaying AI-powered track recommendations for a playlist.
//

import SwiftUI

struct PlaylistRecommendationsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let playlist: PlaylistEntity
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    @State private var recommendations: [Track] = []
    @State private var isLoading = true
    @State private var selectedTracks: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Finding similar tracks...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if recommendations.isEmpty {
                    ContentUnavailableView(
                        "No Recommendations",
                        systemImage: "wand.and.stars",
                        description: Text("Add more tracks to your playlist to get personalized recommendations")
                    )
                } else {
                    List {
                        Section {
                            Text("Based on your playlist, you might also like these tracks.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .listRowBackground(Color.clear)

                        ForEach(recommendations) { track in
                            let isSelected = selectedTracks.contains(track.s3Key)

                            Button {
                                if isSelected {
                                    selectedTracks.remove(track.s3Key)
                                } else {
                                    selectedTracks.insert(track.s3Key)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkImage(
                                        url: track.embeddedArtworkUrl,
                                        size: 44,
                                        systemImage: "music.note",
                                        localURL: cacheService?.localArtworkURL(for: track.embeddedArtworkUrl ?? ""),
                                        cacheService: cacheService
                                    )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title)
                                            .font(.body)
                                            .foregroundStyle(.primary)

                                        if let artist = track.artist {
                                            Text(artist)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.blue)
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Suggestions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selectedTracks.count)") {
                        addSelectedTracks()
                    }
                    .disabled(selectedTracks.isEmpty)
                }
            }
            .task {
                await loadRecommendations()
            }
        }
    }

    private func loadRecommendations() async {
        isLoading = true
        recommendations = await PlaylistRecommendationService.shared.generateRecommendations(
            for: playlist,
            musicService: musicService
        )
        isLoading = false
    }

    private func addSelectedTracks() {
        let tracksToAdd = recommendations.filter { selectedTracks.contains($0.s3Key) }
        PlaylistStore.shared.addTracks(tracksToAdd, to: playlist)
        dismiss()
    }
}

//#Preview {
//    PlaylistRecommendationsSheet(
//        playlist: PlaylistEntity(),
//        musicService: MusicService(),
//        playerService: PlayerService()
//    )
//}
