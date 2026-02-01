//
//  StorageService.swift
//  Music
//
//  S3-compatible storage service for DigitalOcean Spaces.
//  Uses direct HTTP with AWS Signature V4 signing.
//

import Foundation
import CryptoKit

#if os(macOS)

actor StorageService {
    private let config: UploadConfiguration
    private var existingKeysCache: Set<String>?

    // Content types for audio files
    private static let audioContentTypes: [String: String] = [
        "mp3": "audio/mpeg",
        "m4a": "audio/x-m4a",
        "flac": "audio/flac",
        "wav": "audio/wav",
        "aac": "audio/aac"
    ]

    private static let maxImageSize = 10 * 1024 * 1024  // 10MB
    private static let allowedImageTypes = Set(["image/jpeg", "image/png", "image/webp", "image/gif"])

    init(config: UploadConfiguration) {
        self.config = config
    }

    // MARK: - Public URL Generation

    func getPublicURL(for s3Key: String) -> String {
        "\(config.cdnBaseURL)/\(s3Key)"
    }

    private func prefixedKey(_ s3Key: String) -> String {
        "\(config.spacesPrefix)/\(s3Key)"
    }

    // MARK: - List All Files

    /// List all files in the bucket under the configured prefix.
    /// Returns a Set for O(1) lookups.
    func listAllFiles() async throws -> Set<String> {
        var existingKeys = Set<String>()
        var continuationToken: String?

        repeat {
            let (keys, nextToken) = try await listFilesBatch(continuationToken: continuationToken)
            existingKeys.formUnion(keys)
            continuationToken = nextToken
        } while continuationToken != nil

        self.existingKeysCache = existingKeys
        return existingKeys
    }

    private func listFilesBatch(continuationToken: String?) async throws -> (keys: [String], nextToken: String?) {
        var queryItems = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "prefix", value: "\(config.spacesPrefix)/"),
            URLQueryItem(name: "max-keys", value: "1000")
        ]

        if let token = continuationToken {
            queryItems.append(URLQueryItem(name: "continuation-token", value: token))
        }

        guard var components = URLComponents(string: config.spacesEndpoint) else {
            throw StorageError.invalidURL
        }
        components.path = "/"  // Virtual-hosted style: bucket is in hostname, not path
        components.queryItems = queryItems

        guard let url = components.url else {
            throw StorageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        signRequest(&request, method: "GET", headers: [:], payloadHash: AWSV4Signer.emptyPayloadHash)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StorageError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "No response body"
            print("❌ S3 List Error (\(httpResponse.statusCode)):")
            print("   URL: \(url)")
            print("   Response: \(errorBody)")
            throw StorageError.httpError(httpResponse.statusCode, errorBody)
        }

        // Parse XML response
        let parser = S3ListResponseParser(prefix: "\(config.spacesPrefix)/")
        return try parser.parse(data)
    }

    // MARK: - File Existence Check

    func setExistingKeysCache(_ keys: Set<String>) {
        self.existingKeysCache = keys
    }

    func fileExists(_ s3Key: String) async -> Bool {
        // Check cache first
        if let cache = existingKeysCache {
            return cache.contains(s3Key)
        }

        // Fallback to HEAD request
        do {
            return try await headObject(s3Key: s3Key)
        } catch {
            return false
        }
    }

    private func headObject(s3Key: String) async throws -> Bool {
        // Virtual-hosted style: bucket in hostname, key in path
        let fullPath = "/\(prefixedKey(s3Key))"
        guard let encodedPath = fullPath.addingPercentEncoding(withAllowedCharacters: .s3PathAllowed),
              let url = URL(string: "\(config.spacesEndpoint)\(encodedPath)") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        signRequest(&request, method: "HEAD", headers: [:], payloadHash: AWSV4Signer.emptyPayloadHash)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }

        return httpResponse.statusCode == 200
    }

    // MARK: - Upload File

    /// Upload a file to Spaces with retry logic.
    func uploadFile(at path: URL, s3Key: String, contentType: String? = nil) async throws -> String {
        let data = try Data(contentsOf: path)
        let resolvedContentType = contentType ?? Self.audioContentTypes[path.pathExtension.lowercased()] ?? "application/octet-stream"

        return try await uploadData(data, s3Key: s3Key, contentType: resolvedContentType)
    }

    /// Upload raw bytes to Spaces.
    func uploadData(_ data: Data, s3Key: String, contentType: String) async throws -> String {
        // Check if already uploaded
        if await fileExists(s3Key) {
            return getPublicURL(for: s3Key)
        }

        let maxRetries = 3

        for attempt in 0..<maxRetries {
            do {
                try await performUpload(data: data, s3Key: s3Key, contentType: contentType)

                // Add to cache on success
                existingKeysCache?.insert(s3Key)

                return getPublicURL(for: s3Key)
            } catch {
                if attempt < maxRetries - 1 {
                    let waitTime = pow(2.0, Double(attempt + 1))
                    try await Task.sleep(for: .seconds(waitTime))
                } else {
                    throw error
                }
            }
        }

        throw StorageError.uploadFailed("Max retries exceeded")
    }

    /// Force upload data, overwriting if exists. Used for catalog.json.
    func forceUploadData(_ data: Data, s3Key: String, contentType: String) async throws -> String {
        let maxRetries = 3

        for attempt in 0..<maxRetries {
            do {
                try await performUpload(data: data, s3Key: s3Key, contentType: contentType)
                existingKeysCache?.insert(s3Key)
                return getPublicURL(for: s3Key)
            } catch {
                if attempt < maxRetries - 1 {
                    let waitTime = pow(2.0, Double(attempt + 1))
                    try await Task.sleep(for: .seconds(waitTime))
                } else {
                    throw error
                }
            }
        }

        throw StorageError.uploadFailed("Max retries exceeded")
    }

    private func performUpload(data: Data, s3Key: String, contentType: String) async throws {
        // Virtual-hosted style: bucket in hostname, key in path
        let fullPath = "/\(prefixedKey(s3Key))"
        guard let encodedPath = fullPath.addingPercentEncoding(withAllowedCharacters: .s3PathAllowed),
              let url = URL(string: "\(config.spacesEndpoint)\(encodedPath)") else {
            throw StorageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("public-read", forHTTPHeaderField: "x-amz-acl")
        request.httpBody = data

        let payloadHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let headers = [
            "Content-Type": contentType,
            "x-amz-acl": "public-read"
        ]
        signRequest(&request, method: "PUT", headers: headers, payloadHash: payloadHash)

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StorageError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: responseData, encoding: .utf8)
            throw StorageError.httpError(httpResponse.statusCode, errorMessage)
        }
    }

    // MARK: - Download and Upload Image

    /// Download an image from URL and upload to Spaces.
    func downloadAndUploadImage(
        from imageURL: String,
        artist: String,
        album: String
    ) async throws -> String? {
        guard !imageURL.isEmpty, let url = URL(string: imageURL) else {
            return nil
        }

        let s3Key = Identifiers.generateCoverArtworkKey(artist: artist, album: album)

        // Check if already uploaded
        if await fileExists(s3Key) {
            return getPublicURL(for: s3Key)
        }

        // Validate image with HEAD request
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"

        let (_, headResponse) = try await URLSession.shared.data(for: headRequest)

        guard let httpResponse = headResponse as? HTTPURLResponse else {
            return nil
        }

        if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(contentLength), length > Self.maxImageSize {
            return nil
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: ";").first ?? ""
        if !contentType.isEmpty && !Self.allowedImageTypes.contains(contentType) {
            return nil
        }

        // Download the image
        let (data, _) = try await URLSession.shared.data(from: url)

        guard data.count <= Self.maxImageSize else {
            return nil
        }

        return try await uploadData(data, s3Key: s3Key, contentType: contentType.isEmpty ? "image/jpeg" : contentType)
    }

    /// Download an artist image from URL and upload to Spaces.
    func downloadAndUploadArtistImage(
        from imageURL: String,
        artist: String
    ) async throws -> String? {
        guard !imageURL.isEmpty, let url = URL(string: imageURL) else {
            return nil
        }

        let s3Key = Identifiers.generateArtistImageKey(artist: artist)

        // Check if already uploaded
        if await fileExists(s3Key) {
            return getPublicURL(for: s3Key)
        }

        // Download the image
        let (data, response) = try await URLSession.shared.data(from: url)

        guard data.count <= Self.maxImageSize else {
            return nil
        }

        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"

        return try await uploadData(data, s3Key: s3Key, contentType: contentType)
    }

    /// Upload embedded artwork bytes to Spaces.
    func uploadArtworkBytes(
        _ data: Data,
        mimeType: String,
        artist: String,
        album: String
    ) async throws -> String {
        let s3Key = Identifiers.generateEmbeddedArtworkKey(artist: artist, album: album, mimeType: mimeType)
        return try await uploadData(data, s3Key: s3Key, contentType: mimeType)
    }

    // MARK: - AWS Signature V4

    private func signRequest(
        _ request: inout URLRequest,
        method: String,
        headers: [String: String],
        payloadHash: String
    ) {
        let signer = AWSV4Signer(
            accessKey: config.spacesKey,
            secretKey: config.spacesSecret,
            region: config.spacesRegion,
            service: "s3"
        )
        signer.sign(&request, method: method, headers: headers, payloadHash: payloadHash)
    }
}

