//
//  NavigationDestination.swift
//  Music
//

import Foundation

enum NavigationDestination: Hashable {
    case artist(Artist)
    case album(Album, Artist?)

    static func == (lhs: NavigationDestination, rhs: NavigationDestination) -> Bool {
        switch (lhs, rhs) {
        case let (.artist(a1), .artist(a2)):
            return a1.id == a2.id
        case let (.album(al1, ar1), .album(al2, ar2)):
            return al1.id == al2.id && ar1?.id == ar2?.id
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .artist(let artist):
            hasher.combine("artist")
            hasher.combine(artist.id)
        case .album(let album, let artist):
            hasher.combine("album")
            hasher.combine(album.id)
            hasher.combine(artist?.id)
        }
    }
}
