//
//  ArtistsView.swift
//  Music
//

import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif

/// In-memory LRU cache for loaded artwork images to avoid repeated disk reads
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, PlatformImage>()
    private init() {
        // Limit cache to ~100MB on iOS, ~200MB on macOS
        #if os(iOS)
        cache.totalCostLimit = 100 * 1024 * 1024
        cache.countLimit = 200
        #else
        cache.totalCostLimit = 200 * 1024 * 1024
        cache.countLimit = 500
        #endif
    }

    func image(forKey key: String) -> PlatformImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: PlatformImage, forKey key: String) {
        // Estimate memory cost based on image dimensions
        #if os(iOS)
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        #else
        let cost = Int(image.size.width * image.size.height * 4)
        #endif
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeImage(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }
}

struct ArtworkImage: View {
    let url: String?
    let size: CGFloat
    let systemImage: String
    var localURL: URL? = nil
    var cacheService: CacheService? = nil
    var isCircular: Bool = false
    var accessibilityDescription: String? = nil

    @AppStorage("autoImageCachingEnabled") private var autoImageCachingEnabled = true
    @State private var cachedLocalURL: URL? = nil
    @State private var hasTriggeredDownload = false
    @State private var loadedImage: PlatformImage? = nil
    @State private var isLoading = false

    private var clipShape: AnyShape {
        isCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8))
    }

    private var effectiveURL: URL? {
        localURL ?? cachedLocalURL
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                imageView(for: image)
                    .transition(.opacity)
            } else if isLoading {
                ProgressView()
                    .frame(width: size, height: size)
            } else if let urlString = url, cacheService != nil {
                placeholderView
                    .onAppear {
                        triggerCacheDownload(urlString: urlString)
                    }
            } else if let urlString = url, let imageUrl = URL(string: urlString) {
                AsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: size, height: size)
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipShape(clipShape)
                    case .failure:
                        placeholderView
                    @unknown default:
                        placeholderView
                    }
                }
            } else {
                placeholderView
            }
        }
        .task(id: url) {
            await loadImageAsync()
        }
        .onChange(of: url) { _, _ in
            cachedLocalURL = nil
            loadedImage = nil
            hasTriggeredDownload = false
        }
        .animation(.easeInOut(duration: 0.2), value: loadedImage != nil)
        .accessibilityLabel(accessibilityDescription ?? "Artwork")
    }

    private func loadImageAsync() async {
        guard let urlString = url else {
            await MainActor.run { loadedImage = nil }
            return
        }

        // Fast path: check in-memory image cache first
        if let cachedImage = ImageCache.shared.image(forKey: urlString) {
            await MainActor.run {
                loadedImage = cachedImage
                isLoading = false
            }
            return
        }

        // Compute effective URL fresh (prefer localURL, then check cache with fast lookup)
        let urlToLoad: URL?
        if let local = localURL {
            urlToLoad = local
        } else if let cacheService = cacheService,
                  let cached = cacheService.localArtworkURLFast(for: urlString) {
            await MainActor.run { cachedLocalURL = cached }
            urlToLoad = cached
        } else {
            urlToLoad = nil
        }

        guard let loadURL = urlToLoad else {
            await MainActor.run {
                loadedImage = nil
                // Reset download trigger so we can retry downloading missing files
                hasTriggeredDownload = false
            }
            return
        }

        await MainActor.run { isLoading = true }

        let image = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: loadURL) else { return nil as PlatformImage? }
            #if os(iOS)
            return UIImage(data: data)
            #else
            return NSImage(data: data)
            #endif
        }.value

        await MainActor.run {
            if let image = image {
                // Cache in memory for fast subsequent access
                ImageCache.shared.setImage(image, forKey: urlString)
            }
            loadedImage = image
            isLoading = false
            // If file exists but couldn't load (corrupted), allow re-download
            if image == nil {
                hasTriggeredDownload = false
            }
        }
    }

    #if os(iOS)
    private func imageView(for image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(clipShape)
    }
    #else
    private func imageView(for image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(clipShape)
    }
    #endif

    private func triggerCacheDownload(urlString: String) {
        guard !hasTriggeredDownload,
              let cacheService = cacheService,
              autoImageCachingEnabled else { return }
        hasTriggeredDownload = true

        cacheService.cacheArtworkIfNeeded(urlString) { localURL in
            guard let localURL = localURL else { return }

            // Load image immediately on background thread, then update UI
            Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: localURL) else { return }
                #if os(iOS)
                guard let image = UIImage(data: data) else { return }
                #else
                guard let image = NSImage(data: data) else { return }
                #endif

                // Cache in memory
                ImageCache.shared.setImage(image, forKey: urlString)

                await MainActor.run {
                    cachedLocalURL = localURL
                    loadedImage = image
                    isLoading = false
                }
            }
        }
    }

    private var placeholderView: some View {
        Image(systemName: systemImage)
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Color.secondary.opacity(0.1))
            .clipShape(clipShape)
            .shadow(radius: 20)
    }
}