// MARK: - AWS V4 Signer

private struct AWSV4Signer {
    let accessKey: String
    let secretKey: String
    let region: String
    let service: String

    static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    func sign(
        _ request: inout URLRequest,
        method: String,
        headers: [String: String],
        payloadHash: String
    ) {
        guard let url = request.url else { return }

        let date = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let amzDate = dateFormatter.string(from: date)

        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: date)

        // Set required headers
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(url.host ?? "", forHTTPHeaderField: "Host")

        // Build canonical request
        // For S3, the canonical URI should NOT be double-encoded
        // url.path is already decoded, so we need to re-encode it for the signature
        let rawPath = url.path.isEmpty ? "/" : url.path
        let canonicalURI = rawPath.addingPercentEncoding(withAllowedCharacters: .s3PathAllowed) ?? rawPath

        // Build canonical query string: sorted by param name, properly URI-encoded
        let canonicalQueryString: String
        if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !queryItems.isEmpty {
            // Sort by parameter name and manually encode values per AWS Sig V4 spec
            let sortedParams = queryItems.sorted { $0.name < $1.name }
            canonicalQueryString = sortedParams.map { item in
                let encodedName = item.name.addingPercentEncoding(withAllowedCharacters: .s3QueryAllowed) ?? item.name
                let encodedValue = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: .s3QueryAllowed) ?? ""
                return "\(encodedName)=\(encodedValue)"
            }.joined(separator: "&")
        } else {
            canonicalQueryString = ""
        }

        // Build headers dictionary for signing
        var headersToSign: [String: String] = [
            "host": url.host ?? "",
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": amzDate
        ]

        // Add custom headers
        for (key, value) in headers {
            headersToSign[key.lowercased()] = value
        }

        // Sort headers by lowercase name
        let sortedHeaders = headersToSign.sorted { $0.key < $1.key }
        let signedHeadersString = sortedHeaders.map { $0.key }.joined(separator: ";")

        // Each canonical header ends with \n, and there's a \n after the last header before signed headers
        let canonicalHeaders = sortedHeaders.map { "\($0.key):\($0.value)\n" }.joined()

        // Build canonical request per AWS Sig V4 spec:
        // METHOD\n + URI\n + QUERY\n + HEADERS\n + SIGNEDHEADERS\n + PAYLOAD
        let canonicalRequest = "\(method)\n\(canonicalURI)\n\(canonicalQueryString)\n\(canonicalHeaders)\n\(signedHeadersString)\n\(payloadHash)"

        #if DEBUG
        print("📝 Canonical Request:")
        print("---")
        print(canonicalRequest)
        print("---")
        #endif

        // Create string to sign
        let algorithm = "AWS4-HMAC-SHA256"
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let canonicalRequestHash = SHA256.hash(data: Data(canonicalRequest.utf8)).map { String(format: "%02x", $0) }.joined()

        let stringToSign = """
        \(algorithm)
        \(amzDate)
        \(credentialScope)
        \(canonicalRequestHash)
        """

        // Calculate signature
        let signature = calculateSignature(
            stringToSign: stringToSign,
            dateStamp: dateStamp
        )

        // Build authorization header
        let authorization = "\(algorithm) Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeadersString), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    private func calculateSignature(stringToSign: String, dateStamp: String) -> String {
        let kDate = hmacSHA256(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data(service.utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8))
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        let key = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(signature)
    }
}

