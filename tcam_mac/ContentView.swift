import SwiftUI
import AppKit
import AVFoundation

// MARK: - Enums

private enum LoadState: Equatable {
    case idle
    case loading
    case loaded(total: Int)
    case empty
}

enum ClipSort: String, CaseIterable {
    case newestFirst = "Newest First"
    case oldestFirst = "Oldest First"
    case longest     = "Longest"
    case shortest    = "Shortest"
}

enum DateRangeFilter: String, CaseIterable {
    case all       = "All"
    case today     = "Today"
    case thisWeek  = "This Week"
    case thisMonth = "This Month"
}

// MARK: - UserDefaults Keys

private enum UDKey {
    static let lastFolderBookmark = "com.tcam.lastFolderBookmark"
    static let recentFolders      = "com.tcam.recentFolders"
    static let favorites          = "com.tcam.favorites"
}

// MARK: - ContentView

struct ContentView: View {
    @State private var selectedSection: SidebarSection = .saved
    @State private var searchText = ""
    @State private var clipsBySection: [SidebarSection: [TeslaClip]] = [:]
    @State private var selectedFolder: URL? = nil
    @State private var selectedClip: TeslaClip? = nil
    @State private var loadState: LoadState = .idle

    // Persistence
    @State private var recentFolders: [URL] = []

    // Sorting & filtering
    @State private var clipSort: ClipSort = .newestFirst
    @State private var dateFilter: DateRangeFilter = .all

    // Favorites
    @State private var favorites: [String: Bool] = [:]
    @State private var showFavoritesOnly: Bool = false

