//
//  CatalogLoadingView.swift
//  Music
//
//  A polished loading view for catalog loading with retry support.
//

import SwiftUI

struct CatalogLoadingView: View {
    let musicService: MusicService

    @State private var isAnimating = false

    private var isError: Bool {
        musicService.loadingStage == .failed && musicService.error != nil
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Animated music note icon
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 120, height: 120)

                Image(systemName: isError ? "exclamationmark.triangle.fill" : "music.note")
                    .font(.system(size: 48))
                    .foregroundStyle(isError ? .orange : .secondary)
                    .scaleEffect(isAnimating && !isError ? 1.1 : 1.0)
                    .animation(
                        isError ? .none : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: isAnimating
                    )
            }

            VStack(spacing: 12) {
                if isError {
                    Text("Unable to Load Music")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(musicService.error?.localizedDescription ?? "An unknown error occurred")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    Text(musicService.loadingStage.rawValue)
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    ProgressView()
                        .controlSize(.regular)
                }

                // Retry attempt indicator
                if musicService.retryCount > 0 && !isError {
                    Text("Attempt \(musicService.retryCount + 1) of \(musicService.maxRetries + 1)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if isError {
                VStack(spacing: 16) {
                    Button {
                        Task {
                            musicService.resetError()
                            await musicService.loadCatalogWithRetry(forceRefresh: true)
                        }
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)

                    // Platform-specific help text
                    #if os(macOS)
                    Text("Check your internet connection and upload settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #else
                    Text("Check your internet connection or try again later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif
                }
                .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isAnimating = true
        }
    }
}

#Preview("Loading") {
    CatalogLoadingView(musicService: MusicService())
}
