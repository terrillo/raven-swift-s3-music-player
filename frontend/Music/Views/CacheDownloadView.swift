//
//  CacheDownloadView.swift
//  Music

import SwiftUI

struct CacheDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    var cacheService: CacheService
    var tracks: [Track]
    var artworkUrls: [String]
    var catalog: MusicCatalog?

    @State private var hasStarted = false

    private var uncachedTracks: [Track] {
        tracks.filter { !cacheService.isTrackCached($0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                    if !hasStarted {
                        // Start Download button
                        if uncachedTracks.isEmpty {
                            Text("All songs are cached")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        } else {
                            Button {
                                hasStarted = true
                                Task {
                                    await cacheService.cacheAllMusic(tracks: uncachedTracks, artworkUrls: artworkUrls, catalog: catalog)
                                }
                            } label: {
                                Label("Download \(uncachedTracks.count) Songs", systemImage: "arrow.down.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.appAccent)
                            .controlSize(.large)
                        }
                    } else {
                        // Progress header
                        HStack {
                            Text(cacheService.isDownloading ? "Downloading..." : "Download Complete")
                                .font(.headline)
                            Spacer()
                            Text("\(cacheService.completedFiles) / \(cacheService.totalFiles)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        ProgressView(value: cacheService.currentProgress)
                            .tint(.appAccent)
                    }
                }
                .padding()

                Divider()

                // Track list
                if uncachedTracks.isEmpty && !hasStarted {
                    ContentUnavailableView(
                        "All Cached",
                        systemImage: "checkmark.circle",
                        description: Text("All songs are already downloaded")
                    )
                } else {
                    List {
                        ForEach(hasStarted ? uncachedTracks : uncachedTracks) { track in
                            TrackDownloadRow(
                                track: track,
                                status: cacheService.trackDownloadStatus[track.s3Key] ?? .pending
                            )
                        }
                    }
                    .listStyle(.plain)
                }

                // Bottom button
                if hasStarted {
                    VStack(spacing: 12) {
                        if cacheService.isDownloading {
                            Button {
                                cacheService.cancelDownload()
                            } label: {
                                Text("Cancel")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        } else {
                            Button {
                                dismiss()
                            } label: {
                                Text("Done")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.appAccent)
                            .controlSize(.large)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Download Music")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if cacheService.isDownloading {
                            cacheService.cancelDownload()
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

struct TrackDownloadRow: View {
    let track: Track
    let status: DownloadStatus

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            statusIcon
                .frame(width: 24, height: 24)

            // Track info
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)

                if let artist = track.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Progress bar for downloading state
                if case .downloading(let progress) = status {
                    ProgressView(value: progress)
                        .tint(.appAccent)
                }
            }

            Spacer()

            // Duration or status text
            statusText
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .downloading:
            ProgressView()
                .scaleEffect(0.8)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .cached:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.appAccent)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch status {
        case .pending:
            Text("Waiting")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading(let progress):
            Text("\(Int(progress * 100))%")
                .font(.caption)
                .foregroundStyle(Color.appAccent)
                .monospacedDigit()
        case .completed:
            Text("Done")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let error):
            Text("Failed")
                .font(.caption)
                .foregroundStyle(.red)
                .help(error)
        case .cached:
            Text("Cached")
                .font(.caption)
                .foregroundStyle(Color.appAccent)
        }
    }
}