    var body: some View {
        let baseView = NavigationStack {
            if let clip = selectedClip {
                VideoPlayerView(clip: clip)
                    .navigationTitle(clip.title)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                withAnimation(.ui) { selectedClip = nil }
                            } label: {
                                Label("Back", systemImage: "chevron.left")
                            }
                        }
                    }
            } else {
                mainContent
            }
        }
        .toolbar {
            if loadState != .idle {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $selectedSection) {
                        ForEach(SidebarSection.allCases) { section in
                            let count = clipsBySection[section]?.count ?? 0
                            Text(count > 0 ? "\(section.title) (\(count))" : section.title)
                                .tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            // Sort menu
            if loadState != .idle {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(ClipSort.allCases, id: \.self) { sort in
                            Button {
                                withAnimation(.ui) { clipSort = sort }
                            } label: {
                                if clipSort == sort {
                                    Label(sort.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(sort.rawValue)
                                }
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
            }

            // Recent folders menu
            ToolbarItem(placement: .primaryAction) {
                if !recentFolders.isEmpty {
                    Menu {
                        ForEach(recentFolders, id: \.path) { url in
                            Button(url.lastPathComponent) {
                                openRecentFolder(url)
                            }
                        }
                    } label: {
                        Label("Recent", systemImage: "clock")
                    }
                    .disabled(loadState == .loading)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button("Choose TeslaCam Folder", systemImage: "folder") {
                    chooseTeslaCamFolder()
                }
                .disabled(loadState == .loading)
            }
        }
        .onChange(of: selectedSection) { _, _ in selectedClip = nil }
        .onAppear {
            loadFavorites()
            loadRecentFolders()
            restoreLastFolder()
        }

        if loadState != .idle {
            baseView
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search clips")
        } else {
            baseView
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.08, blue: 0.12),
                    Color(red: 0.03, green: 0.04, blue: 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if loadState == .idle {
                idleContent
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    compactHeader
                    sectionContent
                        .id(selectedSection)
                        .transition(.opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.ui, value: selectedSection)
    }

    // MARK: - Idle State

    private var idleContent: some View {
        VStack(spacing: 40) {
            VStack(spacing: 12) {
                Text("Tesla Dashcam")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Select your TeslaCam root folder to begin")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }

            Button {
                chooseTeslaCamFolder()
            } label: {
                Label("Choose TeslaCam Folder", systemImage: "folder")
                    .font(.headline)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Compact Header

    private var compactHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tesla Dashcam")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(selectedFolder.map { "Source: \($0.lastPathComponent)" } ?? "Source: No folder selected")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer()
            statusPill
        }
        .padding(.horizontal, Layout.pagePadding)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Status Pill

    private var statusPill: some View {
        Group {
            switch loadState {
            case .idle:
                HStack(spacing: 6) {
                    Circle().fill(.secondary).frame(width: 8, height: 8)
                    Text("No Folder").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).frame(width: 8, height: 8)
                    Text("Scanning…").font(.caption.weight(.medium))
                }
            case .loaded(let total):
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("\(total) clip\(total == 1 ? "" : "s")").font(.caption.weight(.medium))
                }
            case .empty:
                HStack(spacing: 6) {
                    Circle().fill(.orange).frame(width: 8, height: 8)
                    Text("No Clips Found").font(.caption.weight(.medium)).foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect()
        .animation(.ui, value: loadStateID)
    }

    private var loadStateID: String {
        switch loadState {
        case .idle:    return "idle"
        case .loading: return "loading"
        case .loaded:  return "loaded"
        case .empty:   return "empty"
        }
    }

    // MARK: - Section Content

    @ViewBuilder
    private var sectionContent: some View {
        switch loadState {
        case .idle:
            ContentUnavailableView {
                Label("No TeslaCam Folder Selected", systemImage: "folder.badge.gear")
            } description: {
                Text("Click the folder button in the toolbar to load SavedClips, SentryClips, or RecentClips.")
            }

        case .loading:
            VStack(spacing: 16) {
                ProgressView().scaleEffect(1.4)
                Text("Scanning clips…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            ContentUnavailableView(
                "No TeslaCam Clips Found",
                systemImage: "video.slash",
                description: Text("The selected folder doesn't contain any SavedClips, SentryClips, or RecentClips.")
            )

        case .loaded:
            loadedSectionContent
        }
    }

    @ViewBuilder
    private var loadedSectionContent: some View {
        let clips = clipsBySection[selectedSection] ?? []
        let filtered = filteredClips(from: clips)

        if clips.isEmpty {
            sectionEmptyState(
                title: "No Clips in \(selectedSection.title)",
                description: "There are no \(selectedSection.title.lowercased()) clips in this TeslaCam folder."
            )
        } else if filtered.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                filterChipsRow
                sectionEmptyState(
                    title: filteredEmptyStateTitle,
                    description: filteredEmptyStateDescription
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            clipGrid(for: filtered)
        }
    }

    private var filteredEmptyStateTitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No Matching Clips"
        }
        if showFavoritesOnly && dateFilter != .all {
            return "No Favorite Clips for \(dateFilter.rawValue)"
        }
        if showFavoritesOnly {
            return "No Favorite Clips"
        }
        return "No Clips for \(dateFilter.rawValue)"
    }

    private var filteredEmptyStateDescription: String {
        let sectionName = selectedSection.title.lowercased()
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedSearch.isEmpty {
            return "No \(sectionName) clips match \"\(trimmedSearch)\" with the current filters."
        }
        if showFavoritesOnly && dateFilter != .all {
            return "There are no favorite \(sectionName) clips for the \(dateFilter.rawValue.lowercased()) filter."
        }
        if showFavoritesOnly {
            return "There are no favorite \(sectionName) clips in this TeslaCam folder."
        }
        return "There are no \(sectionName) clips for the \(dateFilter.rawValue.lowercased()) filter."
    }

    private func sectionEmptyState(title: String, description: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Text(description)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filter Chips

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DateRangeFilter.allCases, id: \.self) { filter in
                    let isSelected = dateFilter == filter
                    Text(filter.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.78))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            isSelected
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.13, green: 0.49, blue: 0.97),
                                            Color(red: 0.08, green: 0.36, blue: 0.82)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                : AnyShapeStyle(Color.white.opacity(0.10)),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .stroke(
                                    isSelected
                                        ? Color.white.opacity(0.14)
                                        : Color.white.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                        .shadow(
                            color: isSelected ? Color(red: 0.13, green: 0.49, blue: 0.97).opacity(0.28) : .clear,
                            radius: 8,
                            y: 3
                        )
                        .contentShape(Capsule())
                        .onTapGesture { withAnimation(.hover) { dateFilter = filter } }
                }

                Divider()
                    .frame(height: 16)
                    .opacity(0.4)

                // Favorites toggle chip
                let favActive = showFavoritesOnly
                HStack(spacing: 4) {
                    Image(systemName: favActive ? "heart.fill" : "heart")
                        .font(.caption.weight(.bold))
                    Text("Favorites")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(favActive ? Color(red: 1.0, green: 0.48, blue: 0.71) : Color.white.opacity(0.78))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    favActive
                        ? AnyShapeStyle(Color(red: 1.0, green: 0.33, blue: 0.63).opacity(0.24))
                        : AnyShapeStyle(Color.white.opacity(0.10)),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .stroke(
                            favActive ? Color(red: 1.0, green: 0.55, blue: 0.76).opacity(0.32) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
                .contentShape(Capsule())
                .onTapGesture { withAnimation(.hover) { showFavoritesOnly.toggle() } }
            }
            .padding(.horizontal, Layout.pagePadding)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Clip Grid

    private func clipGrid(for clips: [TeslaClip]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    filterChipsRow
                        .padding(.horizontal, -Layout.pagePadding)
                }

                HStack {
                    Text("\(selectedSection.title) Timeline")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text("\(clips.count) item\(clips.count == 1 ? "" : "s")")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(.horizontal, 2)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300), spacing: Layout.gridSpacing)],
                    spacing: Layout.gridSpacing
                ) {
                    ForEach(clips) { clip in
                        ClipPreviewCard(
                            clip: clip,
                            isFavorite: favorites[clip.id] == true,
                            onToggleFavorite: { toggleFavorite(clip) }
                        )
                        .onTapGesture {
                            withAnimation(.ui) { selectedClip = clip }
                        }
                        .contextMenu {
                            if let folderURL = clip.folderURL {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([folderURL])
                                } label: {
                                    Label("Show in Finder", systemImage: "folder")
                                }

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(folderURL.path, forType: .string)
                                } label: {
                                    Label("Copy Folder Path", systemImage: "doc.on.clipboard")
                                }

                                Button {
                                    shareClip(clip)
                                } label: {
                                    Label("Share…", systemImage: "square.and.arrow.up")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    deleteClip(clip)
                                } label: {
                                    Label("Move to Trash", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .padding(Layout.pagePadding)
        }
    }

    // MARK: - Filtering & Sorting

    private func filteredClips(from clips: [TeslaClip]) -> [TeslaClip] {
        var result = clips

        // Text search
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
        }

        // Date filter
        result = applyDateFilter(result)

        // Favorites filter
        if showFavoritesOnly {
            result = result.filter { favorites[$0.id] == true }
        }

        // Sort
        switch clipSort {
        case .newestFirst: result.sort { $0.date > $1.date }
        case .oldestFirst: result.sort { $0.date < $1.date }
        case .longest:     result.sort { $0.durationSeconds > $1.durationSeconds }
        case .shortest:    result.sort { $0.durationSeconds < $1.durationSeconds }
        }

        return result
    }

    private func applyDateFilter(_ clips: [TeslaClip]) -> [TeslaClip] {
        let cal = Calendar.current
        let now = Date()
        switch dateFilter {
        case .all:       return clips
        case .today:     return clips.filter { cal.isDateInToday($0.date) }
        case .thisWeek:  return clips.filter { cal.isDate($0.date, equalTo: now, toGranularity: .weekOfYear) }
        case .thisMonth: return clips.filter { cal.isDate($0.date, equalTo: now, toGranularity: .month) }
        }
    }

    // MARK: - Persistence: Bookmark

    private func restoreLastFolder() {
        guard let data = UserDefaults.standard.data(forKey: UDKey.lastFolderBookmark) else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            UserDefaults.standard.removeObject(forKey: UDKey.lastFolderBookmark)
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            UserDefaults.standard.removeObject(forKey: UDKey.lastFolderBookmark)
            return
        }
        if isStale, let refreshed = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(refreshed, forKey: UDKey.lastFolderBookmark)
        }
        loadFolder(url)
    }

    // MARK: - Persistence: Recent Folders

    private func loadRecentFolders() {
        let paths = UserDefaults.standard.stringArray(forKey: UDKey.recentFolders) ?? []
        recentFolders = paths.compactMap { URL(fileURLWithPath: $0) }
    }

    private func saveRecentFolder(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: UDKey.recentFolders) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        paths = Array(paths.prefix(5))
        UserDefaults.standard.set(paths, forKey: UDKey.recentFolders)
        recentFolders = paths.compactMap { URL(fileURLWithPath: $0) }
    }

    private func openRecentFolder(_ url: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Re-select your TeslaCam folder or drive to grant access"
        panel.directoryURL = url
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let selected = panel.url else { return }
        saveRecentFolder(selected)
        if let bookmarkData = try? selected.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmarkData, forKey: UDKey.lastFolderBookmark)
        }
        loadFolder(selected)
    }

    // MARK: - Persistence: Favorites

    private func loadFavorites() {
        favorites = (UserDefaults.standard.dictionary(forKey: UDKey.favorites) as? [String: Bool]) ?? [:]
    }

    private func toggleFavorite(_ clip: TeslaClip) {
        let current = favorites[clip.id] ?? false
        favorites[clip.id] = !current
        UserDefaults.standard.set(favorites, forKey: UDKey.favorites)
    }

    // MARK: - Clip Export / Share

    private func shareClip(_ clip: TeslaClip) {
        guard let folderURL = clip.folderURL else { return }

        // Collect all MP4 files from every moment, sorted by timestamp
        let mp4s: [URL] = clip.moments
            .sorted { $0.timestamp < $1.timestamp }
            .flatMap { moment in
                CameraChannel.allCases.compactMap { moment.files[$0] }
            }

        let items: [Any] = mp4s.isEmpty ? [folderURL] : mp4s
        let picker = NSSharingServicePicker(items: items)

        // Anchor to the key window's content view
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
    }

    // MARK: - Clip Deletion

    private func deleteClip(_ clip: TeslaClip) {
        guard let folderURL = clip.folderURL else { return }
        if selectedClip?.id == clip.id { selectedClip = nil }
        NSWorkspace.shared.recycle([folderURL]) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                for section in SidebarSection.allCases {
                    clipsBySection[section]?.removeAll { $0.id == clip.id }
                }
                let total = clipsBySection.values.reduce(0) { $0 + $1.count }
                loadState = total > 0 ? .loaded(total: total) : .empty
            }
        }
    }

    // MARK: - Folder Loading

    private func chooseTeslaCamFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Select your TeslaCam folder or the drive that contains it"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmarkData, forKey: UDKey.lastFolderBookmark)
        }
        saveRecentFolder(url)
        loadFolder(url)
    }

    private func loadFolder(_ url: URL) {
        let resolvedURL = resolveTeslaCamRoot(from: url)
        selectedFolder = resolvedURL
        selectedClip = nil
        loadState = .loading

        Task.detached(priority: .userInitiated) {
            let result = await TeslaCamParser.parseFolder(resolvedURL)
            await MainActor.run {
                clipsBySection = result
                let total = result.values.reduce(0) { $0 + $1.count }
                loadState = total > 0 ? .loaded(total: total) : .empty

                if clipsBySection[selectedSection]?.isEmpty != false {
                    if let first = SidebarSection.allCases.first(where: { !(clipsBySection[$0] ?? []).isEmpty }) {
                        selectedSection = first
                    }
                }
            }
        }
    }

    private func resolveTeslaCamRoot(from url: URL) -> URL {
        if isTeslaCamRoot(url) {
            return url
        }

        let directChild = url.appendingPathComponent("TeslaCam", isDirectory: true)
        if isTeslaCamRoot(directChild) {
            return directChild
        }

        let fm = FileManager.default
        if let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
           let teslaCamFolder = children.first(where: {
               $0.lastPathComponent.caseInsensitiveCompare("TeslaCam") == .orderedSame && isTeslaCamRoot($0)
           }) {
            return teslaCamFolder
        }

        return url
    }

    private func isTeslaCamRoot(_ url: URL) -> Bool {
        let fm = FileManager.default
        let clipFolderNames = ["RecentClips", "SavedClips", "SentryClips"]
        return clipFolderNames.contains {
            fm.fileExists(atPath: url.appendingPathComponent($0, isDirectory: true).path)
        }
    }
}

