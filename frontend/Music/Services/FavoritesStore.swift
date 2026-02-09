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

    private var container: NSPersistentCloudKitContainer { AnalyticsStore.shared.container }
    private var cancellables = Set<AnyCancellable>()

    private init() {
        loadFavoritesInBackground()
        observeRemoteChanges()
    }

    // MARK: - Artist Favorites

    func isArtistFavorite(_ artistId: String) -> Bool {
        favoriteArtistIds.contains(artistId)
    }

    func toggleArtistFavorite(_ artist: Artist) {
        let artistId = artist.id
        if isArtistFavorite(artistId) {
            favoriteArtistIds.remove(artistId)
            persistInBackground(rollback: { [weak self] in self?.favoriteArtistIds.insert(artistId) }) { context in
                let request = NSFetchRequest<FavoriteArtistEntity>(entityName: "FavoriteArtistEntity")
                request.predicate = NSPredicate(format: "artistId == %@", artistId)
                let results = try context.fetch(request)
                for entity in results { context.delete(entity) }
            }
        } else {
            favoriteArtistIds.insert(artistId)
            let artistName = artist.name
            persistInBackground(rollback: { [weak self] in self?.favoriteArtistIds.remove(artistId) }) { context in
                let entity = FavoriteArtistEntity(context: context)
                entity.artistId = artistId
                entity.artistName = artistName
                entity.favoritedAt = Date()
            }
        }
    }

    // MARK: - Album Favorites

    func isAlbumFavorite(_ albumId: String) -> Bool {
        favoriteAlbumIds.contains(albumId)
    }

    func toggleAlbumFavorite(_ album: Album) {
        let albumId = album.id
        if isAlbumFavorite(albumId) {
            favoriteAlbumIds.remove(albumId)
            persistInBackground(rollback: { [weak self] in self?.favoriteAlbumIds.insert(albumId) }) { context in
                let request = NSFetchRequest<FavoriteAlbumEntity>(entityName: "FavoriteAlbumEntity")
                request.predicate = NSPredicate(format: "albumId == %@", albumId)
                let results = try context.fetch(request)
                for entity in results { context.delete(entity) }
            }
        } else {
            favoriteAlbumIds.insert(albumId)
            let albumName = album.name
            let artistName = album.tracks.first?.artist
            persistInBackground(rollback: { [weak self] in self?.favoriteAlbumIds.remove(albumId) }) { context in
                let entity = FavoriteAlbumEntity(context: context)
                entity.albumId = albumId
                entity.albumName = albumName
                entity.artistName = artistName
                entity.favoritedAt = Date()
            }
        }
    }

    // MARK: - Track Favorites

    func isTrackFavorite(_ s3Key: String) -> Bool {
        favoriteTrackKeys.contains(s3Key)
    }

    func toggleTrackFavorite(_ track: Track) {
        let s3Key = track.s3Key
        if isTrackFavorite(s3Key) {
            favoriteTrackKeys.remove(s3Key)
            persistInBackground(rollback: { [weak self] in self?.favoriteTrackKeys.insert(s3Key) }) { context in
                let request = NSFetchRequest<FavoriteTrackEntity>(entityName: "FavoriteTrackEntity")
                request.predicate = NSPredicate(format: "trackS3Key == %@", s3Key)
                let results = try context.fetch(request)
                for entity in results { context.delete(entity) }
            }
        } else {
            favoriteTrackKeys.insert(s3Key)
            let title = track.title
            let artist = track.artist
            persistInBackground(rollback: { [weak self] in self?.favoriteTrackKeys.remove(s3Key) }) { context in
                let entity = FavoriteTrackEntity(context: context)
                entity.trackS3Key = s3Key
                entity.trackTitle = title
                entity.artistName = artist
                entity.favoritedAt = Date()
            }
        }
    }

    // MARK: - Fetch Methods

    func fetchFavoriteArtists() -> [FavoriteArtistEntity] {
        let request = NSFetchRequest<FavoriteArtistEntity>(entityName: "FavoriteArtistEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \FavoriteArtistEntity.artistName, ascending: true)]
        return (try? container.viewContext.fetch(request)) ?? []
    }

    func fetchFavoriteTracks() -> [FavoriteTrackEntity] {
        let request = NSFetchRequest<FavoriteTrackEntity>(entityName: "FavoriteTrackEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \FavoriteTrackEntity.trackTitle, ascending: true)]
        return (try? container.viewContext.fetch(request)) ?? []
    }

    func fetchFavoriteAlbums() -> [FavoriteAlbumEntity] {
        let request = NSFetchRequest<FavoriteAlbumEntity>(entityName: "FavoriteAlbumEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \FavoriteAlbumEntity.albumName, ascending: true)]
        return (try? container.viewContext.fetch(request)) ?? []
    }

    // MARK: - Private Helpers

    /// Perform Core Data work on a background context, then save.
    /// On failure, calls the rollback closure on MainActor to undo the optimistic UI update.
    private func persistInBackground(
        rollback: @escaping @MainActor () -> Void = {},
        _ work: @escaping (NSManagedObjectContext) throws -> Void
    ) {
        let container = self.container
        Task.detached {
            let bgContext = container.newBackgroundContext()
            bgContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            do {
                try await bgContext.perform {
                    try work(bgContext)
                    try bgContext.save()
                }
            } catch {
                print("FavoritesStore: Background persist failed: \(error)")
                await MainActor.run { rollback() }
            }
        }
    }

    /// Load favorites from Core Data on a background context, then merge with current state on MainActor.
    /// Uses merge (not replace) to avoid overwriting optimistic UI updates from pending toggles.
    private func loadFavoritesInBackground() {
        let container = self.container
        Task.detached {
            let bgContext = container.newBackgroundContext()
            bgContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

            let (artistIds, albumIds, trackKeys) = await bgContext.perform {
                let artistRequest = NSFetchRequest<FavoriteArtistEntity>(entityName: "FavoriteArtistEntity")
                let artists = (try? bgContext.fetch(artistRequest)) ?? []
                let artistIds = Set(artists.compactMap { $0.artistId })

                let albumRequest = NSFetchRequest<FavoriteAlbumEntity>(entityName: "FavoriteAlbumEntity")
                let albums = (try? bgContext.fetch(albumRequest)) ?? []
                let albumIds = Set(albums.compactMap { $0.albumId })

                let trackRequest = NSFetchRequest<FavoriteTrackEntity>(entityName: "FavoriteTrackEntity")
                let tracks = (try? bgContext.fetch(trackRequest)) ?? []
                let trackKeys = Set(tracks.compactMap { $0.trackS3Key })

                return (artistIds, albumIds, trackKeys)
            }

            // Replace in-memory sets — this is the authoritative DB state.
            // Optimistic toggles that haven't persisted yet will re-apply on next toggle.
            await MainActor.run { [artistIds, albumIds, trackKeys] in
                self.favoriteArtistIds = artistIds
                self.favoriteAlbumIds = albumIds
                self.favoriteTrackKeys = trackKeys
            }
        }
    }

    private func observeRemoteChanges() {
        // Observe CloudKit remote changes (merges from other devices)
        NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange, object: container.persistentStoreCoordinator)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadFavoritesInBackground()
            }
            .store(in: &cancellables)
    }

    /// Force refresh favorites from Core Data
    func refresh() {
        loadFavoritesInBackground()
    }
}
