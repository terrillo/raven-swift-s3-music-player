//
//  ManualPlaylistsListView.swift
//  Music
//
//  List view showing all user-created playlists.
//

import SwiftUI

struct ManualPlaylistsListView: View {
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    @State private var showingCreatePlaylist = false

    private var playlists: [PlaylistEntity] {
        PlaylistStore.shared.playlists
    }

    var body: some View {
        Group {
            if playlists.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text("Create a playlist to organize your favorite songs")
                )
            } else {
                List {
                    ForEach(playlists, id: \.id) { playlist in
                        NavigationLink {
                            PlaylistDetailView(
                                playlist: playlist,
                                musicService: musicService,
                                playerService: playerService,
                                cacheService: cacheService
                            )
                        } label: {
                            PlaylistRowView(playlist: playlist, cacheService: cacheService)
                        }
                    }
                    .onDelete(perform: deletePlaylists)
                }
            }
        }
        .navigationTitle("My Playlists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreatePlaylist = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingCreatePlaylist) {
            CreatePlaylistSheet()
        }
    }

    private func deletePlaylists(at offsets: IndexSet) {
        for index in offsets {
            let playlist = playlists[index]
            PlaylistStore.shared.deletePlaylist(playlist)
        }
    }
}

//#Preview {
//    NavigationStack {
//        ManualPlaylistsListView(
//            musicService: MusicService(),
//            playerService: PlayerService()
//        )
//    }
//}
