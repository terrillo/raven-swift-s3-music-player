//
//  AddTracksSheet.swift
//  Music
//
//  Sheet for searching and adding tracks to a playlist.
//

import SwiftUI

struct AddTracksSheet: View {
    @Environment(\.dismiss) private var dismiss

    let playlist: PlaylistEntity
    var musicService: MusicService
    var cacheService: CacheService?

    @State private var searchText = ""
    @State private var selectedTracks: Set<String> = []

    private var filteredSongs: [Track] {
        if searchText.isEmpty {
            return Array(musicService.songs.prefix(100))
        }

        let query = searchText.lowercased()
        return musicService.songs.filter { track in
            track.title.lowercased().contains(query) ||
            (track.artist?.lowercased().contains(query) ?? false) ||
            (track.album?.lowercased().contains(query) ?? false)
        }.prefix(100).map { $0 }
    }

    private var existingTrackKeys: Set<String> {
        Set(PlaylistStore.shared.fetchTracks(for: playlist).compactMap { $0.trackS3Key })
    }

    var body: some View {
        NavigationStack {
            List(filteredSongs) { track in
                let isInPlaylist = existingTrackKeys.contains(track.s3Key)
                let isSelected = selectedTracks.contains(track.s3Key)

                Button {
                    if isSelected {
                        selectedTracks.remove(track.s3Key)
                    } else {
                        selectedTracks.insert(track.s3Key)
                    }
                } label: {
                    HStack(spacing: 12) {
                        // Track info
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.body)
                                .foregroundStyle(isInPlaylist ? .secondary : .primary)

                            if let artist = track.artist {
                                Text(artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        // Status indicator
                        if isInPlaylist {
                            Text("Added")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isInPlaylist)
            }
            .searchable(text: $searchText, prompt: "Search songs")
            .navigationTitle("Add Songs")
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
        }
    }

    private func addSelectedTracks() {
        let tracksToAdd = musicService.songs.filter { selectedTracks.contains($0.s3Key) }
        PlaylistStore.shared.addTracks(tracksToAdd, to: playlist)
        dismiss()
    }
}

//#Preview {
//    AddTracksSheet(
//        playlist: PlaylistEntity(),
//        musicService: MusicService()
//    )
//}
