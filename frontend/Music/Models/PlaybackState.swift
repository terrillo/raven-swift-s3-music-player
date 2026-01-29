//
//  PlaybackState.swift
//  Music
//

import Foundation

struct PlaybackState: Codable {
    let currentTrackKey: String?        // s3Key of current track
    let currentAlbumId: String?         // Album.id (Artist/Album)
    let queueTrackKeys: [String]        // s3Keys of all queue tracks
    let currentIndex: Int
    let currentTime: TimeInterval       // Playback position in seconds
    let isShuffled: Bool
    let repeatMode: Int                 // RepeatMode raw value
    let playHistoryKeys: [String]       // s3Keys for history navigation
    let playHistoryIndex: Int
    let savedAt: Date

    private static let userDefaultsKey = "savedPlaybackState"

    static func save(_ state: PlaybackState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    static func load() -> PlaybackState? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(PlaybackState.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}
