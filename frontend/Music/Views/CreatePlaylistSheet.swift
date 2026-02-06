//
//  CreatePlaylistSheet.swift
//  Music
//
//  Sheet for creating a new playlist.
//

import SwiftUI

struct CreatePlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var description: String = ""

    var initialTrack: Track?
    var onCreated: ((PlaylistEntity) -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Playlist Name", text: $name)

                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let track = initialTrack {
                    Section("Adding") {
                        HStack {
                            Image(systemName: "music.note")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(track.title)
                                    .font(.subheadline)
                                if let artist = track.artist {
                                    Text(artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Playlist")
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
                    Button("Create") {
                        createPlaylist()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    private func createPlaylist() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)

        let playlist = PlaylistStore.shared.createPlaylist(
            name: trimmedName,
            description: trimmedDescription.isEmpty ? nil : trimmedDescription
        )

        if let track = initialTrack {
            PlaylistStore.shared.addTrack(track, to: playlist)
        }

        onCreated?(playlist)
        dismiss()
    }
}

#Preview {
    CreatePlaylistSheet()
}