// MARK: - Clip Preview Card

struct ClipPreviewCard: View {
    let clip: TeslaClip
    let isFavorite: Bool
    let onToggleFavorite: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white.opacity(0.06))
                    .aspectRatio(Layout.teslaAspect, contentMode: .fit)

                if let thumbURL = clip.thumbnailURL {
                    ClipThumbnailView(thumbnailURL: thumbURL) {
                        placeholderIcon
                    }
                } else {
                    placeholderIcon
                }

                // Clip type badge — top left
                Text(clip.type.title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(10)

                // Favorite button — top right
                Button {
                    onToggleFavorite()
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isFavorite ? Color.pink : Color.white.opacity(0.7))
                        .padding(8)
                        .background(Circle().fill(.black.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(6)

                // Play icon — center, on hover
                Image(systemName: "play.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.4), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                    .opacity(isHovered ? 1.0 : 0.0)
                    .scaleEffect(isHovered ? 1.0 : 0.88)
                    .animation(.hover, value: isHovered)
            }

            Text(clip.title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(2)

            HStack(alignment: .firstTextBaseline) {
                Text(clip.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))

                Spacer()

                Text("\(clip.duration) · \(clip.cameraCount) cams")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12), lineWidth: 1))
        .scaleEffect(isHovered ? 1.015 : 1.0)
        .shadow(
            color: .black.opacity(isHovered ? 0.18 : 0.07),
            radius: isHovered ? 18 : 8,
            y: isHovered ? 8 : 3
        )
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.hover) { isHovered = hovering } }
    }

    private var placeholderIcon: some View {
        Image(systemName: "video.fill")
            .font(.system(size: 44))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Thumbnail Cache

private actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memCache = NSCache<NSString, NSImage>()
    private let diskCacheDir: URL

    private init() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tcam_thumbs")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        diskCacheDir = tmp
        memCache.countLimit = 300
        memCache.totalCostLimit = 120 * 1024 * 1024 // 120 MB
    }

    func image(for key: String) -> NSImage? {
        if let mem = memCache.object(forKey: key as NSString) { return mem }
        let diskURL = diskCacheDir.appendingPathComponent(key).appendingPathExtension("jpg")
        guard let data = try? Data(contentsOf: diskURL),
              let img = NSImage(data: data) else { return nil }
        memCache.setObject(img, forKey: key as NSString)
        return img
    }

    func store(_ image: NSImage, for key: String) {
        memCache.setObject(image, forKey: key as NSString)
        let diskURL = diskCacheDir.appendingPathComponent(key).appendingPathExtension("jpg")
        guard !FileManager.default.fileExists(atPath: diskURL.path) else { return }
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) {
            try? jpeg.write(to: diskURL, options: .atomic)
        }
    }

    nonisolated static func key(for url: URL) -> String {
        let hash = abs(url.path.hashValue)
        return "\(hash)"
    }
}

