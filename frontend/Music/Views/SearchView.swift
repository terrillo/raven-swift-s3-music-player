//
//  SearchView.swift
//  Music
//

import SwiftUI

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    private var filteredArtists: [Artist] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        let favorites = FavoritesStore.shared.favoriteArtistIds
        var seenIds = Set<String>()
        return musicService.artists
            .filter { artist in
                artist.name.localizedCaseInsensitiveContains(query) ||
                (artist.genre?.localizedCaseInsensitiveContains(query) ?? false) ||
                (artist.area?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .sorted { a, b in
                let aIsFavorite = favorites.contains(a.id)
                let bIsFavorite = favorites.contains(b.id)
                if aIsFavorite != bIsFavorite {
                    return aIsFavorite
                }
                return a.name < b.name
            }
            .filter { seenIds.insert($0.id).inserted }
    }

    private var filteredAlbums: [Album] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        let favorites = FavoritesStore.shared.favoriteAlbumIds
        var seenIds = Set<String>()
        return musicService.albums
            .filter { album in
                album.name.localizedCaseInsensitiveContains(query) ||
                (album.tracks.first?.artist?.localizedCaseInsensitiveContains(query) ?? false) ||
                (album.genre?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .sorted { a, b in
                let aIsFavorite = favorites.contains(a.id)
                let bIsFavorite = favorites.contains(b.id)
                if aIsFavorite != bIsFavorite {
                    return aIsFavorite
                }
                return a.name < b.name
            }
            .filter { seenIds.insert($0.id).inserted }
    }

    private var filteredSongs: [Track] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        let favorites = FavoritesStore.shared.favoriteTrackKeys
        var seenIds = Set<String>()
        return musicService.songs
            .filter { track in
                track.title.localizedCaseInsensitiveContains(query) ||
                (track.artist?.localizedCaseInsensitiveContains(query) ?? false) ||
                (track.album?.localizedCaseInsensitiveContains(query) ?? false) ||
                (track.genre?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .sorted { a, b in
                let aIsFavorite = favorites.contains(a.s3Key)
                let bIsFavorite = favorites.contains(b.s3Key)
                if aIsFavorite != bIsFavorite {
                    return aIsFavorite
                }
                return a.title < b.title
            }
            .filter { seenIds.insert($0.id).inserted }
    }

    private var hasNoResults: Bool {
        !searchText.isEmpty && filteredArtists.isEmpty && filteredAlbums.isEmpty && filteredSongs.isEmpty
    }

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    #if os(iOS)
    private var iOSBody: some View {
        NavigationStack {
            searchList
                .searchable(text: $searchText, prompt: "Artists, Albums, Songs")
                .navigationBarTitleDisplayMode(.inline)
                .navigationTitle("Search")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
    #endif

    #if os(macOS)
    private var macOSBody: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Artists, Albums, Songs", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            searchList
        }
        .navigationTitle("Search")
    }
    #endif

    private var searchList: some View {
        List {
            if searchText.isEmpty {
                ContentUnavailableView(
                    "Search Music",
                    systemImage: "magnifyingglass",
                    description: Text("Search for artists, albums, or songs")
                )
            } else if hasNoResults {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No results for \"\(searchText)\"")
                )
            } else {
                // Artists section
                if !filteredArtists.isEmpty {
                    Section("Artists") {
                        ForEach(filteredArtists) { artist in
                            NavigationLink {
                                ArtistDetailView(artist: artist, musicService: musicService, playerService: playerService, cacheService: cacheService)
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkImage(
                                        url: artist.imageUrl,
                                        size: 44,
                                        systemImage: "music.mic",
                                        localURL: cacheService?.localArtworkURL(for: artist.imageUrl ?? ""),
                                        cacheService: cacheService
                                    )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(artist.name)
                                            .font(.headline)
                                        Text("\(artist.albums.count) \(artist.albums.count == 1 ? "album" : "albums")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                // Albums section
                if !filteredAlbums.isEmpty {
                    Section("Albums") {
                        ForEach(filteredAlbums) { album in
                            NavigationLink {
                                AlbumDetailView(album: album, musicService: musicService, playerService: playerService, cacheService: cacheService)
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkImage(
                                        url: album.imageUrl,
                                        size: 44,
                                        systemImage: "square.stack",
                                        localURL: cacheService?.localArtworkURL(for: album.imageUrl ?? ""),
                                        cacheService: cacheService
                                    )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.name)
                                            .font(.headline)
                                        if let artist = album.tracks.first?.artist {
                                            Text(artist)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Songs section
                if !filteredSongs.isEmpty {
                    Section("Songs") {
                        ForEach(filteredSongs) { track in
                            let isPlayable = playerService.isTrackPlayable(track)
                            Button {
                                if isPlayable {
                                    playerService.play(track: track, queue: filteredSongs)
                                }
                            } label: {
                                SongRow(track: track, playerService: playerService, cacheService: cacheService, isPlayable: isPlayable)
                            }
                            .buttonStyle(.plain)
                            .disabled(!isPlayable)
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    SearchView(musicService: MusicService(), playerService: PlayerService())
}
