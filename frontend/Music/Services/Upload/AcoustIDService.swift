//
//  AcoustIDService.swift
//  Music
//
//  Chromaprint fingerprinting + AcoustID API for identifying untagged audio files.
//  Uses bundled fpcalc binary and queries AcoustID for recording matches.
//

import Foundation

#if os(macOS)

struct AcoustIDResult {
    let recordingMBID: String
    let title: String?
    let artist: String?
    let album: String?
    let score: Double
}

enum AcoustIDError: LocalizedError {
    case fpcalcNotFound
    case fpcalcFailed(String)
    case noApiKey
    case invalidResponse
    case noMatch

    var errorDescription: String? {
        switch self {
        case .fpcalcNotFound:
            return "fpcalc binary not found in app bundle"
        case .fpcalcFailed(let detail):
            return "Fingerprint generation failed: \(detail)"
        case .noApiKey:
            return "AcoustID API key not configured"
        case .invalidResponse:
            return "Invalid response from AcoustID API"
        case .noMatch:
            return "No fingerprint match found"
        }
    }
}

actor AcoustIDService {
    private static let apiURL = "https://api.acoustid.org/v2/lookup"
    private static let minRequestInterval: TimeInterval = 0.34  // ~3 req/sec

    private let apiKey: String
    private var lastRequestTime: Date = .distantPast
    private var cache: [String: AcoustIDResult] = [:]  // fileURL.path -> result

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    var isEnabled: Bool { !apiKey.isEmpty }

    // MARK: - Rate Limiting

    private func rateLimit() async {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < Self.minRequestInterval {
            try? await Task.sleep(for: .seconds(Self.minRequestInterval - elapsed))
        }
        lastRequestTime = Date()
    }

    // MARK: - Lookup

    /// Lookup a file by its audio fingerprint. The caller should use `generateFingerprint`
    /// first (outside the actor) for true parallelism, then pass the result here.
    func lookup(fingerprint: String, duration: Int, cacheKey: String) async throws -> AcoustIDResult {
        if let cached = cache[cacheKey] {
            return cached
        }

        guard isEnabled else { throw AcoustIDError.noApiKey }

        let result = try await queryAcoustID(fingerprint: fingerprint, duration: duration)

        cache[cacheKey] = result
        return result
    }

    // MARK: - Fingerprint Generation (nonisolated for parallelism)

    struct Fingerprint: Sendable {
        let fingerprint: String
        let duration: Int
    }

    /// Generates a Chromaprint fingerprint by running fpcalc as a subprocess.
    /// Note: waitUntilExit() blocks the calling thread. Acceptable because fingerprinting
    /// is capped at maxConcurrentFingerprints=4 and only runs on low-confidence tracks.
    nonisolated static func generateFingerprint(for fileURL: URL) throws -> Fingerprint {
        let fpcalcPath = findFpcalc()
        guard let fpcalcPath else {
            throw AcoustIDError.fpcalcNotFound
        }

        let process = Process()
        process.executableURL = fpcalcPath
        process.arguments = ["-json", fileURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()

        // Read stdout BEFORE waitUntilExit to avoid deadlock when output exceeds pipe buffer (~64KB)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw AcoustIDError.fpcalcFailed("exit code \(process.terminationStatus)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fp = json["fingerprint"] as? String,
              let dur = json["duration"] as? Double else {
            throw AcoustIDError.fpcalcFailed("invalid JSON output")
        }

        return Fingerprint(fingerprint: fp, duration: Int(dur))
    }

    private nonisolated static func findFpcalc() -> URL? {
        // Check app bundle first
        if let bundledPath = Bundle.main.url(forAuxiliaryExecutable: "fpcalc") {
            return bundledPath
        }

        // Fallback: check common install locations
        let paths = [
            "/usr/local/bin/fpcalc",
            "/opt/homebrew/bin/fpcalc",
            "/usr/bin/fpcalc"
        ]

        for path in paths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.isExecutableFile(atPath: path) {
                return url
            }
        }

        return nil
    }

    // MARK: - AcoustID API Query

    private func queryAcoustID(fingerprint: String, duration: Int) async throws -> AcoustIDResult {
        await rateLimit()

        guard let url = URL(string: Self.apiURL) else {
            throw AcoustIDError.invalidResponse
        }

        // Use POST — fingerprints can exceed GET URL length limits
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var parts = URLComponents()
        parts.queryItems = [
            URLQueryItem(name: "client", value: apiKey),
            URLQueryItem(name: "duration", value: String(duration)),
            URLQueryItem(name: "fingerprint", value: fingerprint),
            URLQueryItem(name: "meta", value: "recordings+releasegroups")
        ]
        request.httpBody = parts.percentEncodedQuery?.data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw AcoustIDError.invalidResponse
        }

        // Find best match with score > 0.8
        for result in results {
            guard let score = result["score"] as? Double, score > 0.8 else { continue }

            guard let recordings = result["recordings"] as? [[String: Any]],
                  let recording = recordings.first else { continue }

            let recordingMBID = recording["id"] as? String ?? ""
            let title = recording["title"] as? String

            // Extract artist
            var artist: String?
            if let artists = recording["artists"] as? [[String: Any]],
               let first = artists.first {
                artist = first["name"] as? String
            }

            // Extract album from release groups
            var album: String?
            if let releaseGroups = recording["releasegroups"] as? [[String: Any]],
               let first = releaseGroups.first {
                album = first["title"] as? String
            }

            return AcoustIDResult(
                recordingMBID: recordingMBID,
                title: title,
                artist: artist,
                album: album,
                score: score
            )
        }

        throw AcoustIDError.noMatch
    }
}

#endif