// MARK: - S3 List Response Parser

private class S3ListResponseParser: NSObject, XMLParserDelegate {
    private let prefix: String
    private var keys: [String] = []
    private var nextToken: String?
    private var currentElement = ""
    private var currentValue = ""
    private var isTruncated = false

    init(prefix: String) {
        self.prefix = prefix
        super.init()
    }

    func parse(_ data: Data) throws -> (keys: [String], nextToken: String?) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw StorageError.parseError
        }
        return (keys, isTruncated ? nextToken : nil)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentValue = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmedValue = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "Key":
            if trimmedValue.hasPrefix(prefix) {
                let s3Key = String(trimmedValue.dropFirst(prefix.count))
                keys.append(s3Key)
            }
        case "NextContinuationToken":
            nextToken = trimmedValue
        case "IsTruncated":
            isTruncated = trimmedValue.lowercased() == "true"
        default:
            break
        }
    }
}

// MARK: - Storage Errors

enum StorageError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String?)
    case uploadFailed(String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code, let message):
            return "HTTP error \(code): \(message ?? "Unknown")"
        case .uploadFailed(let reason):
            return "Upload failed: \(reason)"
        case .parseError:
            return "Failed to parse S3 response"
        }
    }
}

// MARK: - S3 Character Sets for AWS Sig V4

extension CharacterSet {
    /// Characters allowed in S3 path components (per AWS Signature V4 spec)
    /// Unreserved characters: A-Z a-z 0-9 - _ . ~
    /// Plus forward slash for path separators
    static let s3PathAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~/")
        return allowed
    }()

    /// Characters allowed in S3 query string values (per AWS Signature V4 spec)
    /// Unreserved characters only: A-Z a-z 0-9 - _ . ~
    /// Note: Does NOT include / (forward slash must be encoded as %2F in query values)
    static let s3QueryAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return allowed
    }()
}

#endif
