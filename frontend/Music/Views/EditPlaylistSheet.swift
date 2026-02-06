//
//  EditPlaylistSheet.swift
//  Music
//
//  Sheet for editing playlist metadata.
//

import SwiftUI

struct EditPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss

    let playlist: PlaylistEntity

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var showingDeleteConfirmation = false

    var onDeleted: (() -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Playlist Name", text: $name)

                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete Playlist", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Edit Playlist")
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
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Delete Playlist?", isPresented: $showingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    deletePlaylist()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete \"\(playlist.name ?? "this playlist")\" and remove all its tracks.")
            }
            .onAppear {
                name = playlist.name ?? ""
                description = playlist.playlistDescription ?? ""
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    private func saveChanges() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)

        PlaylistStore.shared.updatePlaylist(
            playlist,
            name: trimmedName,
            description: trimmedDescription.isEmpty ? nil : trimmedDescription
        )

        dismiss()
    }

    private func deletePlaylist() {
        PlaylistStore.shared.deletePlaylist(playlist)
        onDeleted?()
        dismiss()
    }
}

//#Preview {
//    EditPlaylistSheet(playlist: PlaylistEntity())
//}
