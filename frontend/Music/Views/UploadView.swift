//
//  UploadView.swift
//  Music
//
//  macOS view for uploading local music folders to S3.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

#if os(macOS)

struct UploadView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var uploadService = UploadService()
    @State private var keychainService = KeychainService()
    @State private var scannerService = RemoteScannerService()

    @AppStorage("lastUploadFolderBookmark") private var lastUploadFolderBookmark: Data = Data()
    @State private var selectedFolder: URL?
    @State private var isAccessingSecurityScope = false
    @State private var isDragging = false
    @State private var showingFolderPicker = false
    @State private var showingSettings = false
    @State private var showingScanResults = false
    @State private var lastImportCount: Int?
    @State private var isTestingConnection = false
    @State private var connectionTestMessage: String?
    @State private var scanCompletedMessage: String?
    @State private var showingUploadPreview = false
    @State private var forceReupload = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Upload Music")
                    .font(.title2.bold())

                Spacer()

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                .help("S3 Settings")
            }
            .padding()

            Divider()

            if !keychainService.hasCredentials {
                // No credentials configured
                noCredentialsView
            } else if uploadService.isUploading {
                // Upload in progress
                uploadProgressView
            } else if uploadService.isPreparing {
                // Preparing upload (comparing to remote)
                preparingUploadView
            } else if showingUploadPreview, let preparation = uploadService.preparationResult {
                // Show upload preview
                uploadPreviewView(preparation)
            } else if scannerService.isScanning {
                // Remote scan in progress
                remoteScanProgressView
            } else if scannerService.isImporting {
                // Import in progress
                importProgressView
            } else if showingScanResults && !scannerService.discoveredFiles.isEmpty {
                // Show scan results
                scanResultsView
            } else {
                // Ready to upload
                folderSelectionView
            }

            Spacer()

            // Results
            if let result = uploadService.lastResult {
                resultView(result)
            }

            // Import results
            if let count = lastImportCount {
                importResultView(count)
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .sheet(isPresented: $showingSettings) {
            S3SettingsView(keychainService: keychainService)
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                // Stop previous access if any
                if isAccessingSecurityScope, let oldUrl = selectedFolder {
                    oldUrl.stopAccessingSecurityScopedResource()
                }

                selectedFolder = url
                isAccessingSecurityScope = url.startAccessingSecurityScopedResource()
                print("[UploadView] Selected folder: \(url.path), access: \(isAccessingSecurityScope)")

                // Save bookmark for persistence
                if let bookmark = createBookmark(for: url) {
                    lastUploadFolderBookmark = bookmark
                }
            }
        }
        .onAppear {
            uploadService.configure(modelContext: modelContext)
            scannerService.configure(modelContext: modelContext)

            // Restore last folder from bookmark
            if !lastUploadFolderBookmark.isEmpty && selectedFolder == nil {
                if let url = resolveBookmark(lastUploadFolderBookmark) {
                    selectedFolder = url
                    isAccessingSecurityScope = url.startAccessingSecurityScopedResource()
                    print("[UploadView] Restored folder from bookmark: \(url.path), access: \(isAccessingSecurityScope)")
                }
            }
        }
        .onDisappear {
            // Stop accessing security-scoped resource
            if isAccessingSecurityScope, let url = selectedFolder {
                url.stopAccessingSecurityScopedResource()
                isAccessingSecurityScope = false
            }
        }
    }

    // MARK: - No Credentials View

    private var noCredentialsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("S3 Credentials Required")
                .font(.headline)

            Text("Configure your DigitalOcean Spaces credentials to start uploading music.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Configure Credentials") {
                showingSettings = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Folder Selection View

    private var folderSelectionView: some View {
        VStack(spacing: 20) {
            // Drop zone
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [8])
                    )
                    .foregroundStyle(isDragging ? .blue : .secondary.opacity(0.5))
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isDragging ? Color.blue.opacity(0.1) : Color.clear)
                    )

                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    if let folder = selectedFolder {
                        VStack(spacing: 4) {
                            Text(folder.lastPathComponent)
                                .font(.headline)
                            Text(folder.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text("Drop a folder here or click to browse")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 180)
            .padding(.horizontal)
            .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
                handleDrop(providers)
            }
            .onTapGesture {
                showingFolderPicker = true
            }

            // Action buttons
            HStack {
                if selectedFolder != nil {
                    Button("Clear") {
                        if isAccessingSecurityScope, let url = selectedFolder {
                            url.stopAccessingSecurityScopedResource()
                            isAccessingSecurityScope = false
                        }
                        selectedFolder = nil
                        lastUploadFolderBookmark = Data()
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()

                Button {
                    testConnection()
                } label: {
                    if isTestingConnection {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Label("Test Connection", systemImage: "wifi")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isTestingConnection)
                .help("Test S3 bucket connection")

                Button {
                    startRemoteScan()
                } label: {
                    Label("Scan Remote", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.bordered)
                .help("Scan S3 bucket for existing files not in library")

                Spacer()

                Toggle("Re-upload existing", isOn: $forceReupload)
                    .toggleStyle(.checkbox)
                    .help("When enabled, files are uploaded even if they already exist in S3")

                Button {
                    startPrepareUpload()
                } label: {
                    Label("Prepare Upload", systemImage: "doc.badge.gearshape")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFolder == nil)
            }
            .padding(.horizontal)

            // Connection test result
            if let message = connectionTestMessage {
                HStack {
                    Image(systemName: message.contains("successfully") ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(message.contains("successfully") ? .green : .red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message.contains("successfully") ? .green : .red)
                    Button("Dismiss") {
                        connectionTestMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            // Scan completed message
            if let message = scanCompletedMessage {
                HStack {
                    Image(systemName: message.contains("failed") ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(message.contains("failed") ? .red : .green)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message.contains("failed") ? .red : .secondary)
                    Button("Dismiss") {
                        scanCompletedMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
        }
        .padding(.vertical)
    }

    // MARK: - Upload Progress View

    private var uploadProgressView: some View {
        VStack(spacing: 20) {
            // Phase indicator
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text(uploadService.progress.currentPhase.rawValue)
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: uploadService.progress.progress)
                    .progressViewStyle(.linear)

                HStack {
                    Text("\(uploadService.progress.completedFiles) / \(uploadService.progress.totalFiles) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(Int(uploadService.progress.progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            // Current file
            if !uploadService.progress.currentFile.isEmpty {
                Text(uploadService.progress.currentFile)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Cancel button
            Button("Cancel") {
                uploadService.cancel()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Result View

    private func resultView(_ result: UploadResult) -> some View {
        VStack(spacing: 8) {
            Divider()

            HStack(spacing: 24) {
                Label("\(result.uploaded) uploaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Label("\(result.skipped) skipped", systemImage: "minus.circle.fill")
                    .foregroundStyle(.secondary)

                if result.failed > 0 {
                    Label("\(result.failed) failed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .padding(.vertical, 8)

            if !result.errors.isEmpty {
                DisclosureGroup("Errors (\(result.errors.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(result.errors, id: \.self) { error in
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .frame(maxHeight: 100)
                }
                .font(.caption)
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Import Result View

    private func importResultView(_ count: Int) -> some View {
        VStack(spacing: 8) {
            Divider()

            HStack(spacing: 24) {
                Label("\(count) imported from remote", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Button("Dismiss") {
                    lastImportCount = nil
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Remote Scan Progress View

    private var remoteScanProgressView: some View {
        VStack(spacing: 20) {
            // Phase indicator
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Scanning remote storage...")
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: scannerService.progress)
                    .progressViewStyle(.linear)

                HStack {
                    Text("Checking for files not in library")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(Int(scannerService.progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            // Error display
            if let error = scannerService.error {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
    }

    // MARK: - Import Progress View

    private var importProgressView: some View {
        VStack(spacing: 20) {
            // Phase indicator
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Importing files...")
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: scannerService.importProgress)
                    .progressViewStyle(.linear)

                HStack {
                    Text("\(scannerService.importedCount) / \(scannerService.discoveredFiles.count + scannerService.importedCount) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(Int(scannerService.importProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            // Current file
            if !scannerService.currentImportFile.isEmpty {
                Text(scannerService.currentImportFile)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding()
    }

    // MARK: - Preparing Upload View

    private var preparingUploadView: some View {
        VStack(spacing: 20) {
            // Phase indicator
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text(uploadService.preparationStatus.isEmpty ? "Preparing..." : uploadService.preparationStatus)
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: uploadService.preparationProgress)
                    .progressViewStyle(.linear)

                HStack {
                    Text(uploadService.preparationStatus.isEmpty ? "Scanning..." : uploadService.preparationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Text("\(Int(uploadService.preparationProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
        }
        .padding()
    }

    // MARK: - Upload Preview View

    private func uploadPreviewView(_ preparation: UploadPreparation) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.badge.gearshape.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Ready to Upload")
                .font(.headline)

            Text("Found \(preparation.totalLocalFiles) audio files in \"\(preparation.folderURL.lastPathComponent)\"")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Summary
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.green)
                    Text("\(preparation.filesToUpload.count) files to upload")
                    Spacer()
                }

                HStack {
                    Image(systemName: "forward.fill")
                        .foregroundStyle(.secondary)
                    Text("\(preparation.filesToSkip.count) files already exist (will skip)")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.1)))
            .padding(.horizontal)

            // Buttons
            HStack(spacing: 16) {
                Button("Cancel") {
                    showingUploadPreview = false
                    uploadService.clearPreparation()
                }
                .buttonStyle(.bordered)

                Button {
                    startUploadFromPreparation()
                } label: {
                    Label("Upload \(preparation.filesToUpload.count) Files", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(preparation.filesToUpload.isEmpty)
            }

            // File previews
            if !preparation.filesToUpload.isEmpty {
                DisclosureGroup("Files to upload (\(preparation.filesToUpload.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(preparation.filesToUpload.prefix(50), id: \.self) { url in
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if preparation.filesToUpload.count > 50 {
                                Text("... and \(preparation.filesToUpload.count - 50) more")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .italic()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .font(.caption)
                .padding(.horizontal)
            }

            if !preparation.filesToSkip.isEmpty {
                DisclosureGroup("Files to skip (\(preparation.filesToSkip.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(preparation.filesToSkip.prefix(50), id: \.self) { url in
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if preparation.filesToSkip.count > 50 {
                                Text("... and \(preparation.filesToSkip.count - 50) more")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .italic()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .font(.caption)
                .padding(.horizontal)
            }
        }
        .padding()
    }

    // MARK: - Scan Results View

    private var scanResultsView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Found \(scannerService.discoveredFiles.count) files")
                .font(.headline)

            Text("These files exist in your S3 bucket but are not in your library.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 16) {
                Button("Cancel") {
                    showingScanResults = false
                }
                .buttonStyle(.bordered)

                Button {
                    importDiscoveredFiles()
                } label: {
                    Label("Import All", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }

            // Show file list preview
            if !scannerService.discoveredFiles.isEmpty {
                DisclosureGroup("Preview files (\(scannerService.discoveredFiles.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(scannerService.discoveredFiles.prefix(50), id: \.self) { key in
                                Text(key)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if scannerService.discoveredFiles.count > 50 {
                                Text("... and \(scannerService.discoveredFiles.count - 50) more")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .italic()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
                .font(.caption)
                .padding(.horizontal)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.hasDirectoryPath else {
                return
            }

            DispatchQueue.main.async {
                // Stop previous access if any
                if isAccessingSecurityScope, let oldUrl = selectedFolder {
                    oldUrl.stopAccessingSecurityScopedResource()
                }

                selectedFolder = url
                isAccessingSecurityScope = url.startAccessingSecurityScopedResource()

                // Save bookmark for persistence
                if let bookmark = createBookmark(for: url) {
                    lastUploadFolderBookmark = bookmark
                }
            }
        }

        return true
    }

    private func startUpload() {
        guard let folder = selectedFolder else { return }

        Task {
            await uploadService.uploadFolder(
                folder,
                credentials: keychainService.credentials,
                lastFMApiKey: keychainService.credentials.lastFMApiKey,
                forceReupload: forceReupload
            )
        }
    }

    private func startPrepareUpload() {
        guard let folder = selectedFolder else { return }
        showingUploadPreview = false
        connectionTestMessage = nil
        scanCompletedMessage = nil

        Task {
            await uploadService.prepareUpload(folder, credentials: keychainService.credentials, forceReupload: forceReupload)
            if uploadService.preparationResult != nil {
                showingUploadPreview = true
            }
        }
    }

    private func startUploadFromPreparation() {
        guard let preparation = uploadService.preparationResult else { return }
        showingUploadPreview = false

        Task {
            await uploadService.uploadFolder(
                preparation.folderURL,
                credentials: keychainService.credentials,
                lastFMApiKey: keychainService.credentials.lastFMApiKey,
                forceReupload: forceReupload
            )
            uploadService.clearPreparation()
        }
    }

    private func startRemoteScan() {
        print("[UploadView] startRemoteScan() called")
        lastImportCount = nil
        showingScanResults = false
        connectionTestMessage = nil
        scanCompletedMessage = nil

        let creds = keychainService.credentials
        print("[UploadView] Credentials - bucket: \(creds.bucket), region: \(creds.region), prefix: \(creds.prefix)")
        print("[UploadView] Access key empty: \(creds.accessKey.isEmpty), Secret key empty: \(creds.secretKey.isEmpty)")

        Task {
            print("[UploadView] Starting scanRemote Task...")
            let discovered = await scannerService.scanRemote(credentials: creds)
            print("[UploadView] scanRemote completed, discovered: \(discovered.count) files")
            if !discovered.isEmpty {
                showingScanResults = true
                print("[UploadView] Showing scan results")
            } else if let error = scannerService.error {
                print("[UploadView] Scanner error: \(error.localizedDescription)")
                scanCompletedMessage = "Scan failed: \(error.localizedDescription)"
            } else {
                print("[UploadView] No files discovered, showing message")
                scanCompletedMessage = "Scan complete. All remote files are already in your library."
            }
        }
    }

    private func testConnection() {
        print("[UploadView] testConnection() called")
        isTestingConnection = true
        connectionTestMessage = nil

        let creds = keychainService.credentials
        print("[UploadView] Testing with bucket: \(creds.bucket), region: \(creds.region)")

        Task {
            let result = await scannerService.testConnection(credentials: creds)
            isTestingConnection = false
            connectionTestMessage = result.message
            print("[UploadView] Connection test result: \(result.success) - \(result.message)")
        }
    }

    private func importDiscoveredFiles() {
        showingScanResults = false
        Task {
            let count = await scannerService.importDiscoveredFiles(
                credentials: keychainService.credentials,
                lastFMApiKey: keychainService.credentials.lastFMApiKey
            )
            lastImportCount = count
        }
    }

    // MARK: - Bookmark Helpers

    /// Create a security-scoped bookmark for a URL.
    private func createBookmark(for url: URL) -> Data? {
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            print("[UploadView] Created bookmark for: \(url.path)")
            return bookmark
        } catch {
            print("[UploadView] Failed to create bookmark: \(error.localizedDescription)")
            return nil
        }
    }

    /// Resolve a security-scoped bookmark to a URL.
    private func resolveBookmark(_ bookmark: Data) -> URL? {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                print("[UploadView] Bookmark is stale, may need to re-create")
                // Optionally re-create the bookmark here
            }

            print("[UploadView] Resolved bookmark to: \(url.path)")
            return url
        } catch {
            print("[UploadView] Failed to resolve bookmark: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - S3 Settings View

struct S3SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let keychainService: KeychainService

    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var bucket = ""
    @State private var region = "sfo3"
    @State private var prefix = "music"
    @State private var lastFMApiKey = ""
    @State private var isSaving = false
    @State private var error: String?

    private let regions = ["sfo3", "nyc3", "ams3", "sgp1", "fra1"]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("S3 Settings")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            Form {
                Section("DigitalOcean Spaces Credentials") {
                    TextField("Access Key", text: $accessKey)
                        .textContentType(.username)

                    SecureField("Secret Key", text: $secretKey)
                        .textContentType(.password)

                    TextField("Bucket Name", text: $bucket)

                    Picker("Region", selection: $region) {
                        ForEach(regions, id: \.self) { region in
                            Text(region).tag(region)
                        }
                    }

                    TextField("Path Prefix", text: $prefix)
                        .help("S3 path prefix (e.g., 'music')")
                }

                Section("API Keys (Optional)") {
                    SecureField("Last.fm API Key", text: $lastFMApiKey)
                        .help("Used as fallback for album artwork and wiki")
                }

                Section {
                    HStack {
                        Button("Save Credentials") {
                            saveCredentials()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isValid || isSaving)

                        if keychainService.hasCredentials {
                            Button("Clear Credentials", role: .destructive) {
                                clearCredentials()
                            }
                        }
                    }

                    if let error {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 450, height: 450)
        .onAppear {
            loadCredentials()
        }
    }

    private var isValid: Bool {
        !accessKey.isEmpty && !secretKey.isEmpty && !bucket.isEmpty && !region.isEmpty
    }

    private func loadCredentials() {
        let creds = keychainService.credentials
        accessKey = creds.accessKey
        secretKey = creds.secretKey
        bucket = creds.bucket
        region = creds.region
        prefix = creds.prefix
        lastFMApiKey = creds.lastFMApiKey
    }

    private func saveCredentials() {
        isSaving = true
        error = nil

        let credentials = S3Credentials(
            accessKey: accessKey,
            secretKey: secretKey,
            bucket: bucket,
            region: region,
            prefix: prefix,
            lastFMApiKey: lastFMApiKey
        )

        do {
            try keychainService.saveCredentials(credentials)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }

        isSaving = false
    }

    private func clearCredentials() {
        try? keychainService.deleteCredentials()
        accessKey = ""
        secretKey = ""
        bucket = ""
        region = "sfo3"
        prefix = "music"
        lastFMApiKey = ""
    }
}

#Preview {
    UploadView()
        .modelContainer(for: [UploadedTrack.self, UploadedArtist.self, UploadedAlbum.self], inMemory: true)
}

#endif
