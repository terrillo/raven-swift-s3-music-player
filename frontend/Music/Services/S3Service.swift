//
//  S3Service.swift
//  Music
//
//  S3-compatible storage service using custom AWS Signature V4 signing.
//  Works with DigitalOcean Spaces and other S3-compatible services.
//

import Foundation
import CryptoKit
import SwiftData

#if os(macOS)

// MARK: - S3Service

/// Service for interacting with S3-compatible storage (DigitalOcean Spaces).
/// Uses custom AWS Signature V4 signing without external SDK dependencies.
actor S3Service {
    private let credentials: S3Credentials
    private var existingKeysCache: Set<String>?

    // URLSession optimized for uploads
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600  // 10 minutes for large files
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    init(credentials: S3Credentials) {
        self.credentials = credentials
    }

    // MARK: - Public Methods

    /// List all files with SwiftData caching (5-minute TTL).
    /// Returns cached keys if available and not expired, otherwise fetches fresh.
    func listAllFilesCached(modelContainer: ModelContainer, forceRefresh: Bool = false) async throws -> Set<String> {
        let bucket = credentials.bucket
        let prefix = credentials.prefix

        // Check cache on main actor
        if !forceRefresh {
            let cached = await MainActor.run { () -> (keys: Set<String>, age: Int)? in
                let context = modelContainer.mainContext
                let descriptor = FetchDescriptor<CachedS3Keys>(
                    predicate: #Predicate { $0.bucket == bucket && $0.prefix == prefix }
                )
                guard let cache = try? context.fetch(descriptor).first, !cache.isExpired else {
                    return nil
                }
                return (cache.keys, cache.ageSeconds)
            }

            if let cached {
                print("[S3Service] Using cached keys (\(cached.keys.count) keys, \(cached.age)s old)")
                existingKeysCache = cached.keys
                return cached.keys
            }
        }

        // Fetch fresh from S3
        let keys = try await listAllFiles()

        // Update cache on main actor
        await MainActor.run {
            let context = modelContainer.mainContext

            // Delete old cache entries for this bucket/prefix
            let descriptor = FetchDescriptor<CachedS3Keys>(
                predicate: #Predicate { $0.bucket == bucket && $0.prefix == prefix }
            )
            if let existing = try? context.fetch(descriptor) {
                for cache in existing {
                    context.delete(cache)
                }
            }

            // Insert new cache
            let newCache = CachedS3Keys(bucket: bucket, prefix: prefix, keys: keys)
            context.insert(newCache)
            try? context.save()
            print("[S3Service] Cached \(keys.count) keys (TTL: \(CachedS3Keys.ttlSeconds)s)")
        }

        return keys
    }

    /// List all files in the bucket under the configured prefix.
    /// Returns a set of S3 keys (without prefix) for O(1) lookups.
    func listAllFiles() async throws -> Set<String> {
        print("[S3Service] listAllFiles() called")
        print("[S3Service] Bucket: \(credentials.bucket), Region: \(credentials.region), Prefix: \(credentials.prefix)")

        var allKeys: Set<String> = []
        var continuationToken: String? = nil
        let prefix = "\(credentials.prefix)/"
        var pageCount = 0

        repeat {
            pageCount += 1
            print("[S3Service] Fetching page \(pageCount)...")

            var queryItems = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix),
                URLQueryItem(name: "max-keys", value: "1000")
            ]
            if let token = continuationToken {
                queryItems.append(URLQueryItem(name: "continuation-token", value: token))
            }

            let request = try signedRequest(
                method: "GET",
                path: "/",
                queryItems: queryItems
            )

            print("[S3Service] Request URL: \(request.url?.absoluteString ?? "nil")")

            let (data, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                print("[S3Service] Response status: \(httpResponse.statusCode)")
            }

            try validateResponse(response, data: data)

            // Parse XML response
            let parser = S3ListParser(prefix: prefix)
            parser.parse(data)

            print("[S3Service] Page \(pageCount): Found \(parser.keys.count) keys")

            for key in parser.keys {
                allKeys.insert(key)
            }

            continuationToken = parser.nextContinuationToken
            print("[S3Service] Has more pages: \(continuationToken != nil)")

        } while continuationToken != nil

        print("[S3Service] Total keys found: \(allKeys.count)")
        existingKeysCache = allKeys
        return allKeys
    }

    /// Set the cache of existing keys for efficient lookups.
    func setExistingKeysCache(_ keys: Set<String>) {
        existingKeysCache = keys
    }

    /// Check if a file exists in S3.
    func fileExists(_ s3Key: String) async throws -> Bool {
        // Check cache first
        if let cache = existingKeysCache {
            return cache.contains(s3Key)
        }

        // Fall back to HEAD request
        let request = try signedRequest(
            method: "HEAD",
            path: "/\(credentials.prefix)/\(s3Key)"
        )

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }

    /// Upload data to S3 with retry logic.
    /// Returns the public CDN URL on success.
    func uploadData(_ data: Data, s3Key: String, contentType: String) async throws -> String {
        let maxRetries = 3

        for attempt in 0..<maxRetries {
            do {
                let path = "/\(credentials.prefix)/\(s3Key)"
                var request = try signedRequest(
                    method: "PUT",
                    path: path,
                    contentType: contentType,
                    body: data
                )
                request.setValue("public-read", forHTTPHeaderField: "x-amz-acl")

                let (_, response) = try await session.upload(for: request, from: data)
                try validateResponse(response)

                // Update cache
                existingKeysCache?.insert(s3Key)

                return getPublicUrl(for: s3Key)

            } catch {
                if attempt < maxRetries - 1 {
                    let waitTime = pow(2.0, Double(attempt + 1))
                    try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                } else {
                    throw error
                }
            }
        }

        throw S3Error.uploadFailed
    }

    /// Upload a file from disk to S3.
    /// Returns the public CDN URL on success.
    func uploadFile(at fileURL: URL, s3Key: String, contentType: String, progress: ((Double) -> Void)? = nil) async throws -> String {
        let data = try Data(contentsOf: fileURL)
        return try await uploadData(data, s3Key: s3Key, contentType: contentType)
    }

    /// Upload a large file using multipart upload.
    /// For files > 8MB (matches backend boto3 TransferConfig). Returns the public CDN URL on success.
    func uploadLargeFile(at fileURL: URL, s3Key: String, contentType: String, progress: ((Double) -> Void)? = nil) async throws -> String {
        let data = try Data(contentsOf: fileURL)
        let fileSize = data.count

        // Use regular upload for files under 8MB (matches backend boto3 TransferConfig)
        if fileSize < 8 * 1024 * 1024 {
            return try await uploadData(data, s3Key: s3Key, contentType: contentType)
        }

        // Multipart upload for larger files
        let uploadId = try await initiateMultipartUpload(s3Key: s3Key, contentType: contentType)

        do {
            let partSize = 10 * 1024 * 1024  // 10MB per part
            var parts: [(Int, String)] = []  // (partNumber, ETag)

            var offset = 0
            var partNumber = 1

            while offset < fileSize {
                let end = min(offset + partSize, fileSize)
                let partData = data[offset..<end]

                let etag = try await uploadPart(
                    s3Key: s3Key,
                    uploadId: uploadId,
                    partNumber: partNumber,
                    data: Data(partData)
                )

                parts.append((partNumber, etag))
                offset = end
                partNumber += 1

                progress?(Double(offset) / Double(fileSize))
            }

            try await completeMultipartUpload(s3Key: s3Key, uploadId: uploadId, parts: parts)

            existingKeysCache?.insert(s3Key)
            return getPublicUrl(for: s3Key)

        } catch {
            // Abort on failure
            try? await abortMultipartUpload(s3Key: s3Key, uploadId: uploadId)
            throw error
        }
    }

    /// Generate the public CDN URL for a file.
    func getPublicUrl(for s3Key: String) -> String {
        return "\(credentials.cdnBaseUrl)/\(s3Key)"
    }

    // MARK: - Image Validation

    /// Allowed image content types (matches backend)
    private static let allowedImageTypes: Set<String> = [
        "image/jpeg", "image/png", "image/webp", "image/gif"
    ]

    /// Maximum image size: 10MB (matches backend)
    private static let maxImageSize = 10 * 1024 * 1024

    /// Validate image data before upload.
    /// Returns nil if valid, or an error description if invalid.
    func validateImage(data: Data, contentType: String) -> String? {
        if data.count > Self.maxImageSize {
            return "Image exceeds 10MB limit (\(data.count / 1024 / 1024)MB)"
        }

        if !Self.allowedImageTypes.contains(contentType) && !contentType.hasPrefix("image/") {
            return "Invalid content type: \(contentType)"
        }

        return nil
    }

    /// Download and upload an image from a remote URL.
    /// Returns the Spaces URL on success, nil if image validation fails.
    func downloadAndUploadImage(_ imageUrl: String, s3Key: String) async throws -> String? {
        // Check if already uploaded
        if try await fileExists(s3Key) {
            return getPublicUrl(for: s3Key)
        }

        guard let url = URL(string: imageUrl) else {
            throw S3Error.invalidUrl
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw S3Error.downloadFailed
        }

        // Validate image
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"

        if let validationError = validateImage(data: data, contentType: contentType) {
            print("[S3Service] Skipping image upload: \(validationError)")
            return nil
        }

        return try await uploadData(data, s3Key: s3Key, contentType: contentType)
    }

    /// Upload embedded artwork data with validation.
    /// Returns the Spaces URL on success, nil if validation fails.
    func uploadArtworkData(_ data: Data, s3Key: String, contentType: String) async throws -> String? {
        // Check if already uploaded
        if try await fileExists(s3Key) {
            return getPublicUrl(for: s3Key)
        }

        if let validationError = validateImage(data: data, contentType: contentType) {
            print("[S3Service] Skipping artwork upload: \(validationError)")
            return nil
        }

        return try await uploadData(data, s3Key: s3Key, contentType: contentType)
    }

    // MARK: - Multipart Upload

    private func initiateMultipartUpload(s3Key: String, contentType: String) async throws -> String {
        let path = "/\(credentials.prefix)/\(s3Key)"
        var request = try signedRequest(
            method: "POST",
            path: path,
            queryItems: [URLQueryItem(name: "uploads", value: "")],
            contentType: contentType
        )
        request.setValue("public-read", forHTTPHeaderField: "x-amz-acl")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)

        // Parse upload ID from XML response
        let parser = S3InitiateMultipartParser()
        parser.parse(data)

        guard let uploadId = parser.uploadId else {
            throw S3Error.multipartInitFailed
        }

        return uploadId
    }

    private func uploadPart(s3Key: String, uploadId: String, partNumber: Int, data: Data) async throws -> String {
        let path = "/\(credentials.prefix)/\(s3Key)"
        let queryItems = [
            URLQueryItem(name: "partNumber", value: String(partNumber)),
            URLQueryItem(name: "uploadId", value: uploadId)
        ]

        let request = try signedRequest(
            method: "PUT",
            path: path,
            queryItems: queryItems,
            body: data
        )

        let (_, response) = try await session.upload(for: request, from: data)
        try validateResponse(response)

        guard let httpResponse = response as? HTTPURLResponse,
              let etag = httpResponse.value(forHTTPHeaderField: "ETag") else {
            throw S3Error.missingETag
        }

        return etag
    }

    private func completeMultipartUpload(s3Key: String, uploadId: String, parts: [(Int, String)]) async throws {
        let path = "/\(credentials.prefix)/\(s3Key)"
        let queryItems = [URLQueryItem(name: "uploadId", value: uploadId)]

        // Build XML body
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        xml += "<CompleteMultipartUpload>"
        for (partNumber, etag) in parts.sorted(by: { $0.0 < $1.0 }) {
            xml += "<Part>"
            xml += "<PartNumber>\(partNumber)</PartNumber>"
            xml += "<ETag>\(etag)</ETag>"
            xml += "</Part>"
        }
        xml += "</CompleteMultipartUpload>"

        let body = xml.data(using: .utf8)!

        let request = try signedRequest(
            method: "POST",
            path: path,
            queryItems: queryItems,
            contentType: "application/xml",
            body: body
        )

        let (_, response) = try await session.upload(for: request, from: body)
        try validateResponse(response)
    }

    private func abortMultipartUpload(s3Key: String, uploadId: String) async throws {
        let path = "/\(credentials.prefix)/\(s3Key)"
        let queryItems = [URLQueryItem(name: "uploadId", value: uploadId)]

        let request = try signedRequest(
            method: "DELETE",
            path: path,
            queryItems: queryItems
        )

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    // MARK: - AWS Signature V4

    private func signedRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem]? = nil,
        contentType: String? = nil,
        body: Data? = nil
    ) throws -> URLRequest {
        var components = URLComponents(string: credentials.endpoint)!
        components.path = path
        components.queryItems = queryItems

        guard let url = components.url else {
            throw S3Error.invalidUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = method

        let now = Date()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        let amzDate = amzDateString(now)
        let dateStamp = dateStampString(now)

        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(components.host, forHTTPHeaderField: "Host")

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let payloadHash = sha256Hex(body ?? Data())
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        // Build canonical request
        let canonicalUri = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let canonicalQueryString = queryItems?
            .sorted { $0.name < $1.name }
            .map { "\($0.name.urlEncoded)=\(($0.value ?? "").urlEncoded)" }
            .joined(separator: "&") ?? ""

        var signedHeaders = ["host", "x-amz-content-sha256", "x-amz-date"]
        var canonicalHeaders = "host:\(components.host!)\n"
        canonicalHeaders += "x-amz-content-sha256:\(payloadHash)\n"
        canonicalHeaders += "x-amz-date:\(amzDate)\n"

        if let contentType {
            signedHeaders.insert("content-type", at: 0)
            canonicalHeaders = "content-type:\(contentType)\n" + canonicalHeaders
        }

        let signedHeadersString = signedHeaders.joined(separator: ";")

        let canonicalRequest = [
            method,
            canonicalUri,
            canonicalQueryString,
            canonicalHeaders,
            signedHeadersString,
            payloadHash
        ].joined(separator: "\n")

        // Build string to sign
        let credentialScope = "\(dateStamp)/\(credentials.region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(canonicalRequest.data(using: .utf8)!)
        ].joined(separator: "\n")

        // Calculate signature
        let kDate = hmacSHA256(key: "AWS4\(credentials.secretKey)".data(using: .utf8)!, data: dateStamp.data(using: .utf8)!)
        let kRegion = hmacSHA256(key: kDate, data: credentials.region.data(using: .utf8)!)
        let kService = hmacSHA256(key: kRegion, data: "s3".data(using: .utf8)!)
        let kSigning = hmacSHA256(key: kService, data: "aws4_request".data(using: .utf8)!)
        let signature = hmacSHA256(key: kSigning, data: stringToSign.data(using: .utf8)!).hexString

        // Build authorization header
        let authorization = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(credentialScope), SignedHeaders=\(signedHeadersString), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        return request
    }

    private func validateResponse(_ response: URLResponse, data: Data? = nil) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw S3Error.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorMessage = "HTTP \(httpResponse.statusCode)"
            if let data, let body = String(data: data, encoding: .utf8) {
                errorMessage += ": \(body)"
            }
            throw S3Error.httpError(httpResponse.statusCode, errorMessage)
        }
    }

    // MARK: - Crypto Helpers

    private func sha256Hex(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        let key = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(signature)
    }

    private func amzDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func dateStampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