// MARK: - Clip Thumbnail View

private struct ClipThumbnailView<Placeholder: View>: View {
    let thumbnailURL: URL
    @ViewBuilder let placeholder: Placeholder

    @State private var image: Image?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .aspectRatio(Layout.teslaAspect, contentMode: .fill)
                    .overlay(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.28)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else if isLoading {
                ProgressView()
            } else {
                placeholder
            }
        }
        .task(id: thumbnailURL) {
            guard image == nil else { return }
            isLoading = true
            image = await Self.loadImage(from: thumbnailURL)
            isLoading = false
        }
    }

    private nonisolated static func loadImage(from url: URL) async -> Image? {
        let key = ThumbnailCache.key(for: url)

        // 1. Memory / disk cache hit — instant
        if let cached = await ThumbnailCache.shared.image(for: key) {
            return Image(nsImage: cached)
        }

        return await Task.detached(priority: .utility) {
            let fileExt = url.pathExtension.lowercased()

            // 2. Static image (thumb.png)
            if ["png", "jpg", "jpeg", "heic"].contains(fileExt),
               let nsImage = NSImage(contentsOf: url) {
                let thumb = nsImage.resized(toMaxDimension: 600)
                await ThumbnailCache.shared.store(thumb, for: key)
                return Image(nsImage: thumb)
            }

            // 3. Video: fast keyframe extraction
            guard fileExt == "mp4" || fileExt == "mov" else { return nil }

            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 600, height: 390)
            // Snap to nearest keyframe — avoids decoding B/P frames (5–10× faster)
            let tolerance = CMTime(seconds: 3, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter  = tolerance

            let probeTimes: [CMTime] = [
                CMTime(seconds: 1, preferredTimescale: 600),
                CMTime(seconds: 0.5, preferredTimescale: 600),
                .zero
            ]
            for time in probeTimes {
                if let result = try? await generator.image(at: time) {
                    let nsImage = NSImage(cgImage: result.image, size: .zero)
                    await ThumbnailCache.shared.store(nsImage, for: key)
                    return Image(nsImage: nsImage)
                }
            }
            return nil
        }.value
    }
}

