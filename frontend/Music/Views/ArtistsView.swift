//
//  ArtistsView.swift
//  Music
//

import SwiftUI

struct ArtworkImage: View {
    let url: String?
    let size: CGFloat
    let systemImage: String
    var localURL: URL? = nil
    var cacheService: CacheService? = nil

    @State private var cachedLocalURL: URL? = nil
    @State private var hasTriggeredDownload = false

    var body: some View {
        Group {
            if let localURL = localURL ?? cachedLocalURL, let platformImage = loadLocalImage(from: localURL) {
                #if os(iOS)
                Image(uiImage: platformImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                #else
                Image(nsImage: platformImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                #endif
            } else if let urlString = url, let imageUrl = URL(string: urlString) {
                if let cacheService = cacheService {
                    // Cache service available - trigger download and show placeholder
                    placeholderView
                        .onAppear {
                            triggerCacheDownload(urlString: urlString, cacheService: cacheService)
                        }
                } else {
                    // No cache service - use AsyncImage directly
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
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        case .failure:
                            placeholderView
                        @unknown default:
                            placeholderView
                        }
                    }
                }
            } else {
                placeholderView
            }
        }
    }

    private func triggerCacheDownload(urlString: String, cacheService: CacheService) {
        guard !hasTriggeredDownload else { return }
        hasTriggeredDownload = true

        cacheService.cacheArtworkIfNeeded(urlString) { localURL in
            DispatchQueue.main.async {
                if let localURL = localURL {
                    cachedLocalURL = localURL
                }
            }
        }
    }

    private var placeholderView: some View {
        Image(systemName: systemImage)
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    #if os(iOS)
    private func loadLocalImage(from url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
    #else
    private func loadLocalImage(from url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }
    #endif
}

struct ArtistGridCard: View {
    let artist: Artist
    var localArtworkURL: URL?
    var cacheService: CacheService?

    private var songCount: Int {
        artist.albums.reduce(0) { $0 + $1.tracks.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(
                url: artist.imageUrl,
                size: 160,
                systemImage: "music.mic",
                localURL: localArtworkURL,
                cacheService: cacheService
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)

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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(
                url: album.imageUrl,
                size: 160,
                systemImage: "square.stack",
                localURL: localArtworkURL,
                cacheService: cacheService
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)

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

    @AppStorage("artistsViewMode") private var viewMode: ViewMode = .list

    private let gridColumns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
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
        }
    }

    private var artistListView: some View {
        List(musicService.artists) { artist in
            NavigationLink {
                ArtistDetailView(artist: artist, musicService: musicService, playerService: playerService, cacheService: cacheService)
            } label: {
                HStack(spacing: 12) {
                    ArtworkImage(
                        url: artist.imageUrl,
                        size: 56,
                        systemImage: "music.mic",
                        localURL: cacheService?.localArtworkURL(for: artist.imageUrl ?? ""),
                        cacheService: cacheService
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(artist.name)
                            .font(.headline)

                        let songCount = artist.albums.flatMap { $0.tracks }.count
                        Text("\(artist.albums.count) albums · \(songCount) songs")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var artistGridView: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(musicService.artists) { artist in
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
                    ArtworkImage(url: artist.imageUrl, size: 150, systemImage: "music.mic", cacheService: cacheService)

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
    }
}

struct AlbumDetailView: View {
    let album: Album
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

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
        return musicService.artists.first { $0.name == name }
    }

    var body: some View {
        List {
            // Album header with artwork
            Section {
                VStack(spacing: 12) {
                    ArtworkImage(url: album.imageUrl, size: 200, systemImage: "square.stack", cacheService: cacheService)

                    // Artist name (tappable to go to artist view)
                    if let artist = artist {
                        NavigationLink {
                            ArtistDetailView(artist: artist, musicService: musicService, playerService: playerService, cacheService: cacheService)
                        } label: {
                            Text(artist.name)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    } else if let name = artistName {
                        Text(name)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    // Release date
                    if let releaseDate = album.releaseDate {
                        Text(String(releaseDate))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Genre/Style/Mood/Theme metadata pills
                    if album.genre != nil || album.mood != nil || album.theme != nil {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                if let genre = album.genre {
                                    Text(genre)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.secondary.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                                if let style = album.style {
                                    Text(style)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.orange.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                                if let mood = album.mood {
                                    Text(mood)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                                if let theme = album.theme {
                                    Text(theme)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.purple.opacity(0.2))
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
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .disabled(!hasPlayableTracks)

                Button {
                    if let track = firstPlayableTrack {
                        if !playerService.isShuffled {
                            playerService.toggleShuffle()
                        }
                        playerService.play(track: track, album: album)
                    }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!hasPlayableTracks)
            }
            .listRowBackground(Color.clear)

            // Wiki/About section
            if let wiki = album.wiki {
                Section("About") {
                    Text(wiki)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Tracks
            Section("Tracks") {
                ForEach(album.tracks) { track in
                    let isPlayable = playerService.isTrackPlayable(track)
                    Button {
                        if isPlayable {
                            playerService.play(track: track, album: album)
                        }
                    } label: {
                        AlbumTrackRow(track: track, playerService: playerService, isPlayable: isPlayable)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isPlayable)
                }
            }
        }
        .navigationTitle(album.name)
    }
}

struct AlbumTrackRow: View {
    let track: Track
    var playerService: PlayerService
    var isPlayable: Bool = true

    private var isCurrentTrack: Bool {
        playerService.currentTrack?.id == track.id
    }

    var body: some View {
        HStack {
            // Now playing indicator or track number
            if isCurrentTrack {
                Image(systemName: playerService.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .foregroundStyle(.yellow)
                    .frame(width: 30)
            } else if let trackNumber = track.trackNumber {
                Text("\(trackNumber)")
                    .foregroundStyle(isPlayable ? .secondary : .tertiary)
                    .frame(width: 30)
            } else {
                Spacer()
                    .frame(width: 30)
            }

            VStack(alignment: .leading) {
                Text(track.title)
                    .font(.headline)
                    .foregroundStyle(isCurrentTrack ? .yellow : (isPlayable ? .primary : .secondary))
                if let artist = track.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !isPlayable {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Text(track.formattedDuration)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(isPlayable ? 1.0 : 0.5)
    }
}

#Preview {
    ArtistsView(showingSearch: .constant(false), musicService: MusicService(), playerService: PlayerService())
}
