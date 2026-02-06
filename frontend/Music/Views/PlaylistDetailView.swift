//
//  PlaylistDetailView.swift
//  Music
//
//  Detail view for a playlist showing header and track list.
//

import SwiftUI

struct PlaylistDetailView: View {
    let playlist: PlaylistEntity
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    @State private var showingEditSheet = false
    @State private var showingAddTracks = false
    @State private var showingRecommendations = false
    @State private var pendingNavigation: NavigationDestination?
    @State private var shouldDismiss = false

    @Environment(\.dismiss) private var dismiss

    private var playlistTracks: [PlaylistTrackEntity] {
        PlaylistStore.shared.fetchTracks(for: playlist)
    }

    private var resolvedTracks: [(entity: PlaylistTrackEntity, track: Track?)] {
        let trackLookup = musicService.trackByS3Key
        return playlistTracks.map { entity in
            let track = entity.trackS3Key.flatMap { trackLookup[$0] }
            return (entity, track)
        }
    }

    private var playableTracks: [Track] {
        resolvedTracks.compactMap { pair in
            guard let track = pair.track else { return nil }
            return playerService.isTrackPlayable(track) ? track : nil
        }
    }

    private var hasPlayableTracks: Bool {
        !playableTracks.isEmpty
    }

    private var totalDuration: Int {
        resolvedTracks.compactMap { $0.track?.duration }.reduce(0, +)
    }

    var body: some View {
        Group {
            if playlistTracks.isEmpty {
                VStack(spacing: 20) {
                    PlaylistHeaderView(
                        playlist: playlist,
                        trackCount: 0,
                        totalDuration: 0,
                        hasPlayableTracks: false,
                        onPlay: {},
                        onShuffle: {},
                        onEdit: { showingEditSheet = true },
                        onRecommendations: { showingRecommendations = true }
                    )

                    ContentUnavailableView {
                        Label("No Songs", systemImage: "music.note")
                    } description: {
                        Text("Add songs to your playlist")
                    } actions: {
                        Button {
                            showingAddTracks = true
                        } label: {
                            Label("Add Songs", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                List {
                    Section {
                        PlaylistHeaderView(
                            playlist: playlist,
                            trackCount: playlistTracks.count,
                            totalDuration: totalDuration,
                            hasPlayableTracks: hasPlayableTracks,
                            onPlay: playAll,
                            onShuffle: shuffleAll,
                            onEdit: { showingEditSheet = true },
                            onRecommendations: { showingRecommendations = true }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                    Section {
                        ForEach(resolvedTracks, id: \.entity.id) { pair in
                            if let track = pair.track {
                                let isPlayable = playerService.isTrackPlayable(track)

                                Button {
                                    if isPlayable {
                                        playerService.play(track: track, queue: playableTracks)
                                    }
                                } label: {
                                    SongRow.songs(
                                        track: track,
                                        playerService: playerService,
                                        cacheService: cacheService,
                                        musicService: musicService,
                                        isPlayable: isPlayable,
                                        onNavigate: { pendingNavigation = $0 }
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(!isPlayable)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        removeTrack(pair.entity)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        removeTrack(pair.entity)
                                    } label: {
                                        Label("Remove from Playlist", systemImage: "minus.circle")
                                    }
                                }
                            } else {
                                // Track not found in catalog (deleted?)
                                HStack {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading) {
                                        Text(pair.entity.trackTitle ?? "Unknown Track")
                                            .font(.body)
                                        Text("Track not found in catalog")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        removeTrack(pair.entity)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.name ?? "Playlist")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddTracks = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            EditPlaylistSheet(playlist: playlist) {
                shouldDismiss = true
            }
        }
        .sheet(isPresented: $showingAddTracks) {
            AddTracksSheet(
                playlist: playlist,
                musicService: musicService,
                cacheService: cacheService
            )
        }
        .sheet(isPresented: $showingRecommendations) {
            PlaylistRecommendationsSheet(
                playlist: playlist,
                musicService: musicService,
                playerService: playerService,
                cacheService: cacheService
            )
        }
        .navigationDestination(item: $pendingNavigation) { destination in
            switch destination {
            case .artist(let artist):
                ArtistDetailView(
                    artist: artist,
                    musicService: musicService,
                    playerService: playerService,
                    cacheService: cacheService
                )
            case .album(let album, _):
                AlbumDetailView(
                    album: album,
                    musicService: musicService,
                    playerService: playerService,
                    cacheService: cacheService
                )
            }
        }
        .onChange(of: shouldDismiss) { _, newValue in
            if newValue {
                dismiss()
            }
        }
    }

    private func playAll() {
        guard let firstTrack = playableTracks.first else { return }
        playerService.play(track: firstTrack, queue: playableTracks)
    }

    private func shuffleAll() {
        playerService.shufflePlay(queue: playableTracks)
    }

    private func removeTrack(_ trackEntity: PlaylistTrackEntity) {
        PlaylistStore.shared.removeTrack(trackEntity, from: playlist)
    }
}

//#Preview {
//    NavigationStack {
//        PlaylistDetailView(
//            playlist: PlaylistEntity(),
//            musicService: MusicService(),
//            playerService: PlayerService()
//        )
//    }
//}
