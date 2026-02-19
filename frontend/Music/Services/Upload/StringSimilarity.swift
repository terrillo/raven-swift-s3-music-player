//
//  StringSimilarity.swift
//  Music
//
//  Fuzzy string matching algorithms for improving metadata lookups.
//  Uses Jaro-Winkler and normalized Levenshtein distance.
//

import Foundation

#if os(macOS)

enum StringSimilarity {
    static let albumMatchThreshold = 0.85
    static let artistMatchThreshold = 0.90

    /// Returns the higher of Jaro-Winkler and normalized Levenshtein scores
    static func similarity(_ s1: String, _ s2: String) -> Double {
        let a = s1.lowercased()
        let b = s2.lowercased()
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        return max(jaroWinkler(a, b), normalizedLevenshtein(a, b))
    }

    /// Check if two strings are similar enough for album matching
    static func albumsMatch(_ s1: String, _ s2: String) -> Bool {
        similarity(s1, s2) >= albumMatchThreshold
    }

    /// Check if two strings are similar enough for artist matching
    static func artistsMatch(_ s1: String, _ s2: String) -> Bool {
        similarity(s1, s2) >= artistMatchThreshold
    }

    // MARK: - Jaro-Winkler

    static func jaroWinkler(_ s1: String, _ s2: String) -> Double {
        let jaro = jaroDistance(s1, s2)
        if jaro == 0 { return 0 }

        // Common prefix length (max 4)
        let a1 = Array(s1)
        let a2 = Array(s2)
        var prefixLen = 0
        let maxPrefix = min(4, min(a1.count, a2.count))
        for i in 0..<maxPrefix {
            if a1[i] == a2[i] {
                prefixLen += 1
            } else {
                break
            }
        }

        let p = 0.1  // Winkler scaling factor
        return jaro + Double(prefixLen) * p * (1.0 - jaro)
    }

    private static func jaroDistance(_ s1: String, _ s2: String) -> Double {
        let a1 = Array(s1)
        let a2 = Array(s2)
        let len1 = a1.count
        let len2 = a2.count

        if len1 == 0 && len2 == 0 { return 1.0 }
        if len1 == 0 || len2 == 0 { return 0.0 }

        let matchWindow = max(max(len1, len2) / 2 - 1, 0)
        var s1Matches = [Bool](repeating: false, count: len1)
        var s2Matches = [Bool](repeating: false, count: len2)

        var matches = 0
        var transpositions = 0

        for i in 0..<len1 {
            let start = max(0, i - matchWindow)
            let end = min(i + matchWindow + 1, len2)

            for j in start..<end {
                if s2Matches[j] || a1[i] != a2[j] { continue }
                s1Matches[i] = true
                s2Matches[j] = true
                matches += 1
                break
            }
        }

        if matches == 0 { return 0.0 }

        var k = 0
        for i in 0..<len1 {
            guard s1Matches[i] else { continue }
            while !s2Matches[k] { k += 1 }
            if a1[i] != a2[k] { transpositions += 1 }
            k += 1
        }

        let m = Double(matches)
        return (m / Double(len1) + m / Double(len2) + (m - Double(transpositions) / 2.0) / m) / 3.0
    }

    // MARK: - Normalized Levenshtein

    static func normalizedLevenshtein(_ s1: String, _ s2: String) -> Double {
        let a1 = Array(s1)
        let a2 = Array(s2)
        let len1 = a1.count
        let len2 = a2.count

        if len1 == 0 && len2 == 0 { return 1.0 }
        if len1 == 0 || len2 == 0 { return 0.0 }

        var prev = Array(0...len2)
        var curr = [Int](repeating: 0, count: len2 + 1)

        for i in 1...len1 {
            curr[0] = i
            for j in 1...len2 {
                let cost = a1[i - 1] == a2[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }

        let maxLen = max(len1, len2)
        return 1.0 - Double(prev[len2]) / Double(maxLen)
    }
}

#endif
