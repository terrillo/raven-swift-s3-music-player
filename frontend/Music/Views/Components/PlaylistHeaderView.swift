//
//  PlaylistHeaderView.swift
//  Music
//
//  Header component for playlist detail view with play/shuffle actions.
//

import SwiftUI

struct PlaylistHeaderView: View {
    let hasPlayableTracks: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void

    var body: some View {
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
        .padding()
    }
}

//#Preview {
//    PlaylistHeaderView(
//        hasPlayableTracks: true,
//        onPlay: {},
//        onShuffle: {}
//    )
//}
