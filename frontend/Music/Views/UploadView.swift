//
//  UploadView.swift
//  Music
//
//  macOS-only view for uploading music to DigitalOcean Spaces.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

#if os(macOS)

struct UploadView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var uploader = MusicUploader()
    @State private var selectedFolder: URL?
    @State private var showingFolderPicker = false
    @State private var showingSettings = false
    @State private var config = UploadConfiguration()
    @State private var fileImporterError: Error?

    // Preview state
    @State private var preview: UploadPreview?
    @State private var showingPreview = false
    @State private var isScanning = false
    @State private var scanError: Error?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Header
                Text("Upload Music")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                // Configuration status
                configurationSection

                Divider()

                // Folder selection
                folderSelectionSection

                // Progress section
                if uploader.isRunning {
                    progressSection
                }

                // Scan progress
                if isScanning {
                    scanProgressSection
                }

                // Error display
                if let error = uploader.error ?? fileImporterError ?? scanError {
                    errorSection(error)
                }

                Spacer()

                // Action buttons
                actionButtons
            }
            .padding(30)
            .frame(minWidth: 500, minHeight: 400)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                    .help("Configure upload settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                UploadSettingsView(config: $config)
            }
            .sheet(isPresented: $showingPreview) {
                if let preview = preview {
                    UploadPreviewSheet(
                        preview: preview,
                        onCancel: {
                            showingPreview = false
                        },
                        onStartUpload: {
                            startUploadFromPreview()
                        }
                    )
                }
            }
            .fileImporter(
                isPresented: $showingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        // Stop accessing previous folder's security-scoped resource
                        selectedFolder?.stopAccessingSecurityScopedResource()

                        // Start accessing new folder's security-scoped resource
                        if url.startAccessingSecurityScopedResource() {
                            selectedFolder = url
                        }
                    }
                case .failure(let error):
                    fileImporterError = error
                }
            }
            .onAppear {
                loadConfiguration()
            }
            .onDisappear {
                // Release security-scoped resource when view disappears
                selectedFolder?.stopAccessingSecurityScopedResource()
            }
        }
    }

    // MARK: - Sections

    private var configurationSection: some View {
        HStack {
            Image(systemName: config.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(config.isValid ? .green : .orange)

            Text(config.isValid ? "Configuration ready" : "Configure credentials to upload")
                .foregroundStyle(.secondary)

            if !config.isValid {
                Button("Configure") {
                    showingSettings = true
                }
                .buttonStyle(.link)
            }
        }
        .font(.callout)
    }

    private var folderSelectionSection: some View {
        VStack(spacing: 12) {
            Button {
                showingFolderPicker = true
            } label: {
                Label(
                    selectedFolder?.lastPathComponent ?? "Select Music Folder",
                    systemImage: "folder"
                )
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            if let folder = selectedFolder {
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var progressSection: some View {
        VStack(spacing: 12) {
            // Phase indicator
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text(uploader.progress.phase.rawValue)
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            ProgressView(value: uploader.progress.progress)
                .progressViewStyle(.linear)

            // Current file
            if let currentFile = uploader.progress.currentFile {
                Text(currentFile)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Stats
            HStack(spacing: 20) {
                StatView(label: "Processed", value: uploader.progress.processedFiles, color: .green)
                StatView(label: "Skipped", value: uploader.progress.skippedFiles, color: .blue)
                StatView(label: "Converted", value: uploader.progress.convertedFiles, color: .orange)
                StatView(label: "Failed", value: uploader.progress.failedFiles, color: .red)
            }
            .font(.caption)
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private func errorSection(_ error: Error) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(error.localizedDescription)
                .foregroundStyle(.red)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }

    private var scanProgressSection: some View {
        VStack(spacing: 12) {
            // Phase indicator
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text(uploader.progress.phase.rawValue)
                    .foregroundStyle(.secondary)
            }

            // Progress bar (during fetchingMetadata phase)
            if uploader.progress.phase == .fetchingMetadata && uploader.progress.totalFiles > 0 {
                ProgressView(value: uploader.progress.progress)
                    .progressViewStyle(.linear)

                // Current file
                if let currentFile = uploader.progress.currentFile {
                    Text(currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Stats
                Text("\(uploader.progress.processedFiles) of \(uploader.progress.totalFiles) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            if uploader.isRunning {
                Button("Cancel") {
                    uploader.cancel()
                }
                .buttonStyle(.bordered)
            } else if isScanning {
                Button("Cancel") {
                    isScanning = false
                }
                .buttonStyle(.bordered)
            } else {
                Button("Scan") {
                    startScan()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFolder == nil || !config.isValid)
            }
        }
    }

    // MARK: - Actions

    private func loadConfiguration() {
        if let saved = try? UploadConfiguration.loadFromKeychain() {
            config = saved
        }
        uploader.configure(config: config, modelContext: modelContext)
    }

    private func startScan() {
        guard let folder = selectedFolder else { return }
        uploader.configure(config: config, modelContext: modelContext)

        isScanning = true
        scanError = nil

        Task {
            do {
                let result = try await uploader.scanForPreview(from: folder)
                await MainActor.run {
                    preview = result
                    showingPreview = true
                    isScanning = false
                }
            } catch {
                await MainActor.run {
                    scanError = error
                    isScanning = false
                }
            }
        }
    }

    private func startUploadFromPreview() {
        guard let folder = selectedFolder, let preview = preview else { return }
        uploader.configure(config: config, modelContext: modelContext)
        uploader.startFromPreview(preview, folderURL: folder)
        showingPreview = false
    }
}

// MARK: - Upload Preview Sheet

struct UploadPreviewSheet: View {
    let preview: UploadPreview
    let onCancel: () -> Void
    let onStartUpload: () -> Void

    @State private var showSkippedFiles = false
    @State private var newFilesPage = 0
    @State private var skippedFilesPage = 0

    private let pageSize = 50

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Upload Preview")
                    .font(.headline)
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // New files section
                    newFilesSection

                    // Skipped files section (collapsible)
                    if !preview.skippedFiles.isEmpty {
                        skippedFilesSection
                    }
                }
                .padding()
            }

            Divider()

            // Footer buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Start Upload") {
                    onStartUpload()
                }
                .buttonStyle(.borderedProminent)
                .disabled(preview.newFiles.isEmpty)
            }
            .padding()
        }
        .frame(width: 700, height: 500)
    }

    private var newFilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Text("New Files (\(preview.newFiles.count))")
                    .font(.subheadline.weight(.semibold))
            }

            if preview.newFiles.isEmpty {
                Text("No new files to upload")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.vertical, 8)
            } else {
                previewTable(items: preview.newFiles, page: $newFilesPage)
            }
        }
    }

    private var skippedFilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation {
                    showSkippedFiles.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Already Uploaded (\(preview.skippedFiles.count))")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: showSkippedFiles ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showSkippedFiles {
                previewTable(items: preview.skippedFiles, page: $skippedFilesPage)
            }
        }
    }

    private func previewTable(items: [UploadPreviewItem], page: Binding<Int>) -> some View {
        let totalPages = max(1, (items.count + pageSize - 1) / pageSize)
        let startIndex = page.wrappedValue * pageSize
        let endIndex = min(startIndex + pageSize, items.count)
        let pageItems = startIndex < items.count ? Array(items[startIndex..<endIndex]) : []

        return VStack(spacing: 0) {
            // Header row
            HStack {
                Text("Artist")
                    .frame(width: 120, alignment: .leading)
                Text("Album")
                    .frame(width: 140, alignment: .leading)
                Text("Title")
                    .frame(width: 160, alignment: .leading)
                Text("S3 Path")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))

            // Data rows (lazy for performance with large datasets)
            LazyVStack(spacing: 0) {
            ForEach(pageItems) { item in
                HStack {
                    Text(item.artist)
                        .frame(width: 120, alignment: .leading)
                        .lineLimit(1)
                    Text(item.album)
                        .frame(width: 140, alignment: .leading)
                        .lineLimit(1)
                    Text(item.title)
                        .frame(width: 160, alignment: .leading)
                        .lineLimit(1)
                    Text(item.s3Key)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Divider()
            }
            }

            // Pagination controls
            if totalPages > 1 {
                HStack {
                    Button {
                        if page.wrappedValue > 0 {
                            page.wrappedValue -= 1
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(page.wrappedValue == 0)
                    .buttonStyle(.plain)

                    Spacer()

                    Text("Page \(page.wrappedValue + 1) of \(totalPages)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("(\(startIndex + 1)-\(endIndex) of \(items.count))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Button {
                        if page.wrappedValue < totalPages - 1 {
                            page.wrappedValue += 1
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(page.wrappedValue >= totalPages - 1)
                    .buttonStyle(.plain)
                }
                .padding(8)
            }
        }
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }
}

// MARK: - Stat View

private struct StatView: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Upload Settings View

struct UploadSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var config: UploadConfiguration

    @State private var spacesKey = ""
    @State private var spacesSecret = ""
    @State private var spacesBucket = ""
    @State private var spacesRegion = UploadConfiguration.defaultRegion
    @State private var spacesPrefix = UploadConfiguration.defaultPrefix
    @State private var lastFMApiKey = ""
    @State private var musicBrainzContact = ""
    @State private var showingSecret = false
    @State private var error: Error?
    @State private var isTesting = false
    @State private var testResult: TestResult?

    enum TestResult {
        case success(fileCount: Int)
        case failure(String)
    }

    private var canTest: Bool {
        !spacesKey.isEmpty && !spacesSecret.isEmpty && !spacesBucket.isEmpty && !spacesRegion.isEmpty
    }

    var body: some View {
        Form {
            Section("DigitalOcean Spaces") {
                TextField("Access Key", text: $spacesKey)
                    .textContentType(.none)

                HStack {
                    if showingSecret {
                        TextField("Secret Key", text: $spacesSecret)
                    } else {
                        SecureField("Secret Key", text: $spacesSecret)
                    }
                    Button {
                        showingSecret.toggle()
                    } label: {
                        Image(systemName: showingSecret ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                }

                TextField("Bucket Name", text: $spacesBucket)
                TextField("Region", text: $spacesRegion)
                    .help("e.g., sfo3, nyc3, ams3")
                TextField("Prefix", text: $spacesPrefix)
                    .help("S3 path prefix (default: music)")

                // Test Connection Button
                HStack {
                    Button {
                        testConnection()
                    } label: {
                        HStack(spacing: 6) {
                            if isTesting {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "network")
                            }
                            Text(isTesting ? "Testing..." : "Test Connection")
                        }
                    }
                    .disabled(!canTest || isTesting)

                    Spacer()

                    // Test Result
                    if let result = testResult {
                        switch result {
                        case .success(let count):
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Connected (\(count) files)")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        case .failure(let message):
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text(message)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            }
                            .font(.callout)
                        }
                    }
                }
            }

            Section("Metadata Services (Optional)") {
                TextField("Last.fm API Key", text: $lastFMApiKey)
                    .help("For album artwork and wiki fallback")
                TextField("MusicBrainz Contact Email", text: $musicBrainzContact)
                    .help("Required for MusicBrainz API access")
            }

            if let error = error {
                Section {
                    Text(error.localizedDescription)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 400)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveConfiguration()
                }
                .disabled(spacesKey.isEmpty || spacesSecret.isEmpty || spacesBucket.isEmpty)
            }
        }
        .onAppear {
            loadFields()
        }
    }

    private func loadFields() {
        spacesKey = config.spacesKey
        spacesSecret = config.spacesSecret
        spacesBucket = config.spacesBucket
        spacesRegion = config.spacesRegion
        spacesPrefix = config.spacesPrefix
        lastFMApiKey = config.lastFMApiKey
        musicBrainzContact = config.musicBrainzContact
    }

    private func saveConfiguration() {
        config = UploadConfiguration(
            spacesKey: spacesKey,
            spacesSecret: spacesSecret,
            spacesBucket: spacesBucket,
            spacesRegion: spacesRegion,
            spacesPrefix: spacesPrefix,
            lastFMApiKey: lastFMApiKey,
            musicBrainzContact: musicBrainzContact
        )

        do {
            try config.saveToKeychain()
            dismiss()
        } catch {
            self.error = error
        }
    }

    private func testConnection() {
        guard canTest else { return }

        isTesting = true
        testResult = nil

        let testConfig = UploadConfiguration(
            spacesKey: spacesKey,
            spacesSecret: spacesSecret,
            spacesBucket: spacesBucket,
            spacesRegion: spacesRegion,
            spacesPrefix: spacesPrefix
        )

        Task {
            do {
                let storage = StorageService(config: testConfig)
                let files = try await storage.listAllFiles()
                await MainActor.run {
                    testResult = .success(fileCount: files.count)
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    // Extract meaningful error message
                    let message: String
                    if let storageError = error as? StorageError {
                        switch storageError {
                        case .httpError(let code, let detail):
                            if code == 403 {
                                message = "Access denied - check credentials"
                            } else if code == 404 {
                                message = "Bucket not found"
                            } else {
                                message = "HTTP \(code)"
                            }
                        default:
                            message = storageError.localizedDescription
                        }
                    } else {
                        message = error.localizedDescription
                    }
                    testResult = .failure(message)
                    isTesting = false
                }
            }
        }
    }
}

#Preview {
    UploadView()
        .modelContainer(for: [CatalogArtist.self, CatalogAlbum.self, CatalogTrack.self, CatalogMetadata.self], inMemory: true)
}

#endif
