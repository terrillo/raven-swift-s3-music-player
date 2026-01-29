//
//  Image+DominantColor.swift
//  Music
//

import SwiftUI

#if os(iOS)
import UIKit

extension UIImage {
    var averageColor: Color? {
        guard let cgImage = self.cgImage else { return nil }

        let width = 1
        let height = 1
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }

        let pointer = data.bindMemory(to: UInt8.self, capacity: 4)
        let red = CGFloat(pointer[0]) / 255.0
        let green = CGFloat(pointer[1]) / 255.0
        let blue = CGFloat(pointer[2]) / 255.0

        return Color(red: red, green: green, blue: blue)
    }
}
#else
import AppKit

extension NSImage {
    var averageColor: Color? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width = 1
        let height = 1
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }

        let pointer = data.bindMemory(to: UInt8.self, capacity: 4)
        let red = CGFloat(pointer[0]) / 255.0
        let green = CGFloat(pointer[1]) / 255.0
        let blue = CGFloat(pointer[2]) / 255.0

        return Color(red: red, green: green, blue: blue)
    }
}
#endif

// MARK: - Color Brightness Detection

extension Color {
    /// Returns the luminance value (0-1) of this color
    var luminance: CGFloat {
        #if os(iOS)
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        let nsColor = NSColor(self)
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else { return 0.5 }
        let red = rgbColor.redComponent
        let green = rgbColor.greenComponent
        let blue = rgbColor.blueComponent
        #endif

        // Calculate relative luminance using sRGB formula
        return 0.299 * red + 0.587 * green + 0.114 * blue
    }

    /// Returns true if this color is considered "light" (should use dark text on it)
    var isLight: Bool {
        luminance > 0.5
    }

    /// Returns appropriate foreground color for contrast
    var contrastingForeground: Color {
        isLight ? .black : .white
    }

    /// Returns appropriate secondary foreground color for contrast
    var contrastingSecondary: Color {
        isLight ? .black.opacity(0.6) : .white.opacity(0.6)
    }

    /// Returns a version of this color that's visible on a dark background
    /// Brightens dark colors while preserving hue
    func visibleOnDark(minLuminance: CGFloat = 0.5) -> Color {
        let currentLuminance = self.luminance
        if currentLuminance >= minLuminance {
            return self
        }

        // Calculate how much we need to brighten
        let boost = minLuminance - currentLuminance + 0.2

        #if os(iOS)
        let uiColor = UIColor(self)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // Increase brightness while slightly reducing saturation for better readability
        let newBrightness = min(1.0, brightness + boost)
        let newSaturation = saturation * 0.8 // Slightly desaturate for softer look
        return Color(UIColor(hue: hue, saturation: newSaturation, brightness: newBrightness, alpha: alpha))
        #else
        let nsColor = NSColor(self)
        guard let hsbColor = nsColor.usingColorSpace(.sRGB) else { return self }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        hsbColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // Increase brightness while slightly reducing saturation for better readability
        let newBrightness = min(1.0, brightness + boost)
        let newSaturation = saturation * 0.8
        return Color(NSColor(hue: hue, saturation: newSaturation, brightness: newBrightness, alpha: alpha))
        #endif
    }

    /// Returns label colors with good dynamic range for dark backgrounds
    var labelPrimary: Color {
        visibleOnDark(minLuminance: 0.6)
    }

    var labelSecondary: Color {
        visibleOnDark(minLuminance: 0.45)
    }

    var labelTertiary: Color {
        visibleOnDark(minLuminance: 0.35)
    }
}
