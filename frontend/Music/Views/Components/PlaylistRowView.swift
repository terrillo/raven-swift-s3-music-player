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

    var body: some View {
        HStack(spacing: 12) {
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
