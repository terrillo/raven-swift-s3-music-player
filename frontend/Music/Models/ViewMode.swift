//
//  ViewMode.swift
//  Music
//

import Foundation

enum ViewMode: String, CaseIterable {
    case list
    case grid

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}
