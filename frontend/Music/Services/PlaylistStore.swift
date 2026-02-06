//
//  PlaylistStore.swift
//  Music
//
//  Manages manual playlists with iCloud sync via Core Data + CloudKit.
//  Follows the same pattern as FavoritesStore.
//

import CoreData
import Combine
import SwiftUI

@MainActor
@Observable
class PlaylistStore {
    static let shared = PlaylistStore()

    private(set) var playlists: [PlaylistEntity] = []

    private var viewContext: NSManagedObjectContext { AnalyticsStore.shared.viewContext }
    private var cancellables = Set<AnyCancellable>()

    private init() {
        loadPlaylists()
        observeChanges()
        observeRemoteChanges()
    }

    // MARK: - Playlist CRUD

    @discardableResult
    func createPlaylist(
        name: String,
        description: String? = nil,
        coverImageUrl: String? = nil
    ) -> PlaylistEntity {
        let entity = PlaylistEntity(context: viewContext)
        entity.id = UUID()
        entity.name = name
        entity.playlistDescription = description
        entity.coverImageUrl = coverImageUrl
        entity.createdAt = Date()
        entity.modifiedAt = Date()

        saveAndUpdate()
        return entity
    }

    func updatePlaylist(
        _ playlist: PlaylistEntity,
        name: String? = nil,
        description: String? = nil,
        coverImageUrl: String? = nil
    ) {
        if let name = name {
            playlist.name = name
        }
        if let description = description {
            playlist.playlistDescription = description
        }
        if let coverImageUrl = coverImageUrl {
            playlist.coverImageUrl = coverImageUrl
        }
        playlist.modifiedAt = Date()

        saveAndUpdate()
    }

    func deletePlaylist(_ playlist: PlaylistEntity) {
        viewContext.delete(playlist)
        saveAndUpdate()
    }

    // MARK: - Track Management

    func addTrack(_ track: Track, to playlist: PlaylistEntity) {
        // Check if track already exists in playlist
        let existingTracks = fetchTracks(for: playlist)
        if existingTracks.contains(where: { $0.trackS3Key == track.s3Key }) {
            return // Already in playlist
        }

        let entity = PlaylistTrackEntity(context: viewContext)
        entity.id = UUID()
        entity.trackS3Key = track.s3Key
        entity.trackTitle = track.title
        entity.artistName = track.artist
        entity.sortOrder = Int32(existingTracks.count)
        entity.addedAt = Date()
        entity.playlist = playlist

        playlist.modifiedAt = Date()
        saveAndUpdate()
    }

    func addTracks(_ tracks: [Track], to playlist: PlaylistEntity) {
        let existingTracks = fetchTracks(for: playlist)
        let existingKeys = Set(existingTracks.compactMap { $0.trackS3Key })
        var nextOrder = Int32(existingTracks.count)

        for track in tracks {
            if existingKeys.contains(track.s3Key) {
                continue // Skip duplicates
            }

            let entity = PlaylistTrackEntity(context: viewContext)
            entity.id = UUID()
            entity.trackS3Key = track.s3Key
            entity.trackTitle = track.title
            entity.artistName = track.artist
            entity.sortOrder = nextOrder
            entity.addedAt = Date()
            entity.playlist = playlist
            nextOrder += 1
        }

        playlist.modifiedAt = Date()
        saveAndUpdate()
    }

    func removeTrack(_ trackEntity: PlaylistTrackEntity, from playlist: PlaylistEntity) {
        viewContext.delete(trackEntity)
        playlist.modifiedAt = Date()

        // Reorder remaining tracks
        let remainingTracks = fetchTracks(for: playlist)
        for (index, track) in remainingTracks.enumerated() {
            track.sortOrder = Int32(index)
        }

        saveAndUpdate()
    }

    func reorderTracks(in playlist: PlaylistEntity, from source: IndexSet, to destination: Int) {
        var tracks = fetchTracks(for: playlist)
        tracks.move(fromOffsets: source, toOffset: destination)

        for (index, track) in tracks.enumerated() {
            track.sortOrder = Int32(index)
        }

        playlist.modifiedAt = Date()
        saveAndUpdate()
    }

    // MARK: - Queries

    func fetchTracks(for playlist: PlaylistEntity) -> [PlaylistTrackEntity] {
        let request = NSFetchRequest<PlaylistTrackEntity>(entityName: "PlaylistTrackEntity")
        request.predicate = NSPredicate(format: "playlist == %@", playlist)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PlaylistTrackEntity.sortOrder, ascending: true)]

        return (try? viewContext.fetch(request)) ?? []
    }

    func playlist(withId id: UUID) -> PlaylistEntity? {
        playlists.first { $0.id == id }
    }

    func containsTrack(_ s3Key: String, in playlist: PlaylistEntity) -> Bool {
        let tracks = fetchTracks(for: playlist)
        return tracks.contains { $0.trackS3Key == s3Key }
    }

    // MARK: - Private Helpers

    private func saveAndUpdate() {
        do {
            try viewContext.save()
            loadPlaylists()
        } catch {
            print("Failed to save playlists: \(error)")
        }
    }

    private func loadPlaylists() {
        let request = NSFetchRequest<PlaylistEntity>(entityName: "PlaylistEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PlaylistEntity.modifiedAt, ascending: false)]

        playlists = (try? viewContext.fetch(request)) ?? []
    }

    private func observeChanges() {
        NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: viewContext)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadPlaylists()
            }
            .store(in: &cancellables)
    }

    private func observeRemoteChanges() {
        // Observe CloudKit remote changes
        NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange, object: AnalyticsStore.shared.container.persistentStoreCoordinator)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadPlaylists()
            }
            .store(in: &cancellables)
    }

    /// Force refresh playlists from Core Data (useful after iCloud sync)
    func refresh() {
        loadPlaylists()
    }
}
