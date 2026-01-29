//
//  QueueListView.swift
//  Music
//

import SwiftUI

struct QueueListView: View {
    let tracks: [Track]
    let accentColor: Color
    let emptyTitle: String
    let emptyMessage: String
    let onTrackTap: (Track) -> Void

    init(
        tracks: [Track],
        accentColor: Color,
        emptyTitle: String = "No Tracks",
        emptyMessage: String = "No tracks to display",
        onTrackTap: @escaping (Track) -> Void
    ) {
        self.tracks = tracks
        self.accentColor = accentColor
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.onTrackTap = onTrackTap
    }

    var body: some View {
        if tracks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.title2)
                    .foregroundStyle(accentColor.labelSecondary)
                Text(emptyTitle)
                    .font(.headline)
                    .foregroundStyle(accentColor.labelPrimary)
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(accentColor.labelSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            onTrackTap(track)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .foregroundStyle(accentColor.labelTertiary)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .font(.body)
                                        .foregroundStyle(accentColor.labelPrimary)
                                        .lineLimit(1)

                                    if let artist = track.artist {
                                        Text(artist)
                                            .font(.caption)
                                            .foregroundStyle(accentColor.labelSecondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                if let duration = track.duration {
                                    Text(formatDuration(duration))
                                        .font(.caption)
                                        .foregroundStyle(accentColor.labelTertiary)
                                        .monospacedDigit()
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        if index < tracks.count - 1 {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
            }
        }
    }

    private func formatDuration(_ duration: Int) -> String {
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Preview Helpers

extension Track {
    static func preview(
        title: String,
        artist: String,
        album: String,
        trackNumber: Int,
        duration: Int
    ) -> Track {
        Track(
            title: title,
            artist: artist,
            album: album,
            trackNumber: trackNumber,
            duration: duration,
            format: "m4a",
            s3Key: "\(artist)/\(album)/\(title).m4a",
            url: nil,
            embeddedArtworkUrl: nil,
            genre: nil,
            style: nil,
            mood: nil,
            theme: nil,
            albumArtist: artist,
            trackTotal: nil,
            discNumber: nil,
            discTotal: nil,
            year: 2024,
            composer: nil,
            comment: nil,
            bitrate: nil,
            samplerate: nil,
            channels: nil,
            filesize: nil,
            originalFormat: nil
        )
    }
}

#Preview("With Tracks") {
    QueueListView(
        tracks: [
            .preview(title: "Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera", trackNumber: 1, duration: 354),
            .preview(title: "Don't Stop Me Now", artist: "Queen", album: "Jazz", trackNumber: 2, duration: 209),
            .preview(title: "Somebody to Love", artist: "Queen", album: "A Day at the Races", trackNumber: 3, duration: 296),
        ],
        accentColor: .blue,
        emptyTitle: "No History",
        emptyMessage: "Play some songs to see your history"
    ) { track in
        print("Tapped: \(track.title)")
    }
    .frame(height: 200)
}

#Preview("Empty State") {
    QueueListView(
        tracks: [],
        accentColor: .purple,
        emptyTitle: "No History",
        emptyMessage: "Play some songs to see your history"
    ) { _ in }
    .frame(height: 200)
}
