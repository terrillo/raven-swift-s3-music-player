//
//  PlaylistRowView.swift
//  Music
//
//  A row component for displaying a playlist in a list.
//

import SwiftUI

struct PlaylistRowView: View {
    let playlist: PlaylistEntity
    var cacheService: CacheService?

    private var trackCount: Int {
        PlaylistStore.shared.fetchTracks(for: playlist).count
    }

    private var coverUrl: String? {
        if let custom = playlist.coverImageUrl, !custom.isEmpty {
            return custom
        }
        // Use first track's artwork as cover
        let tracks = PlaylistStore.shared.fetchTracks(for: playlist)
        return tracks.first?.trackS3Key.flatMap { s3Key in
            // Return nil - artwork will need to be resolved from catalog
            nil
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Playlist artwork
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))

                Image(systemName: "music.note.list")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name ?? "Untitled")
                    .font(.headline)
                    .lineLimit(1)

                Text("\(trackCount) songs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

//#Preview {
//    List {
//        PlaylistRowView(playlist: PlaylistEntity())
//    }
//}
