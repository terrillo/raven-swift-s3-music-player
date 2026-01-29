//
//  Color+AppAccent.swift
//  Music
//

import SwiftUI

extension Color {
    static var appAccent: Color {
        #if os(macOS)
        return .accentColor
        #else
        return .red
        #endif
    }
}
