//
//  PlaylistHeaderView.swift
//  Music
//
//  Header component for playlist detail view with artwork, title, and actions.
//

import SwiftUI

struct PlaylistHeaderView: View {
    let playlist: PlaylistEntity
    let trackCount: Int
    let totalDuration: Int
    let hasPlayableTracks: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let onEdit: () -> Void
    let onRecommendations: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Artwork
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [.purple.opacity(0.6), .blue.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "music.note.list")
                    .font(.system(size: 60))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: 200, height: 200)
            .shadow(radius: 8)

            // Title and description
            VStack(spacing: 4) {
                Text(playlist.name ?? "Untitled")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                if let description = playlist.playlistDescription, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                Text("\(trackCount) songs \(formattedDuration)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    onPlay()
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasPlayableTracks)

                Button {
                    onShuffle()
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!hasPlayableTracks)
            }

            // Secondary actions
            HStack(spacing: 20) {
                Button {
                    onEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(.subheadline)
                }

                Button {
                    onRecommendations()
                } label: {
                    Label("Suggestions", systemImage: "wand.and.stars")
                        .font(.subheadline)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var formattedDuration: String {
        guard totalDuration > 0 else { return "" }
        let hours = totalDuration / 3600
        let minutes = (totalDuration % 3600) / 60
        if hours > 0 {
            return "• \(hours)h \(minutes)m"
        } else {
            return "• \(minutes) min"
        }
    }
}

//#Preview {
//    PlaylistHeaderView(
//        playlist: PlaylistEntity(),
//        trackCount: 25,
//        totalDuration: 4500,
//        hasPlayableTracks: true,
//        onPlay: {},
//        onShuffle: {},
//        onEdit: {},
//        onRecommendations: {}
//    )
//}
