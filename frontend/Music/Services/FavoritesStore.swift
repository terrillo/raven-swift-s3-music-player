//
//  FavoritesStore.swift
//  Music
//

import CoreData
import Combine

@MainActor
@Observable
class FavoritesStore {
    static let shared = FavoritesStore()

    private(set) var favoriteArtistIds: Set<String> = []
    private(set) var favoriteAlbumIds: Set<String> = []
    private(set) var favoriteTrackKeys: Set<String> = []

    private var viewContext: NSManagedObjectContext { AnalyticsStore.shared.viewContext }
    private var cancellables = Set<AnyCancellable>()

    private init() {
        loadFavorites()
        observeChanges()
    }

    // MARK: - Artist Favorites

    func isArtistFavorite(_ artistId: String) -> Bool {
        favoriteArtistIds.contains(artistId)
    }

    func toggleArtistFavorite(_ artist: Artist) {
        if isArtistFavorite(artist.id) {
            removeArtistFavorite(artist.id)
        } else {
            addArtistFavorite(artist)
        }
    }

    private func addArtistFavorite(_ artist: Artist) {
        let entity = FavoriteArtistEntity(context: viewContext)
        entity.artistId = artist.id
        entity.artistName = artist.name
        entity.favoritedAt = Date()

        saveAndUpdate()
    }

    private func removeArtistFavorite(_ artistId: String) {
        let request = NSFetchRequest<FavoriteArtistEntity>(entityName: "FavoriteArtistEntity")
        request.predicate = NSPredicate(format: "artistId == %@", artistId)

        do {
            let results = try viewContext.fetch(request)
            for entity in results {
                viewContext.delete(entity)
            }
            saveAndUpdate()
        } catch {
            print("Failed to remove artist favorite: \(error)")
        }
    }

    // MARK: - Album Favorites

    func isAlbumFavorite(_ albumId: String) -> Bool {
        favoriteAlbumIds.contains(albumId)
    }

    func toggleAlbumFavorite(_ album: Album) {
        if isAlbumFavorite(album.id) {
            removeAlbumFavorite(album.id)
        } else {
            addAlbumFavorite(album)
        }
    }

    private func addAlbumFavorite(_ album: Album) {
        let entity = FavoriteAlbumEntity(context: viewContext)
        entity.albumId = album.id
        entity.albumName = album.name
        entity.artistName = album.tracks.first?.artist
        entity.favoritedAt = Date()

        saveAndUpdate()
    }

    private func removeAlbumFavorite(_ albumId: String) {
        let request = NSFetchRequest<FavoriteAlbumEntity>(entityName: "FavoriteAlbumEntity")
        request.predicate = NSPredicate(format: "albumId == %@", albumId)

        do {
            let results = try viewContext.fetch(request)
            for entity in results {
                viewContext.delete(entity)
            }
            saveAndUpdate()
        } catch {
            print("Failed to remove album favorite: \(error)")
        }
    }

    // MARK: - Track Favorites

    func isTrackFavorite(_ s3Key: String) -> Bool {
        favoriteTrackKeys.contains(s3Key)
    }

    func toggleTrackFavorite(_ track: Track) {
        if isTrackFavorite(track.s3Key) {
            removeTrackFavorite(track.s3Key)
        } else {
            addTrackFavorite(track)
        }
    }

    private func addTrackFavorite(_ track: Track) {
        let entity = FavoriteTrackEntity(context: viewContext)
        entity.trackS3Key = track.s3Key
        entity.trackTitle = track.title
        entity.artistName = track.artist
        entity.favoritedAt = Date()

        saveAndUpdate()
    }

    private func removeTrackFavorite(_ s3Key: String) {
        let request = NSFetchRequest<FavoriteTrackEntity>(entityName: "FavoriteTrackEntity")
        request.predicate = NSPredicate(format: "trackS3Key == %@", s3Key)

        do {
            let results = try viewContext.fetch(request)
            for entity in results {
                viewContext.delete(entity)
            }
            saveAndUpdate()
        } catch {
            print("Failed to remove track favorite: \(error)")
        }
    }

    // MARK: - Fetch Methods

    func fetchFavoriteArtists() -> [FavoriteArtistEntity] {
        let request = NSFetchRequest<FavoriteArtistEntity>(entityName: "FavoriteArtistEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \FavoriteArtistEntity.artistName, ascending: true)]

        return (try? viewContext.fetch(request)) ?? []
    }

    func fetchFavoriteTracks() -> [FavoriteTrackEntity] {
        let request = NSFetchRequest<FavoriteTrackEntity>(entityName: "FavoriteTrackEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \FavoriteTrackEntity.trackTitle, ascending: true)]

        return (try? viewContext.fetch(request)) ?? []
    }

    func fetchFavoriteAlbums() -> [FavoriteAlbumEntity] {
        let request = NSFetchRequest<FavoriteAlbumEntity>(entityName: "FavoriteAlbumEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \FavoriteAlbumEntity.albumName, ascending: true)]

        return (try? viewContext.fetch(request)) ?? []
    }

    // MARK: - Private Helpers

    private func saveAndUpdate() {
        do {
            try viewContext.save()
            loadFavorites()
        } catch {
            print("Failed to save favorites: \(error)")
        }
    }

    private func loadFavorites() {
        // Load artist favorites
        let artistRequest = NSFetchRequest<FavoriteArtistEntity>(entityName: "FavoriteArtistEntity")
        if let artists = try? viewContext.fetch(artistRequest) {
            favoriteArtistIds = Set(artists.compactMap { $0.artistId })
        }

        // Load album favorites
        let albumRequest = NSFetchRequest<FavoriteAlbumEntity>(entityName: "FavoriteAlbumEntity")
        if let albums = try? viewContext.fetch(albumRequest) {
            favoriteAlbumIds = Set(albums.compactMap { $0.albumId })
        }

        // Load track favorites
        let trackRequest = NSFetchRequest<FavoriteTrackEntity>(entityName: "FavoriteTrackEntity")
        if let tracks = try? viewContext.fetch(trackRequest) {
            favoriteTrackKeys = Set(tracks.compactMap { $0.trackS3Key })
        }
    }

    private func observeChanges() {
        NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: viewContext)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadFavorites()
            }
            .store(in: &cancellables)
    }
}