struct ArtistGridCard: View {
    let artist: Artist
    var localArtworkURL: URL?
    var cacheService: CacheService?

    private var songCount: Int {
        artist.albums.reduce(0) { $0 + $1.tracks.count }
    }

    private var isFavorite: Bool {
        FavoritesStore.shared.isArtistFavorite(artist.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ArtworkImage(
                    url: artist.imageUrl,
                    size: 160,
                    systemImage: "music.mic",
                    localURL: localArtworkURL,
                    cacheService: cacheService,
                    isCircular: false
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)

                if isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name)
                    .font(.headline)
                    .lineLimit(1)

                Text("\(songCount) \(songCount == 1 ? "song" : "songs")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        #if os(iOS)
        .background(Color(.systemGray6))
        #else
        .background(Color.secondary.opacity(0.1))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct AlbumGridCard: View {
    let album: Album
    var artistName: String?
    var localArtworkURL: URL?
    var cacheService: CacheService?

    private var isFavorite: Bool {
        FavoritesStore.shared.isAlbumFavorite(album.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ArtworkImage(
                    url: album.imageUrl,
                    size: 160,
                    systemImage: "square.stack",
                    localURL: localArtworkURL,
                    cacheService: cacheService
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)

                if isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(album.name)
                    .font(.headline)
                    .lineLimit(1)

                if let artist = artistName ?? album.tracks.first?.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    Text("\(album.tracks.count) songs")
                    if let releaseDate = album.releaseDate {
                        Text("·")
                        Text(String(releaseDate))
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                if let genre = album.genre {
                    Text(genre)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        #if os(iOS)
        .background(Color(.systemGray6))
        #else
        .background(Color.secondary.opacity(0.1))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ArtistsView: View {
    @Binding var showingSearch: Bool
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?
    @Binding var pendingNavigation: NavigationDestination?

    @AppStorage("artistsViewMode") private var viewMode: ViewMode = .list
    @State private var navigationPath = NavigationPath()

    private let gridColumns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)
    ]

    @State private var cachedSortedArtists: [Artist] = []

    private var sortedArtists: [Artist] { cachedSortedArtists }

    private func updateSortedArtists() {
        let favorites = FavoritesStore.shared.favoriteArtistIds
        cachedSortedArtists = musicService.artists.sorted { a, b in
            let aIsFavorite = favorites.contains(a.id)
            let bIsFavorite = favorites.contains(b.id)
            if aIsFavorite != bIsFavorite {
                return aIsFavorite
            }
            return a.name < b.name
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if musicService.isLoading {
                    ProgressView("Loading...")
                } else if musicService.artists.isEmpty {
                    ContentUnavailableView(
                        "No Artists",
                        systemImage: "music.mic",
                        description: Text("Your artists will appear here")
                    )
                } else {
                    switch viewMode {
                    case .list:
                        artistListView
                    case .grid:
                        artistGridView
                    }
                }
            }
            .navigationTitle("Artists")
            .onAppear { if cachedSortedArtists.isEmpty { updateSortedArtists() } }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Picker("View", selection: $viewMode) {
                            ForEach(ViewMode.allCases, id: \.self) { mode in
                                Image(systemName: mode.icon)
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 80)
                    }
                }
                .sharedBackgroundVisibility(.hidden)


                ToolbarSpacer(.fixed, placement: .primaryAction)

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            .navigationDestination(for: NavigationDestination.self) { destination in
                switch destination {
                case .artist(let artist):
                    ArtistDetailView(artist: artist, musicService: musicService, playerService: playerService, cacheService: cacheService)
                case .album(let album, _):
                    AlbumDetailView(album: album, musicService: musicService, playerService: playerService, cacheService: cacheService)
                }
            }
        }
        .task(id: pendingNavigation) {
            guard let destination = pendingNavigation else { return }
            // Small delay to ensure NavigationStack is ready
            try? await Task.sleep(for: .milliseconds(150))
            navigationPath = NavigationPath()
            navigationPath.append(destination)
            pendingNavigation = nil
        }
    }

    private var artistListView: some View {
        List(sortedArtists) { artist in
            NavigationLink {
                ArtistDetailView(artist: artist, musicService: musicService, playerService: playerService, cacheService: cacheService)
            } label: {
                HStack(spacing: 12) {
                    ArtworkImage(
                        url: artist.imageUrl,
                        size: 56,
                        systemImage: "music.mic",
                        localURL: cacheService?.localArtworkURL(for: artist.imageUrl ?? ""),
                        cacheService: cacheService,
                        isCircular: true
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(artist.name)
                            .font(.headline)

                        let songCount = artist.albums.flatMap { $0.tracks }.count
                        Text("\(artist.albums.count) albums · \(songCount) songs")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    ArtistFavoriteButton(artist: artist)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var artistGridView: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(sortedArtists) { artist in
                    NavigationLink {
                        ArtistDetailView(artist: artist, musicService: musicService, playerService: playerService, cacheService: cacheService)
                    } label: {
                        ArtistGridCard(
                            artist: artist,
                            localArtworkURL: cacheService?.localArtworkURL(for: artist.imageUrl ?? ""),
                            cacheService: cacheService
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

struct ArtistDetailView: View {
    let artist: Artist
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    private var formattedDates: String? {
        guard let beginDate = artist.beginDate else { return nil }
        let startYear = String(beginDate.prefix(4))
        if let endDate = artist.endDate {
            let endYear = String(endDate.prefix(4))
            return "\(startYear) - \(endYear)"
        } else {
            return "\(startYear) - present"
        }
    }

    var body: some View {
        List {
            // Artist header section
            Section {
                VStack(spacing: 16) {
                    // Artist image
                    ArtworkImage(url: artist.imageUrl, size: 150, systemImage: "music.mic", cacheService: cacheService, isCircular: true)

                    // Disambiguation subtitle
                    if let disambiguation = artist.disambiguation, !disambiguation.isEmpty {
                        Text(disambiguation)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Area and dates metadata
                    if artist.area != nil || formattedDates != nil {
                        HStack(spacing: 16) {
                            if let area = artist.area {
                                Label(area, systemImage: "mappin.and.ellipse")
                                    .font(.caption)
                            }
                            if let dates = formattedDates {
                                Label(dates, systemImage: "calendar")
                                    .font(.caption)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }

                    // Genre/Style/Mood metadata
                    if artist.genre != nil || artist.style != nil || artist.mood != nil {
                        HStack(spacing: 12) {
                            if let genre = artist.genre {
                                Label(genre, systemImage: "guitars")
                                    .font(.caption)
                            }
                            if let style = artist.style {
                                Label(style, systemImage: "music.note.list")
                                    .font(.caption)
                            }
                            if let mood = artist.mood {
                                Label(mood, systemImage: "face.smiling")
                                    .font(.caption)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            // Albums section (moved above bio)
            Section("Albums") {
                ForEach(artist.albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album, musicService: musicService, playerService: playerService, cacheService: cacheService)
                    } label: {
                        HStack {
                            ArtworkImage(url: album.imageUrl, size: 60, systemImage: "square.stack", cacheService: cacheService)

                            VStack(alignment: .leading) {
                                Text(album.name)
                                    .font(.headline)
                                Text("\(album.tracks.count) songs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // About section (bio moved here)
            if let bio = artist.bio {
                Section("About") {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(artist.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ArtistFavoriteButton(artist: artist)
            }
        }
    }
}

struct AlbumDetailView: View {
    let album: Album
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    @State private var artworkColor: Color = Color(white: 0.3)
    @State private var pendingNavigation: NavigationDestination?

    private var firstPlayableTrack: Track? {
        album.tracks.first { playerService.isTrackPlayable($0) }
    }

    private var hasPlayableTracks: Bool {
        firstPlayableTrack != nil
    }

    private var artistName: String? {
        album.tracks.first?.artist
    }

    private var artist: Artist? {
        guard let name = artistName else { return nil }
        return musicService.artistByName[name]
    }

    private func extractArtworkColor() {
        // Try to load from cache service first
        if let urlString = album.imageUrl,
           let cacheService = cacheService,
           let localURL = cacheService.localArtworkURL(for: urlString) {
            extractColor(from: localURL)
            return
        }

        // Fall back to downloading if we have a URL
        if let urlString = album.imageUrl,
           let url = URL(string: urlString) {
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    await MainActor.run {
                        #if os(iOS)
                        if let image = UIImage(data: data), let color = image.averageColor {
                            withAnimation(.easeInOut(duration: 0.5)) {
                                artworkColor = color
                            }
                        }
                        #else
                        if let image = NSImage(data: data), let color = image.averageColor {
                            withAnimation(.easeInOut(duration: 0.5)) {
                                artworkColor = color
                            }
                        }
                        #endif
                    }
                } catch {
                    // Silently fail - keep default color
                }
            }
        }
    }

    private func extractColor(from url: URL) {
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url)
            }.value
            guard let data else { return }
            #if os(iOS)
            guard let image = UIImage(data: data), let color = image.averageColor else { return }
            #else
            guard let image = NSImage(data: data), let color = image.averageColor else { return }
            #endif
            withAnimation(.easeInOut(duration: 0.5)) {
                artworkColor = color
            }
        }
    }

    var body: some View {
        List {
            // Album header with artwork
            Section {
                VStack(spacing: 12) {
                    ArtworkImage(url: album.imageUrl, size: 270, systemImage: "square.stack", cacheService: cacheService)
                        .shadow(radius: 10)

                    // Artist name (tappable to go to artist view)
                    if let artist = artist {
                        NavigationLink {
                            ArtistDetailView(artist: artist, musicService: musicService, playerService: playerService, cacheService: cacheService)
                        } label: {
                            Text(artist.name)
                                .font(.title3)
                                .foregroundStyle(artworkColor.contrastingSecondary)
                        }
                        .buttonStyle(.plain)
                    } else if let name = artistName {
                        Text(name)
                            .font(.title3)
                            .foregroundStyle(artworkColor.contrastingSecondary)
                    }

                    // Release date
                    if let releaseDate = album.releaseDate {
                        Text(String(releaseDate))
                            .font(.subheadline)
                            .foregroundStyle(artworkColor.contrastingSecondary)
                    }

                    // Genre/Style/Mood/Theme metadata pills
                    if album.genre != nil || album.style != nil || album.mood != nil || album.theme != nil {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                if let genre = album.genre {
                                    Text(genre)
                                        .font(.caption)
                                        .foregroundStyle(artworkColor.contrastingForeground)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(artworkColor.contrastingForeground.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                                if let style = album.style {
                                    Text(style)
                                        .font(.caption)
                                        .foregroundStyle(artworkColor.contrastingForeground)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(artworkColor.contrastingForeground.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                                if let mood = album.mood {
                                    Text(mood)
                                        .font(.caption)
                                        .foregroundStyle(artworkColor.contrastingForeground)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(artworkColor.contrastingForeground.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                                if let theme = album.theme {
                                    Text(theme)
                                        .font(.caption)
                                        .foregroundStyle(artworkColor.contrastingForeground)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(artworkColor.contrastingForeground.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            // Play buttons
            HStack(spacing: 16) {
                Button {
                    if let track = firstPlayableTrack {
                        if playerService.isShuffled {
                            playerService.toggleShuffle()
                        }
                        playerService.play(track: track, album: album)
                    }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(7)
                }
                .buttonStyle(.bordered)
                .foregroundStyle(artworkColor.contrastingForeground)
                .disabled(!hasPlayableTracks)
                .cornerRadius(6.0)

                Button {
                    playerService.shufflePlay(queue: album.tracks, album: album)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                        .padding(7)
                }
                .foregroundStyle(artworkColor.contrastingForeground)
                .buttonStyle(.bordered)
                .disabled(!hasPlayableTracks)
                .cornerRadius(6.0)
            }
            .listRowBackground(Color.clear)

            // Tracks
            Section("Tracks") {
                ForEach(album.tracks) { track in
                    let isPlayable = playerService.isTrackPlayable(track)
                    Button {
                        if isPlayable {
                            if playerService.isShuffled {
                                playerService.toggleShuffle()
                            }
                            playerService.play(track: track, album: album)
                        }
                    } label: {
                        SongRow.albumTrack(
                            track: track,
                            playerService: playerService,
                            musicService: musicService,
                            isPlayable: isPlayable,
                            onNavigate: { pendingNavigation = $0 }
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isPlayable)
                }
            }
            
            // Wiki/About section
            if let wiki = album.wiki {
                Section("About") {
                    Text(wiki)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(artworkColor.gradient)
        .onAppear {
            extractArtworkColor()
        }
        .navigationTitle(album.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AlbumFavoriteButton(album: album)
            }
        }
        #if os(iOS)
        .toolbarBackground(artworkColor, for: .navigationBar)
        #endif
        .navigationDestination(item: $pendingNavigation) { destination in
            switch destination {
            case .artist(let artist):
                ArtistDetailView(artist: artist, musicService: musicService, playerService: playerService, cacheService: cacheService)
            case .album(let album, _):
                AlbumDetailView(album: album, musicService: musicService, playerService: playerService, cacheService: cacheService)
            }
        }
    }
}

struct ArtistFavoriteButton: View {
    let artist: Artist

    private var isFavorite: Bool {
        FavoritesStore.shared.isArtistFavorite(artist.id)
    }

    var body: some View {
        Button {
            FavoritesStore.shared.toggleArtistFavorite(artist)
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(isFavorite ? .pink : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview Sample Data

extension Track {
    static let preview = Track(
        title: "Take Me to Church",
        artist: "Hozier",
        album: "Hozier",
        trackNumber: 1,
        duration: 242,
        format: "m4a",
        s3Key: "Hozier/Hozier/Take-Me-to-Church.m4a",
        url: "https://example.com/track.m4a",
        embeddedArtworkUrl: nil,
        genre: "Alternative Rock",
        style: "Indie Rock",
        mood: "Melancholic",
        theme: "Spirituality",
        albumArtist: "Hozier",
        trackTotal: 13,
        discNumber: 1,
        discTotal: 1,
        year: 2014,
        composer: nil,
        comment: nil,
        bitrate: 256.0,
        samplerate: 44100,
        channels: 2,
        filesize: 7654321,
        originalFormat: nil
    )

    static let previewTracks: [Track] = [
        Track(title: "Take Me to Church", artist: "Hozier", album: "Hozier", trackNumber: 1, duration: 242, format: "m4a", s3Key: "Hozier/Hozier/01-Take-Me-to-Church.m4a", url: nil, embeddedArtworkUrl: nil, genre: "Alternative Rock", style: nil, mood: nil, theme: nil, albumArtist: nil, trackTotal: nil, discNumber: nil, discTotal: nil, year: nil, composer: nil, comment: nil, bitrate: nil, samplerate: nil, channels: nil, filesize: nil, originalFormat: nil),
        Track(title: "Angel of Small Death", artist: "Hozier", album: "Hozier", trackNumber: 2, duration: 198, format: "m4a", s3Key: "Hozier/Hozier/02-Angel-of-Small-Death.m4a", url: nil, embeddedArtworkUrl: nil, genre: "Alternative Rock", style: nil, mood: nil, theme: nil, albumArtist: nil, trackTotal: nil, discNumber: nil, discTotal: nil, year: nil, composer: nil, comment: nil, bitrate: nil, samplerate: nil, channels: nil, filesize: nil, originalFormat: nil),
        Track(title: "Jackie and Wilson", artist: "Hozier", album: "Hozier", trackNumber: 3, duration: 225, format: "m4a", s3Key: "Hozier/Hozier/03-Jackie-and-Wilson.m4a", url: nil, embeddedArtworkUrl: nil, genre: "Alternative Rock", style: nil, mood: nil, theme: nil, albumArtist: nil, trackTotal: nil, discNumber: nil, discTotal: nil, year: nil, composer: nil, comment: nil, bitrate: nil, samplerate: nil, channels: nil, filesize: nil, originalFormat: nil),
        Track(title: "Someone New", artist: "Hozier", album: "Hozier", trackNumber: 4, duration: 212, format: "m4a", s3Key: "Hozier/Hozier/04-Someone-New.m4a", url: nil, embeddedArtworkUrl: nil, genre: "Alternative Rock", style: nil, mood: nil, theme: nil, albumArtist: nil, trackTotal: nil, discNumber: nil, discTotal: nil, year: nil, composer: nil, comment: nil, bitrate: nil, samplerate: nil, channels: nil, filesize: nil, originalFormat: nil),
        Track(title: "From Eden", artist: "Hozier", album: "Hozier", trackNumber: 5, duration: 267, format: "m4a", s3Key: "Hozier/Hozier/05-From-Eden.m4a", url: nil, embeddedArtworkUrl: nil, genre: "Alternative Rock", style: nil, mood: nil, theme: nil, albumArtist: nil, trackTotal: nil, discNumber: nil, discTotal: nil, year: nil, composer: nil, comment: nil, bitrate: nil, samplerate: nil, channels: nil, filesize: nil, originalFormat: nil)
    ]
}

extension Album {
    static let preview = Album(
        name: "Hozier",
        imageUrl: "https://upload.wikimedia.org/wikipedia/en/a/a0/Hozier_-_Hozier.png",
        wiki: "Hozier is the debut studio album by Irish singer-songwriter Hozier, released on 19 September 2014 by Island Records and Rubyworks.",
        releaseDate: 2014,
        genre: "Alternative Rock",
        style: "Indie Rock",
        mood: "Melancholic",
        theme: "Love",
        tracks: Track.previewTracks,
        releaseType: "Album",
        country: "IE",
        label: "Island Records",
        barcode: nil,
        mediaFormat: nil
    )

    static let previewAlbums: [Album] = [
        preview,
        Album(
            name: "Wasteland, Baby!",
            imageUrl: nil,
            wiki: "Second studio album by Irish musician Hozier.",
            releaseDate: 2019,
            genre: "Alternative Rock",
            style: "Indie Folk",
            mood: "Hopeful",
            theme: "Apocalypse",
            tracks: [
                Track(title: "Nina Cried Power", artist: "Hozier", album: "Wasteland, Baby!", trackNumber: 1, duration: 298, format: "m4a", s3Key: "Hozier/Wasteland-Baby/01-Nina-Cried-Power.m4a", url: nil, embeddedArtworkUrl: nil, genre: nil, style: nil, mood: nil, theme: nil, albumArtist: nil, trackTotal: nil, discNumber: nil, discTotal: nil, year: nil, composer: nil, comment: nil, bitrate: nil, samplerate: nil, channels: nil, filesize: nil, originalFormat: nil),
                Track(title: "Almost (Sweet Music)", artist: "Hozier", album: "Wasteland, Baby!", trackNumber: 2, duration: 254, format: "m4a", s3Key: "Hozier/Wasteland-Baby/02-Almost.m4a", url: nil, embeddedArtworkUrl: nil, genre: nil, style: nil, mood: nil, theme: nil, albumArtist: nil, trackTotal: nil, discNumber: nil, discTotal: nil, year: nil, composer: nil, comment: nil, bitrate: nil, samplerate: nil, channels: nil, filesize: nil, originalFormat: nil)
            ],
            releaseType: "Album",
            country: "IE",
            label: "Columbia",
            barcode: nil,
            mediaFormat: nil
        )
    ]
}

extension Artist {
    static let preview = Artist(
        name: "Hozier",
        imageUrl: "https://www.theaudiodb.com/images/media/artist/thumb/hozier.jpg",
        bio: "Andrew John Hozier-Byrne, known mononymously as Hozier, is an Irish singer, songwriter and musician. His music primarily draws from folk, soul and blues, often using religious and literary themes.",
        genre: "Alternative Rock",
        style: "Indie Folk",
        mood: "Melancholic",
        albums: Album.previewAlbums,
        artistType: "Person",
        area: "Ireland",
        beginDate: "1990-03-17",
        endDate: nil,
        disambiguation: "Irish singer-songwriter"
    )

    static let previewArtists: [Artist] = [
        preview,
        Artist(
            name: "Adele",
            imageUrl: nil,
            bio: "Adele Laurie Blue Adkins is an English singer and songwriter.",
            genre: "Pop",
            style: "Soul",
            mood: "Emotional",
            albums: [
                Album(name: "21", imageUrl: nil, wiki: nil, releaseDate: 2011, genre: "Pop", style: nil, mood: nil, theme: nil, tracks: [
                    Track(title: "Rolling in the Deep", artist: "Adele", album: "21", trackNumber: 1, duration: 228, format: "m4a", s3Key: "Adele/21/01-Rolling-in-the-Deep.m4a", url: nil, embeddedArtworkUrl: nil, genre: nil, style: nil, mood: nil, theme: nil, albumArtist: nil, trackTotal: nil, discNumber: nil, discTotal: nil, year: nil, composer: nil, comment: nil, bitrate: nil, samplerate: nil, channels: nil, filesize: nil, originalFormat: nil)
                ], releaseType: nil, country: nil, label: nil, barcode: nil, mediaFormat: nil)
            ],
            artistType: "Person",
            area: "United Kingdom",
            beginDate: "1988-05-05",
            endDate: nil,
            disambiguation: "British singer"
        ),
        Artist(
            name: "The Beatles",
            imageUrl: nil,
            bio: "The Beatles were an English rock band formed in Liverpool in 1960.",
            genre: "Rock",
            style: "Pop Rock",
            mood: "Varied",
            albums: [],
            artistType: "Group",
            area: "United Kingdom",
            beginDate: "1960-01-01",
            endDate: "1970-04-10",
            disambiguation: "British rock band"
        )
    ]
}

// MARK: - Previews

#Preview("Artists View") {
    ArtistsView(
        showingSearch: .constant(false),
        musicService: MusicService(),
        playerService: PlayerService(),
        pendingNavigation: .constant(nil)
    )
}

#Preview("Artwork Image") {
    VStack(spacing: 20) {
        ArtworkImage(url: nil, size: 100, systemImage: "music.mic", isCircular: true)
        ArtworkImage(url: nil, size: 100, systemImage: "square.stack")
        ArtworkImage(url: nil, size: 60, systemImage: "music.note")
    }
    .padding()
}

#Preview("Artist Grid Card") {
    ArtistGridCard(artist: .preview)
        .frame(width: 180)
        .padding()
}

#Preview("Album Grid Card") {
    AlbumGridCard(album: .preview, artistName: "Hozier")
        .frame(width: 180)
        .padding()
}

#Preview("Artist Detail View") {
    NavigationStack {
        ArtistDetailView(
            artist: .preview,
            musicService: MusicService(),
            playerService: PlayerService()
        )
    }
}

#Preview("Album Detail View") {
    NavigationStack {
        AlbumDetailView(
            album: .preview,
            musicService: MusicService(),
            playerService: PlayerService()
        )
    }
}

#Preview("Album Track Row") {
    List {
        SongRow.albumTrack(track: .preview, playerService: PlayerService())
        SongRow.albumTrack(track: .preview, playerService: PlayerService(), isPlayable: false)
    }
}

#Preview("Artist Favorite Button") {
    HStack(spacing: 20) {
        ArtistFavoriteButton(artist: .preview)
        AlbumFavoriteButton(album: .preview)
    }
    .padding()
}