// MARK: - Helper Extensions

private extension Data {
    var hexString: String {
        compactMap { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .awsQueryAllowed) ?? self
    }
}

private extension CharacterSet {
    static let awsQueryAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}

// MARK: - XML Parsers

private class S3ListParser: NSObject, XMLParserDelegate {
    private let prefix: String
    var keys: [String] = []
    var nextContinuationToken: String?

    private var currentElement = ""
    private var currentValue = ""

    init(prefix: String) {
        self.prefix = prefix
    }

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentValue = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Key" {
            let key = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasPrefix(prefix) {
                let s3Key = String(key.dropFirst(prefix.count))
                if !s3Key.isEmpty {
                    keys.append(s3Key)
                }
            }
        } else if elementName == "NextContinuationToken" {
            nextContinuationToken = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private class S3InitiateMultipartParser: NSObject, XMLParserDelegate {
    var uploadId: String?

    private var currentElement = ""
    private var currentValue = ""

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentValue = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "UploadId" {
            uploadId = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - Errors

enum S3Error: LocalizedError {
    case invalidUrl
    case invalidResponse
    case uploadFailed
    case downloadFailed
    case invalidContentType
    case fileTooLarge
    case multipartInitFailed
    case missingETag
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidUrl:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .uploadFailed:
            return "Upload failed after multiple retries"
        case .downloadFailed:
            return "Failed to download file"
        case .invalidContentType:
            return "Invalid content type"
        case .fileTooLarge:
            return "File exceeds size limit"
        case .multipartInitFailed:
            return "Failed to initiate multipart upload"
        case .missingETag:
            return "Missing ETag in upload response"
        case .httpError(let code, let message):
            return "HTTP error \(code): \(message)"
        }
    }
}

// MARK: - Content Types

enum AudioContentType {
    static func forExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp3":
            return "audio/mpeg"
        case "m4a":
            return "audio/x-m4a"
        case "flac":
            return "audio/flac"
        case "wav":
            return "audio/wav"
        case "aac":
            return "audio/aac"
        default:
            return "application/octet-stream"
        }
    }
}

#else

// iOS stub - S3 operations are macOS only
actor S3Service {
    init(credentials: S3Credentials) {}

    func listAllFiles() async throws -> Set<String> { [] }
    func fileExists(_ s3Key: String) async throws -> Bool { false }
    func uploadData(_ data: Data, s3Key: String, contentType: String) async throws -> String { "" }
    func uploadFile(at fileURL: URL, s3Key: String, contentType: String, progress: ((Double) -> Void)?) async throws -> String { "" }
    func uploadLargeFile(at fileURL: URL, s3Key: String, contentType: String, progress: ((Double) -> Void)?) async throws -> String { "" }
    func getPublicUrl(for s3Key: String) -> String { "" }
    func validateImage(data: Data, contentType: String) -> String? { nil }
    func downloadAndUploadImage(_ imageUrl: String, s3Key: String) async throws -> String? { nil }
    func uploadArtworkData(_ data: Data, s3Key: String, contentType: String) async throws -> String? { nil }
}

#endif