private extension NSImage {
    /// Returns a copy scaled so the longest side is ≤ maxDimension.
    nonisolated func resized(toMaxDimension max: CGFloat) -> NSImage {
        let sz = size
        guard sz.width > max || sz.height > max else { return self }
        let scale = max / Swift.max(sz.width, sz.height)
        let newSize = CGSize(width: sz.width * scale, height: sz.height * scale)
        let result = NSImage(size: newSize)
        result.lockFocus()
        draw(in: CGRect(origin: .zero, size: newSize),
             from: .zero,
             operation: .copy,
             fraction: 1)
        result.unlockFocus()
        return result
    }
}

// MARK: - Models

enum SidebarSection: String, CaseIterable, Identifiable {
    case saved, sentry, recent
    nonisolated var id: String { rawValue }
    nonisolated var title: String { rawValue.capitalized }
    nonisolated var icon: String {
        switch self {
        case .saved:  "bookmark.fill"
        case .sentry: "shield.lefthalf.filled"
        case .recent: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        }
    }
}

enum CameraChannel: String, CaseIterable {
    case front, back, left_repeater, right_repeater, left_pillar, right_pillar
}

struct TeslaMoment: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let files: [CameraChannel: URL]
}

struct TeslaClip: Identifiable {
    /// Stable across re-scans: derived from type + first moment's unix timestamp
    var id: String {
        let ts = moments.first.map { String(format: "%.0f", $0.timestamp.timeIntervalSince1970) } ?? "0"
        return "\(type.rawValue)_\(ts)"
    }
    let folderURL: URL?          // nil for RecentClips (flat files, no event folder)
    let title: String
    let date: Date
    let type: SidebarSection
    let thumbnailURL: URL?
    let moments: [TeslaMoment]
    let durationSeconds: Double
    var cameraCount: Int { moments.first?.files.count ?? 0 }
    var duration: String {
        let totalSeconds = max(0, Int(durationSeconds.rounded()))
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Parser

private actor DurationResolver {
    private var cache: [URL: Double] = [:]

    func duration(for url: URL) async -> Double {
        if let cached = cache[url] { return cached }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let loadedDuration = try? await asset.load(.duration)
        let seconds = loadedDuration.map { CMTimeGetSeconds($0) } ?? 60
        let safeDuration = (seconds.isFinite && seconds > 0) ? seconds : 60
        cache[url] = safeDuration
        return safeDuration
    }
}

private class TeslaCamParser {

    nonisolated static func parseFolder(_ rootURL: URL) async -> [SidebarSection: [TeslaClip]] {
        let fm = FileManager.default
        var result: [SidebarSection: [TeslaClip]] = [:]
        let durationResolver = DurationResolver()

        let recentURL = rootURL.appendingPathComponent("RecentClips")
        if fm.fileExists(atPath: recentURL.path) {
            result[.recent] = await parseRecent(recentURL, durationResolver: durationResolver)
        }

        let savedURL = rootURL.appendingPathComponent("SavedClips")
        if fm.fileExists(atPath: savedURL.path) {
            result[.saved] = await parseEventFolders(savedURL, type: .saved, durationResolver: durationResolver)
        }

        let sentryURL = rootURL.appendingPathComponent("SentryClips")
        if fm.fileExists(atPath: sentryURL.path) {
            result[.sentry] = await parseEventFolders(sentryURL, type: .sentry, durationResolver: durationResolver)
        }

        return result
    }

    private nonisolated static func parseRecent(
        _ folderURL: URL,
        durationResolver: DurationResolver
    ) async -> [TeslaClip] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else { return [] }

        var momentMap: [String: [CameraChannel: URL]] = [:]
        for file in files where file.pathExtension.lowercased() == "mp4" {
            if let ts = extractTimestamp(file.lastPathComponent),
               let channel = channelFromFilename(file.lastPathComponent) {
                momentMap[ts, default: [:]][channel] = file
            }
        }

        let clips: [TeslaClip] = await withTaskGroup(of: TeslaClip?.self) { group in
            for (ts, fileMap) in momentMap {
                group.addTask {
                    guard let timestamp = dateFromTimestamp(ts) else { return nil }
                    let moments = [TeslaMoment(timestamp: timestamp, files: fileMap)]
                    let thumbURL = fileMap[.front] ?? fileMap.values.first
                    return TeslaClip(
                        folderURL: nil,
                        title: "Recent • \(ts)",
                        date: timestamp,
                        type: .recent,
                        thumbnailURL: thumbURL,
                        moments: moments,
                        durationSeconds: await clipDurationSeconds(for: moments, durationResolver: durationResolver)
                    )
                }
            }
            var result: [TeslaClip] = []
            for await clip in group {
                if let clip { result.append(clip) }
            }
            return result
        }

        return clips.sorted { $0.date > $1.date }
    }

    private nonisolated static func parseEventFolders(
        _ parentURL: URL,
        type: SidebarSection,
        durationResolver: DurationResolver
    ) async -> [TeslaClip] {
        let fm = FileManager.default
        guard let subfolders = try? fm.contentsOfDirectory(at: parentURL, includingPropertiesForKeys: nil) else { return [] }

        let clips: [TeslaClip] = await withTaskGroup(of: TeslaClip?.self) { group in
            for folderURL in subfolders {
                group.addTask {
                    await parseEventFolder(folderURL, type: type, durationResolver: durationResolver)
                }
            }
            var result: [TeslaClip] = []
            result.reserveCapacity(subfolders.count)
            for await clip in group {
                if let clip { result.append(clip) }
            }
            return result
        }
        return clips.sorted { $0.date > $1.date }
    }

    private nonisolated static func parseEventFolder(
        _ folderURL: URL,
        type: SidebarSection,
        durationResolver: DurationResolver
    ) async -> TeslaClip? {
        let fm = FileManager.default
        guard let eventDate = dateFromTimestamp(folderURL.lastPathComponent) else { return nil }
        guard let files = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else { return nil }

        var momentMap: [String: [CameraChannel: URL]] = [:]
        var thumbURL: URL? = nil

        for fileURL in files {
            let name = fileURL.lastPathComponent.lowercased()
            if name == "thumb.png" { thumbURL = fileURL; continue }
            if name == "event.mp4" || name.hasPrefix("._") { continue }

            if fileURL.pathExtension.lowercased() == "mp4",
               let ts = extractTimestamp(fileURL.lastPathComponent),
               let channel = channelFromFilename(fileURL.lastPathComponent) {
                momentMap[ts, default: [:]][channel] = fileURL
            }
        }

        let moments: [TeslaMoment] = momentMap.compactMap { entry in
            guard let timestamp = dateFromTimestamp(entry.key) else { return nil }
            return TeslaMoment(timestamp: timestamp, files: entry.value)
        }
        let sortedMoments = moments.sorted { $0.timestamp < $1.timestamp }
        let fallbackThumb = sortedMoments.first?.files[.front] ?? sortedMoments.first?.files.values.first

        let sectionTitle = type.rawValue.capitalized

        return TeslaClip(
            folderURL: folderURL,
            title: "\(sectionTitle) • \(eventDate.formatted(date: .abbreviated, time: .shortened))",
            date: eventDate,
            type: type,
            thumbnailURL: thumbURL ?? fallbackThumb,
            moments: sortedMoments,
            durationSeconds: await clipDurationSeconds(for: sortedMoments, durationResolver: durationResolver)
        )
    }

    private nonisolated static func clipDurationSeconds(
        for moments: [TeslaMoment],
        durationResolver: DurationResolver
    ) async -> Double {
        var total = 0.0
        for moment in moments {
            guard let representativeURL = moment.files[.front] ?? moment.files.values.first else { continue }
            total += await durationResolver.duration(for: representativeURL)
        }
        return total
    }

    private nonisolated static func extractTimestamp(_ filename: String) -> String? {
        let pattern = #"(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) else { return nil }
        return (filename as NSString).substring(with: match.range(at: 1))
    }

    private nonisolated static func channelFromFilename(_ filename: String) -> CameraChannel? {
        let lower = filename.lowercased()
        if lower.contains("front")          { return .front }
        if lower.contains("back")           { return .back }
        if lower.contains("left_repeater")  { return .left_repeater }
        if lower.contains("right_repeater") { return .right_repeater }
        if lower.contains("left_pillar")    { return .left_pillar }
        if lower.contains("right_pillar")   { return .right_pillar }
        return nil
    }

    private nonisolated static func dateFromTimestamp(_ ts: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: ts)
    }
}

#Preview { ContentView() }
