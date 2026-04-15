import SwiftUI
import AVKit
import MapKit
import Combine
import AppKit

// MARK: - GPS Point (interpolated)

struct GPSPoint: Equatable {
    let latitude: Double
    let longitude: Double
    let heading: Double
}

// MARK: - GPS Trail Point

struct GPSTrailPoint {
    let seconds: Double
    let coordinate: CLLocationCoordinate2D
}

private struct ResolvedMapRouteSample {
    let seconds: Double
    let coordinate: CLLocationCoordinate2D
}

private func hasValidMapCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
    abs(coordinate.latitude) > 0.0001 || abs(coordinate.longitude) > 0.0001
}

private func resolvedMapRouteSamples(
    seiTimeline: [(seconds: Double, metadata: SeiMetadata)],
    gpsTrail: [GPSTrailPoint],
    from: Double = -.infinity,
    to: Double = .infinity
) -> [ResolvedMapRouteSample] {
    let fromSEI = seiTimeline
        .filter { $0.seconds >= from && $0.seconds <= to }
        .map {
            ResolvedMapRouteSample(
                seconds: $0.seconds,
                coordinate: CLLocationCoordinate2D(
                    latitude: $0.metadata.latitudeDeg,
                    longitude: $0.metadata.longitudeDeg
                )
            )
        }
        .filter { hasValidMapCoordinate($0.coordinate) }

    if fromSEI.count > 1 {
        return fromSEI
    }

    return gpsTrail
        .filter { $0.seconds >= from && $0.seconds <= to }
        .map { ResolvedMapRouteSample(seconds: $0.seconds, coordinate: $0.coordinate) }
        .filter { hasValidMapCoordinate($0.coordinate) }
}

private func visibleResolvedMapTrail(
    in route: [ResolvedMapRouteSample],
    upTo absoluteTime: Double
) -> [CLLocationCoordinate2D] {
    guard !route.isEmpty else { return [] }
    var lo = 0
    var hi = route.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if route[mid].seconds <= absoluteTime {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return route[0..<lo].map(\.coordinate)
}

// MARK: - View Mode

enum ViewMode: String, CaseIterable {
    case front        = "Front"
    case frontFocused = "Focus"
    case grid4        = "4 Cam"
    case gridAll      = "All Cams"
}

// MARK: - Map Style

enum MapStyleOption {
    case standard, satellite
}

// MARK: - SEI Load State

enum SEIState: Equatable {
    case idle
    case loading
    case loaded(Int)
    case unavailable
}

// MARK: - Playback Speed

enum PlaybackSpeed: Double, CaseIterable {
    case half  = 0.5
    case one   = 1.0
    case two   = 2.0
    case four  = 4.0

    var label: String {
        switch self {
        case .half: return "½×"
        case .one:  return "1×"
        case .two:  return "2×"
        case .four: return "4×"
        }
    }
}

// MARK: - CADisplayLink Driver (60/120fps tick publisher)

@MainActor
final class DisplayLinkDriver: ObservableObject {
    @Published private(set) var tick: UInt64 = 0
    private var link: CADisplayLink?

    func start() {
        guard link == nil else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let dl = screen.displayLink(target: self, selector: #selector(fire))
        dl.add(to: .main, forMode: .common)
        link = dl
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func fire() { tick &+= 1 }
}

// MARK: - VideoPlayerView

struct VideoPlayerView: View {
    let clip: TeslaClip

    @State private var players: [CameraChannel: AVPlayer] = [:]
    @State private var mainCamera: CameraChannel = .front
    @State private var viewMode: ViewMode = .front
    @State private var showMap = true
    @State private var hudOffset: CGSize = .zero
    @State private var hudOffsetAtDragStart: CGSize = .zero
    @State private var playbackSpeed: PlaybackSpeed = .one
    @State private var isFullScreen: Bool = false
    @State private var mapStyle: MapStyleOption = .standard
    @State private var mapFollowsVehicle: Bool = true
    @State private var showExportSheet = false

    @State private var seiTimeline: [(seconds: Double, metadata: SeiMetadata)] = []
    @State private var gpsTrail: [GPSTrailPoint] = []
    @State private var seiState: SEIState = .idle
    @State private var currentTelemetry: SeiMetadata? = nil
    @State private var interpolatedGPS: GPSPoint? = nil
    @State private var currentPlayerSeconds: Double = 0
    @State private var clipDuration: Double = 0

    @State private var keyMonitor: Any? = nil
    @State private var fullScreenObservers: [NSObjectProtocol] = []

    @StateObject private var displayLink = DisplayLinkDriver()

    private let grid4Channels: [CameraChannel] = [.front, .back, .left_repeater, .right_repeater]
    private let gridAllColumns = 2

    private var activeMainCamera: CameraChannel {
        (viewMode == .front || viewMode == .frontFocused) ? .front : mainCamera
    }

    var body: some View {
        VStack(spacing: 0) {
            modeToolbar

            GeometryReader { geo in
                let mapWidth    = min(max(geo.size.width * 0.22, 170), 280)
                let mapHeight   = mapWidth * 0.75
                let hudMaxWidth = min(340, max(170, geo.size.width - (showMap ? mapWidth + 24 : 0) - 36))

                ZStack {
                    videoContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Bottom-left: draggable telemetry HUD
                    CompactTelemetryHUD(
                        current: currentTelemetry,
                        seiState: seiState,
                        playerSeconds: currentPlayerSeconds,
                        clipStartDate: clip.date
                    )
                    .frame(maxWidth: hudMaxWidth, alignment: .leading)
                    .padding(10)
                    .padding(.bottom, 6)
                    .offset(hudOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                hudOffset = CGSize(
                                    width: hudOffsetAtDragStart.width + value.translation.width,
                                    height: hudOffsetAtDragStart.height + value.translation.height
                                )
                            }
                            .onEnded { _ in hudOffsetAtDragStart = hudOffset }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                    // Bottom-right: live map
                    if showMap {
                        LiveMapView(
                            gps: interpolatedGPS,
                            seiTimeline: seiTimeline,
                            gpsTrail: gpsTrail,
                            currentSeconds: currentPlayerSeconds,
                            mapStyle: mapStyle,
                            mapFollowsVehicle: mapFollowsVehicle
                        )
                        .frame(width: mapWidth, height: mapHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12), lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
                        .padding(Layout.chipSpacing * 2)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
            }

            // Speed graph — only when telemetry is loaded
            if case .loaded = seiState {
                SpeedGraphView(
                    seiTimeline: seiTimeline,
                    currentSeconds: currentPlayerSeconds,
                    totalDuration: clipDuration,
                    onSeek: { seconds in
                        let target = CMTime(seconds: seconds, preferredTimescale: 600)
                        for player in players.values {
                            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    }
                )
                .frame(height: 52)
                .background(.black)
            }

            masterControlBar
        }
        .background(.black)
        .onAppear {
            setupPlayersAndSEI()
            installKeyboardMonitor()
            installFullScreenObservers()
            displayLink.start()
        }
        .onDisappear {
            displayLink.stop()
            cleanupPlayers()
            removeKeyboardMonitor()
            removeFullScreenObservers()
        }
        .onReceive(displayLink.$tick) { tick in
            updateCurrentTime()
            updateTelemetry()
            updateMapGPS()
            if tick % 16 == 0 { synchronizeSecondaryPlayers() }
        }
        .onChange(of: viewMode)    { _, newMode in
            if newMode == .front || newMode == .frontFocused { mainCamera = .front }
            synchronizeSecondaryPlayers()
        }
        .sheet(isPresented: $showExportSheet) {
            CropExportSheet(
                clip: clip,
                viewMode: viewMode,
                players: players,
                seiTimeline: seiTimeline,
                gpsTrail: gpsTrail,
                totalDuration: clipDuration > 0 ? clipDuration : 60,
                mapStyle: mapStyle,
                mapFollowsVehicle: mapFollowsVehicle,
                showMap: showMap
            )
        }
    }

    // MARK: - Mode Toolbar

    private var modeToolbar: some View {
        HStack(spacing: 8) {
            speedPicker
            Spacer()
            modePills
            Spacer()
            mapControlsGroup
            cropExportButton
            shareButton
            fullScreenToggle
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var cropExportButton: some View {
        Button { showExportSheet = true } label: {
            Image(systemName: "scissors")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Crop & Export")
    }

    private var modePills: some View {
        HStack(spacing: 2) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                let isSelected = viewMode == mode
                Text(mode.rawValue)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        isSelected
                            ? AnyShapeStyle(Color.white.opacity(0.22))
                            : AnyShapeStyle(Color.clear),
                        in: Capsule()
                    )
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(.ui) { viewMode = mode } }
            }
        }
        .padding(4)
        .background(.white.opacity(0.07), in: Capsule())
    }

    private var speedPicker: some View {
        HStack(spacing: 2) {
            ForEach(PlaybackSpeed.allCases, id: \.rawValue) { speed in
                let isSelected = playbackSpeed == speed
                Text(speed.label)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        isSelected ? Color.white.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.hover) { playbackSpeed = speed }
                        applySpeedToAllPlayers(speed)
                    }
            }
        }
        .padding(4)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    // Map toggle + style toggle + follow toggle grouped together
    private var mapControlsGroup: some View {
        HStack(spacing: 4) {
            // Map on/off
            Button {
                withAnimation(.ui) { showMap.toggle() }
            } label: {
                Image(systemName: showMap ? "map.fill" : "map")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(showMap ? Color.white : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        showMap ? AnyShapeStyle(Color.blue.opacity(0.35)) : AnyShapeStyle(Color.white.opacity(0.07)),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)

            if showMap {
                // Satellite / standard toggle
                Button {
                    withAnimation(.hover) {
                        mapStyle = mapStyle == .standard ? .satellite : .standard
                    }
                } label: {
                    Image(systemName: mapStyle == .satellite ? "globe.europe.africa.fill" : "globe.europe.africa")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(mapStyle == .satellite ? "Switch to Standard" : "Switch to Satellite")

                // Follow / overview toggle
                Button {
                    withAnimation(.ui) { mapFollowsVehicle.toggle() }
                } label: {
                    Image(systemName: mapFollowsVehicle ? "location.fill" : "location.slash.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(mapFollowsVehicle ? Color.blue : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(mapFollowsVehicle ? "Overview (show full route)" : "Follow vehicle")
            }
        }
    }

    private var shareButton: some View {
        Button {
            shareCurrentClip()
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Share clip videos")
    }

    private func shareCurrentClip() {
        // Collect MP4s for all available cameras, sorted by channel then timestamp
        let mp4s: [URL] = clip.moments
            .sorted { $0.timestamp < $1.timestamp }
            .flatMap { moment in
                CameraChannel.allCases.compactMap { moment.files[$0] }
            }

        let items: [Any] = mp4s.isEmpty
            ? (clip.folderURL.map { [$0] } ?? [])
            : mp4s

        guard !items.isEmpty else { return }

        let picker = NSSharingServicePicker(items: items)
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
    }

    private var fullScreenToggle: some View {
        Button {
            NSApp.mainWindow?.toggleFullScreen(nil)
        } label: {
            Image(systemName: isFullScreen
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: [.command])
        .help(isFullScreen ? "Exit Full Screen" : "Enter Full Screen")
    }

    // MARK: - Video Content

    @ViewBuilder
    private var videoContent: some View {
        switch viewMode {
        case .front:        singleCameraView(channel: .front)
        case .frontFocused: frontFocusedLayout
        case .grid4:        gridLayout(channels: grid4Channels, columns: 2)
        case .gridAll:      gridLayout(channels: Array(CameraChannel.allCases), columns: gridAllColumns)
        }
    }

    private func singleCameraView(channel: CameraChannel) -> some View {
        Group {
            if let player = players[channel] {
                PlayerSurfaceView(player: player)
                    .aspectRatio(Layout.teslaAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                noCameraView(channel: channel)
            }
        }
        .background(.black)
    }

    private var frontFocusedLayout: some View {
        GeometryReader { geo in
            let spacing: CGFloat = Layout.gridCellSpacing
            let usableHeight = max(geo.size.height - spacing, 0)
            let stripHeight  = min(max(usableHeight * 0.22, 90), 160)
            let mainHeight   = max(usableHeight - stripHeight, 0)

            VStack(spacing: spacing) {
                ZStack(alignment: .topLeading) {
                    if let player = players[.front] {
                        PlayerSurfaceView(player: player)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    } else {
                        Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    cameraLabel(displayName(.front))
                }
                .frame(height: mainHeight)

                HStack(spacing: spacing) {
                    ForEach(CameraChannel.allCases.filter { $0 != .front }, id: \.self) { channel in
                        ZStack(alignment: .bottomLeading) {
                            if let player = players[channel] {
                                PlayerSurfaceView(player: player)
                                    .aspectRatio(Layout.teslaAspect, contentMode: .fit)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                            } else {
                                Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            cameraLabel(displayName(channel))
                        }
                    }
                }
                .frame(height: stripHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black)
    }

    private func gridLayout(channels: [CameraChannel], columns: Int) -> some View {
        let rows = channels.chunked(into: columns)
        return GeometryReader { geo in
            let spacing: CGFloat = Layout.gridCellSpacing
            let cellW = ((geo.size.width  - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
            let cellH = ((geo.size.height - spacing * CGFloat(rows.count  - 1)) / CGFloat(rows.count)).rounded(.down)

            VStack(spacing: spacing) {
                ForEach(rows.indices, id: \.self) { rowIdx in
                    let row = rows[rowIdx]
                    HStack(spacing: spacing) {
                        if row.count < columns { Spacer(minLength: 0) }
                        ForEach(row, id: \.self) { channel in
                            let isActive = mainCamera == channel
                            ZStack(alignment: .bottomLeading) {
                                if let player = players[channel] {
                                    PlayerSurfaceView(player: player)
                                        .frame(width: cellW, height: cellH)
                                } else {
                                    noCameraView(channel: channel)
                                        .frame(width: cellW, height: cellH)
                                }
                                cameraLabel(displayName(channel))
                                if isActive {
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color.blue.opacity(0.8), lineWidth: 2)
                                }
                            }
                            .frame(width: cellW, height: cellH).clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(.hover) { mainCamera = channel } }
                        }
                        if row.count < columns { Spacer(minLength: 0) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    // MARK: - Master Control Bar

    private var masterControlBar: some View {
        Group {
            if let player = players[activeMainCamera] {
                CustomControlBar(player: player)
            } else {
                HStack {
                    Spacer()
                    Label("No video for this camera", systemImage: "video.slash")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(height: 44)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    // MARK: - Camera Label

    private func cameraLabel(_ name: String) -> some View {
        Text(name).font(.caption2.bold()).foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .glassEffect(.clear, in: .rect(cornerRadius: 4))
        .padding(6)
    }

    private func displayName(_ channel: CameraChannel) -> String {
        channel.rawValue.uppercased().replacingOccurrences(of: "_", with: " ")
    }

    private func noCameraView(channel: CameraChannel) -> some View {
        Color.black.overlay(
            VStack(spacing: 6) {
                Image(systemName: "video.slash").font(.title2).foregroundStyle(.tertiary)
                Text(displayName(channel)).font(.caption2).foregroundStyle(.quaternary)
            }
        )
    }

    // MARK: - Setup & Teardown

    private func setupPlayersAndSEI() {
        let sortedMoments = clip.moments.sorted { $0.timestamp < $1.timestamp }

        for channel in CameraChannel.allCases {
            let urls = sortedMoments.compactMap { $0.files[channel] }
            if let player = makeStitchedPlayer(from: urls) {
                players[channel] = player
            }
        }
        // Async duration load — AVMutableComposition.duration returns zero synchronously
        if let master = players[.front] ?? players.values.first {
            Task {
                if let d = try? await master.currentItem?.asset.load(.duration) {
                    let secs = CMTimeGetSeconds(d)
                    if secs.isFinite && secs > 0 {
                        await MainActor.run { clipDuration = max(clipDuration, secs) }
                    }
                }
            }
        }

        let frontSEIURLs = sortedMoments.compactMap { $0.files[.front] }
        let seiURLs = frontSEIURLs.isEmpty
            ? (sortedMoments.first?.files.values.first).map { [$0] } ?? []
            : frontSEIURLs

        if !seiURLs.isEmpty {
            seiState = .loading
            Task.detached(priority: .userInitiated) {
                let parsed = await TeslaSEIParser.parseSEI(from: seiURLs, frameRate: 30.0)
                let trail = Self.buildGPSTrail(from: parsed)
                await MainActor.run {
                    seiTimeline = parsed
                    gpsTrail    = trail
                    seiState    = parsed.isEmpty ? .unavailable : .loaded(parsed.count)
                    if let last = parsed.last { clipDuration = max(clipDuration, last.seconds) }
                }
            }
        } else {
            seiState = .unavailable
        }
    }

    /// Downsample SEI timeline to ~1 GPS point per second, filtering no-fix frames.
    private nonisolated static func buildGPSTrail(
        from timeline: [(seconds: Double, metadata: SeiMetadata)]
    ) -> [GPSTrailPoint] {
        var result: [GPSTrailPoint] = []
        var lastSecond: Int = -1
        for frame in timeline {
            let lat = frame.metadata.latitudeDeg
            let lon = frame.metadata.longitudeDeg
            guard abs(lat) > 0.0001 || abs(lon) > 0.0001 else { continue }
            let sec = Int(frame.seconds)
            guard sec != lastSecond else { continue }
            lastSecond = sec
            result.append(GPSTrailPoint(
                seconds: frame.seconds,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
            ))
        }
        return result
    }

    private func cleanupPlayers() {
        players.values.forEach { $0.pause() }
    }

    private func makeStitchedPlayer(from urls: [URL]) -> AVPlayer? {
        guard !urls.isEmpty else { return nil }
        if urls.count == 1 { return AVPlayer(url: urls[0]) }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return AVPlayer(url: urls[0]) }

        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursor = CMTime.zero
        var hasVideo = false

        for url in urls {
            let asset = AVURLAsset(url: url)
            let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
            guard timeRange.duration.isNumeric && timeRange.duration > .zero else { continue }

            if let sourceVideo = asset.tracks(withMediaType: .video).first {
                do { try videoTrack.insertTimeRange(timeRange, of: sourceVideo, at: cursor); hasVideo = true }
                catch { continue }
            } else { continue }

            if let sourceAudio = asset.tracks(withMediaType: .audio).first, let audioTrack {
                try? audioTrack.insertTimeRange(timeRange, of: sourceAudio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, timeRange.duration)
        }

        return hasVideo
            ? AVPlayer(playerItem: AVPlayerItem(asset: composition))
            : AVPlayer(url: urls[0])
    }

    private func applySpeedToAllPlayers(_ speed: PlaybackSpeed) {
        for player in players.values where player.timeControlStatus == .playing {
            player.rate = Float(speed.rawValue)
        }
    }

    private func synchronizeSecondaryPlayers() {
        guard let master = players[activeMainCamera] ?? players[.front] else { return }

        if master.timeControlStatus == .playing, master.rate != Float(playbackSpeed.rawValue) {
            master.rate = Float(playbackSpeed.rawValue)
        }

        if viewMode == .front {
            for (channel, player) in players where channel != .front {
                if player.rate != 0 { player.pause() }
            }
            return
        }

        let masterTime = master.currentTime()
        guard masterTime.isNumeric else { return }
        let masterSeconds = CMTimeGetSeconds(masterTime)
        guard masterSeconds.isFinite else { return }
        let isMasterPlaying = master.timeControlStatus == .playing
        let driftThreshold: Double = isMasterPlaying ? 0.12 : 0.03

        for player in players.values {
            if player === master { continue }
            let delta = abs(CMTimeGetSeconds(player.currentTime()) - masterSeconds)
            if delta > driftThreshold {
                player.seek(to: masterTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if isMasterPlaying {
                if player.timeControlStatus != .playing {
                    player.playImmediately(atRate: Float(playbackSpeed.rawValue))
                } else if player.rate != Float(playbackSpeed.rawValue) {
                    player.rate = Float(playbackSpeed.rawValue)
                }
            } else if player.rate != 0 {
                player.pause()
            }
        }
    }

    private func updateCurrentTime() {
        guard let frontPlayer = players[.front] else { return }
        let t = CMTimeGetSeconds(frontPlayer.currentTime())
        guard t.isFinite else { return }
        currentPlayerSeconds = t
    }

    private func updateTelemetry() {
        guard !seiTimeline.isEmpty else { return }
        currentTelemetry = nearestSEIFrame(to: currentPlayerSeconds, in: seiTimeline)?.metadata
    }

    // MARK: - Sub-frame GPS interpolation (15 fps)

    private func updateMapGPS() {
        guard !seiTimeline.isEmpty else { return }
        guard let player = players[activeMainCamera] ?? players[.front] else { return }
        let t = CMTimeGetSeconds(player.currentTime())
        guard t.isFinite else { return }

        var lo = 0, hi = seiTimeline.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if seiTimeline[mid].seconds < t { lo = mid + 1 } else { hi = mid }
        }
        let nextIdx = lo

        let point: GPSPoint
        if nextIdx == 0 {
            let m = seiTimeline[0].metadata
            point = GPSPoint(latitude: m.latitudeDeg, longitude: m.longitudeDeg, heading: m.headingDeg)
        } else if nextIdx >= seiTimeline.count {
            let m = seiTimeline.last!.metadata
            point = GPSPoint(latitude: m.latitudeDeg, longitude: m.longitudeDeg, heading: m.headingDeg)
        } else {
            let prev  = seiTimeline[nextIdx - 1]
            let next  = seiTimeline[nextIdx]
            let span  = next.seconds - prev.seconds
            let alpha = span > 0 ? min(1.0, max(0.0, (t - prev.seconds) / span)) : 0.0
            let lat   = prev.metadata.latitudeDeg  + alpha * (next.metadata.latitudeDeg  - prev.metadata.latitudeDeg)
            let lon   = prev.metadata.longitudeDeg + alpha * (next.metadata.longitudeDeg - prev.metadata.longitudeDeg)
            let hdg   = lerpAngle(prev.metadata.headingDeg, next.metadata.headingDeg, alpha)
            point = GPSPoint(latitude: lat, longitude: lon, heading: hdg)
        }

        guard abs(point.latitude) > 0.0001 || abs(point.longitude) > 0.0001 else {
            interpolatedGPS = nil; return
        }
        interpolatedGPS = point
    }

    private func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var diff = b - a
        while diff >  180 { diff -= 360 }
        while diff < -180 { diff += 360 }
        return a + t * diff
    }

    // MARK: - Keyboard (← → space)

    private func installKeyboardMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 123: self.stepFrame(by: -1); return nil   // ← left arrow
            case 124: self.stepFrame(by:  1); return nil   // → right arrow
            case 49:  self.togglePlayPause(); return nil   // space
            default:  return event
            }
        }
    }

    private func removeKeyboardMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func stepFrame(by direction: Int) {
        guard let master = players[activeMainCamera] ?? players[.front] else { return }
        master.pause()
        let current = CMTimeGetSeconds(master.currentTime())
        let stepped = max(0, current + Double(direction) / 30.0)
        let target  = CMTime(seconds: stepped, preferredTimescale: 600)
        master.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        for (channel, player) in players where channel != activeMainCamera {
            player.pause()
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func togglePlayPause() {
        guard let master = players[activeMainCamera] ?? players[.front] else { return }
        if master.timeControlStatus == .playing {
            master.pause()
        } else {
            master.playImmediately(atRate: Float(playbackSpeed.rawValue))
        }
    }

    // MARK: - Full-Screen Observers

    private func installFullScreenObservers() {
        let enter = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: nil,
            queue: .main
        ) { _ in isFullScreen = true }

        let exit = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil,
            queue: .main
        ) { _ in isFullScreen = false }

        fullScreenObservers = [enter, exit]
    }

    private func removeFullScreenObservers() {
        fullScreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        fullScreenObservers = []
    }
}

// MARK: - Speed Graph

struct SpeedGraphView: View {
    let seiTimeline: [(seconds: Double, metadata: SeiMetadata)]
    let currentSeconds: Double
    let totalDuration: Double
    var onSeek: ((Double) -> Void)? = nil

    // Pre-computed cache — rebuilt only when seiTimeline or size changes, not on every frame.
    private struct GraphCache: Equatable {
        let id: Int                  // stable key: seiTimeline.count ^ Int(totalDuration * 1000)
        let fillPath: Path
        let linePath: Path
        let gForcePath: Path
        let brakeTicks: [CGFloat]    // normalized x fractions [0..1]
        let maxSpeed: Double
        let maxGForce: Double
        static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    }

    // Background canvas — only re-drawn when GraphCache changes (not on currentSeconds ticks).
    private struct BackgroundGraph: View, Equatable {
        let cache: GraphCache
        static func == (l: Self, r: Self) -> Bool { l.cache == r.cache }

        var body: some View {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                ctx.fill(cache.fillPath, with: .color(.blue.opacity(0.12)))
                ctx.stroke(cache.linePath, with: .color(.blue.opacity(0.75)), lineWidth: 1.5)
                ctx.stroke(cache.gForcePath, with: .color(.orange.opacity(0.85)), lineWidth: 1.2)
                for xFrac in cache.brakeTicks {
                    let x = xFrac * size.width
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: size.height - 3))
                    tick.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(tick, with: .color(.red.opacity(0.7)), lineWidth: 1)
                }
                let maxMph   = Int(cache.maxSpeed * 2.237)
                let maxLabel = ctx.resolve(Text("\(maxMph) mph max").font(.system(size: 8)).foregroundStyle(Color.white.opacity(0.3)))
                let maxW     = maxLabel.measure(in: size).width
                ctx.draw(maxLabel, at: CGPoint(x: size.width - maxW - 4, y: 4), anchor: .topLeading)

                let gLabel = ctx.resolve(
                    Text(String(format: "%.2fG max", cache.maxGForce))
                        .font(.system(size: 8))
                        .foregroundStyle(Color.orange.opacity(0.65))
                )
                let gW = gLabel.measure(in: size).width
                ctx.draw(gLabel, at: CGPoint(x: size.width - gW - 4, y: 14), anchor: .topLeading)
            }
        }
    }

    // Playhead canvas — cheap, re-draws every frame (just a line + O(log n) label lookup).
    private struct PlayheadCanvas: View {
        let currentSeconds: Double
        let totalDuration: Double
        let seiTimeline: [(seconds: Double, metadata: SeiMetadata)]

        var body: some View {
            Canvas { ctx, size in
                guard totalDuration > 0 else { return }
                let playX = min(CGFloat(currentSeconds / totalDuration) * size.width, size.width - 1)
                var ph = Path()
                ph.move(to: CGPoint(x: playX, y: 0))
                ph.addLine(to: CGPoint(x: playX, y: size.height))
                ctx.stroke(ph, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
                if let closest = nearestSEIFrame(to: currentSeconds, in: seiTimeline) {
                    let mph    = Int(closest.metadata.vehicleSpeedMps * 2.237)
                    let gForce = combinedGForce(for: closest.metadata)
                    let label  = ctx.resolve(
                        Text("\(mph) mph  •  \(String(format: "%.2fG", gForce))")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.8))
                    )
                    let labelW = label.measure(in: size).width
                    ctx.draw(label, at: CGPoint(x: min(max(playX + 3, 2), size.width - labelW - 2), y: 4), anchor: .topLeading)
                }
            }
        }
    }

    @State private var cache: GraphCache? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let cache {
                    BackgroundGraph(cache: cache).equatable()
                }
                PlayheadCanvas(
                    currentSeconds: currentSeconds,
                    totalDuration: totalDuration,
                    seiTimeline: seiTimeline
                )
            }
            .overlay(alignment: .bottomLeading) {
                Text("SPEED / G")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.leading, 4).padding(.bottom, 3)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard totalDuration > 0 else { return }
                        let fraction = max(0.0, min(1.0, value.location.x / geo.size.width))
                        onSeek?(fraction * totalDuration)
                    }
            )
            .onAppear                        { rebuildCache(size: geo.size) }
            .onChange(of: geo.size)          { _, s  in rebuildCache(size: s) }
            .onChange(of: seiTimeline.count) { _, _  in rebuildCache(size: geo.size) }
            .onChange(of: totalDuration)     { _, _  in rebuildCache(size: geo.size) }
        }
    }

    private func rebuildCache(size: CGSize) {
        guard size.width > 0, size.height > 0, !seiTimeline.isEmpty, totalDuration > 0 else { return }
        let sampled  = sampledSEITimeline(maxPoints: max(Int(size.width * 2), 240))
        let speeds   = sampled.map { $0.metadata.vehicleSpeedMps }
        let gForces  = sampled.map { Self.combinedGForce(for: $0.metadata) }
        let maxSpeed: Double = max(Double(speeds.max() ?? 1.0), 1.0)
        let maxGForce: Double = max(gForces.max() ?? 0.2, 0.2)
        let pad: CGFloat = 6

        func speedPoint(_ f: (seconds: Double, metadata: SeiMetadata)) -> CGPoint {
            let x = CGFloat(f.seconds / totalDuration) * size.width
            let speedRatio = CGFloat(Double(f.metadata.vehicleSpeedMps) / maxSpeed)
            let graphHeight = size.height - pad * 2
            let y = size.height - pad - speedRatio * graphHeight
            return CGPoint(x: x, y: y)
        }

        func gPoint(_ f: (seconds: Double, metadata: SeiMetadata)) -> CGPoint {
            let x = CGFloat(f.seconds / totalDuration) * size.width
            let gRatio = CGFloat(Self.combinedGForce(for: f.metadata) / maxGForce)
            let graphHeight = size.height - pad * 2
            let y = size.height - pad - gRatio * graphHeight
            return CGPoint(x: x, y: y)
        }

        var fill = Path()
        fill.move(to: CGPoint(x: 0, y: size.height))
        sampled.forEach { fill.addLine(to: speedPoint($0)) }
        if let last = sampled.last { fill.addLine(to: CGPoint(x: speedPoint(last).x, y: size.height)) }
        fill.closeSubpath()

        var line = Path()
        sampled.enumerated().forEach { i, f in
            i == 0 ? line.move(to: speedPoint(f)) : line.addLine(to: speedPoint(f))
        }

        var gLine = Path()
        sampled.enumerated().forEach { i, f in
            i == 0 ? gLine.move(to: gPoint(f)) : gLine.addLine(to: gPoint(f))
        }

        let ticks = sampled.filter { $0.metadata.brakeApplied }.map { CGFloat($0.seconds / totalDuration) }
        let cid   = seiTimeline.count ^ Int(totalDuration * 1000)
        cache = GraphCache(
            id: cid,
            fillPath: fill,
            linePath: line,
            gForcePath: gLine,
            brakeTicks: ticks,
            maxSpeed: maxSpeed,
            maxGForce: maxGForce
        )
    }

    private func sampledSEITimeline(maxPoints: Int) -> [(seconds: Double, metadata: SeiMetadata)] {
        guard seiTimeline.count > maxPoints else { return seiTimeline }
        let step = max(1, seiTimeline.count / maxPoints)
        var sampled = stride(from: 0, to: seiTimeline.count, by: step).map { seiTimeline[$0] }
        if let last = seiTimeline.last, sampled.last?.seconds != last.seconds { sampled.append(last) }
        return sampled
    }

    private static func combinedGForce(for metadata: SeiMetadata) -> Double {
        let lat = sqrt(
            pow(metadata.linearAccelerationMps2X, 2) +
            pow(metadata.linearAccelerationMps2Y, 2)
        ) / 9.81
        let lon = abs(metadata.linearAccelerationMps2Z) / 9.81
        return sqrt(lat * lat + lon * lon)
    }
}

// MARK: - Compact Telemetry HUD

struct CompactTelemetryHUD: View {
    let current: SeiMetadata?
    let seiState: SEIState
    let playerSeconds: Double
    let clipStartDate: Date
    var showAutopilotBadge: Bool = true

    var body: some View {
        switch seiState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.65)
                Text("Loading telemetry…").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassEffect(.clear, in: .rect(cornerRadius: 16))

        case .unavailable:
            Text("No telemetry data")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.clear, in: .rect(cornerRadius: 16))

        case .loaded:
            mainHUD
        }
    }

    private var mainHUD: some View {
        VStack(spacing: 5) {
            // Row 1: time / speed / date / autopilot
            HStack(alignment: .firstTextBaseline) {
                timeDisplay
                Spacer()
                speedDisplay
                Spacer()
                dateDisplay
                if showAutopilotBadge,
                   let label = apShort(current?.autopilotState), !label.isEmpty {
                    apBadge(label).padding(.leading, 6)
                }
            }

            // Row 2: gear / steering / brake / blinkers
            HStack(spacing: 10) {
                activeGearDisplay
                steeringDisplay
                Spacer()
                brakeDisplay
                leftBlinker
                rightBlinker
            }

            // Row 3: accelerator pedal
            acceleratorPedalDisplay
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.15), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Row 1

    private var timeDisplay: some View {
        Text(currentDate.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()))
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
    }

    private var dateDisplay: some View {
        Text(currentDate.formatted(.dateTime.month(.abbreviated).day()))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var speedDisplay: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(Int((current?.vehicleSpeedMps ?? 0) * 2.237))")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text("mph")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    // MARK: Row 2

    private var activeGearDisplay: some View {
        Text(currentGear)
            .font(.system(size: 18, weight: .bold, design: .monospaced))
            .foregroundStyle(.black)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(gearColor, in: RoundedRectangle(cornerRadius: 8))
            .animation(.hover, value: current?.gearState)
    }

    private var currentGear: String {
        switch current?.gearState {
        case .park:    return "P"
        case .reverse: return "R"
        case .neutral: return "N"
        case .drive:   return "D"
        default:       return "–"
        }
    }

    private var gearColor: Color {
        switch current?.gearState {
        case .park:    return .gray
        case .drive:   return .green
        case .reverse: return .red
        case .neutral: return .yellow
        default:       return .gray
        }
    }

    private var steeringDisplay: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.25), lineWidth: 2)
                    .frame(width: 32, height: 32)
                Image(systemName: "steeringwheel")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(Double(current?.steeringWheelAngle ?? 0)))
                    .animation(.easeOut(duration: 0.18), value: current?.steeringWheelAngle)
            }
            Text(String(format: "%+.0f°", Double(current?.steeringWheelAngle ?? 0)))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    private var brakeDisplay: some View {
        let isPressed = current?.brakeApplied ?? false

        return ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(isPressed ? Color.red.opacity(0.92) : Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .frame(width: 28, height: 20)

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(isPressed ? Color.white.opacity(0.95) : Color.white.opacity(0.35))
                        .frame(width: 1.5, height: 10)
                }
            }
        }
        .shadow(color: isPressed ? .red.opacity(0.24) : .clear, radius: 8)
        .scaleEffect(isPressed ? 1 : 0.96)
        .animation(.easeOut(duration: 0.12), value: isPressed)
    }

    private var leftBlinker:  some View { blinkerIndicator(direction: .left,  isActive: current?.blinkerOnLeft  ?? false) }
    private var rightBlinker: some View { blinkerIndicator(direction: .right, isActive: current?.blinkerOnRight ?? false) }

    private enum BlinkerDirection { case left, right }

    private var isBlinkOnPhase: Bool {
        let phaseIndex = Int((max(0, playerSeconds) / 0.33).rounded(.down))
        return phaseIndex.isMultiple(of: 2)
    }

    private func blinkerIndicator(direction: BlinkerDirection, isActive: Bool) -> some View {
        let isOnPhase  = isActive && isBlinkOnPhase
        let symbolName = direction == .left ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill"
        return Image(systemName: symbolName)
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(isOnPhase ? Color.black : Color.white.opacity(0.55))
            .frame(width: 22, height: 16)
            .background(Capsule().fill(isOnPhase ? Color.yellow : Color.white.opacity(0.12)))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            .scaleEffect(isOnPhase ? 1.0 : 0.94)
            .animation(.easeInOut(duration: 0.08), value: isOnPhase)
    }

    // MARK: Row 3 — Accelerator

    private var acceleratorPedalDisplay: some View {
        let isPressed = Double(current?.acceleratorPedalPosition ?? 0) > 0.05

        return HStack {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPressed ? Color.blue.opacity(0.85) : Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .frame(width: 22, height: 28)

                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(isPressed ? Color.white.opacity(0.92) : Color.white.opacity(0.35))
                            .frame(width: 10, height: 1.5)
                    }
                }
            }
            .shadow(color: isPressed ? .blue.opacity(0.28) : .clear, radius: 8)
            .scaleEffect(isPressed ? 1 : 0.96)
            .animation(.easeOut(duration: 0.12), value: isPressed)

            Spacer()
        }
    }

    // MARK: Autopilot Badge

    private func apBadge(_ label: String) -> some View {
        Text(label)
            .font(.caption2.bold())
            .foregroundStyle(.blue)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.blue.opacity(0.25), in: Capsule())
    }

    // MARK: Helpers

    private var currentDate: Date {
        playerSeconds.isFinite ? clipStartDate.addingTimeInterval(playerSeconds) : clipStartDate
    }

    private func apShort(_ a: SeiMetadata.AutopilotState?) -> String? {
        switch a {
        case .selfDriving: return "FSD"
        case .autosteer:   return "AP"
        case .tacc:        return "TACC"
        default:           return nil
        }
    }
}

// MARK: - Custom Control Bar

struct CustomControlBar: View {
    let player: AVPlayer

    @State private var isPlaying:   Bool   = false
    @State private var currentTime: Double = 0
    @State private var duration:    Double = 1
    @State private var isScrubbing: Bool   = false
    @State private var timeObserverToken: Any?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isPlaying ? player.pause() : player.play()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            Text(formatTime(currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            VideoScrubber(
                value: $currentTime,
                isScrubbing: $isScrubbing,
                duration: duration,
                onScrubEnded: { val in
                    let t = CMTime(seconds: val, preferredTimescale: 600)
                    player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        isScrubbing = false
                    }
                }
            )

            Text(formatTime(duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadDuration()
            startObservingPlayerTime()
        }
        .onDisappear { stopObservingPlayerTime() }
        .onChange(of: ObjectIdentifier(player)) { _, _ in
            stopObservingPlayerTime()
            currentTime = 0
            isScrubbing = false
            loadDuration()
            startObservingPlayerTime()
        }
    }

    private func loadDuration() {
        if let item = player.currentItem {
            let d = CMTimeGetSeconds(item.asset.duration)
            if d.isFinite && d > 0 { duration = d; return }
        }
        Task {
            if let d = try? await player.currentItem?.asset.load(.duration) {
                let secs = CMTimeGetSeconds(d)
                if secs.isFinite && secs > 0 { await MainActor.run { duration = secs } }
            }
        }
    }

    private func formatTime(_ s: Double) -> String {
        guard s.isFinite && s >= 0 else { return "00:00" }
        let total = Int(s)
        let h = total / 3600; let m = (total % 3600) / 60; let sec = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }

    private func startObservingPlayerTime() {
        guard timeObserverToken == nil else { return }
        let interval = CMTime(value: 1, timescale: 60)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            isPlaying = player.timeControlStatus == .playing
            guard !isScrubbing else { return }
            let t = CMTimeGetSeconds(time)
            if t.isFinite { currentTime = t }
        }
    }

    private func stopObservingPlayerTime() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }
}

// MARK: - VideoScrubber (NSSlider wrapper)

struct VideoScrubber: NSViewRepresentable {
    @Binding var value: Double
    @Binding var isScrubbing: Bool
    let duration: Double
    var onScrubEnded: (Double) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> ScrubNSSlider {
        let slider = ScrubNSSlider()
        slider.minValue    = 0
        slider.maxValue    = max(duration, 1)
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.sliderMoved(_:))
        slider.onScrubBegan = { context.coordinator.began() }
        slider.onScrubEnded = { val in context.coordinator.ended(val) }
        return slider
    }

    func updateNSView(_ nsView: ScrubNSSlider, context: Context) {
        nsView.maxValue = max(duration, 1)
        if !nsView.isTracking && !isScrubbing {
            nsView.doubleValue = value
        }
    }

    final class Coordinator: NSObject {
        var parent: VideoScrubber
        init(parent: VideoScrubber) { self.parent = parent }

        func began() { parent.isScrubbing = true }

        func ended(_ val: Double) {
            parent.value = val
            parent.onScrubEnded(val)
        }

        @objc func sliderMoved(_ sender: ScrubNSSlider) {
            parent.value = sender.doubleValue
        }
    }
}

// MARK: - ScrubNSSlider

final class ScrubNSSlider: NSSlider {
    var onScrubBegan: (() -> Void)?
    var onScrubEnded: ((Double) -> Void)?
    private(set) var isTracking = false

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        onScrubBegan?()
        super.mouseDown(with: event)
        isTracking = false
        onScrubEnded?(doubleValue)
    }
}

// MARK: - PlayerSurfaceView

struct PlayerSurfaceView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerSurfaceNSView {
        let view = PlayerSurfaceNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerSurfaceNSView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class PlayerSurfaceNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); playerLayer.frame = bounds }
}

// MARK: - Live Map Overlay

struct LiveMapView: View {
    let gps: GPSPoint?
    let seiTimeline: [(seconds: Double, metadata: SeiMetadata)]
    let gpsTrail: [GPSTrailPoint]
    let currentSeconds: Double
    let mapStyle: MapStyleOption
    let mapFollowsVehicle: Bool

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasSetInitialPosition = false

    private var routeSamples: [ResolvedMapRouteSample] {
        resolvedMapRouteSamples(seiTimeline: seiTimeline, gpsTrail: gpsTrail)
    }

    private var visibleTrail: [CLLocationCoordinate2D] {
        visibleResolvedMapTrail(in: routeSamples, upTo: currentSeconds)
    }

    var body: some View {
        Group {
            if let gps {
                let coord = CLLocationCoordinate2D(latitude: gps.latitude, longitude: gps.longitude)
                Map(position: $cameraPosition) {
                    if visibleTrail.count > 1 {
                        MapPolyline(coordinates: visibleTrail)
                            .stroke(.blue.opacity(0.6), lineWidth: 3)
                    }
                    Annotation("", coordinate: coord, anchor: .center) {
                        carMarker(heading: gps.heading)
                    }
                }
                .mapStyle(mapStyle == .satellite ? .imagery : .standard)
                .mapControls { }
                .onChange(of: gps) { _, newGPS in
                    guard mapFollowsVehicle else { return }
                    moveCamera(to: newGPS, animated: hasSetInitialPosition)
                }
                .onChange(of: mapFollowsVehicle) { _, follows in
                    if follows {
                        hasSetInitialPosition = false
                        moveCamera(to: gps, animated: true)
                    } else {
                        fitTrailBounds()
                    }
                }
                .onAppear {
                    if mapFollowsVehicle {
                        moveCamera(to: gps, animated: false)
                    } else {
                        fitTrailBounds()
                    }
                }
            } else {
                ZStack {
                    Color.black.opacity(0.4)
                    VStack(spacing: 6) {
                        Image(systemName: "location.slash.fill").font(.title2).foregroundStyle(.tertiary)
                        Text("No GPS Signal").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func carMarker(heading: Double) -> some View {
        ZStack {
            Circle().fill(.blue.opacity(0.25)).frame(width: 32, height: 32)
            Circle().fill(.blue).frame(width: 14, height: 14)
                .overlay(
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                )
        }
        .rotationEffect(.degrees(heading))
        .animation(.mapFrame, value: heading)
    }

    private func moveCamera(to gps: GPSPoint, animated: Bool) {
        let coord = CLLocationCoordinate2D(latitude: gps.latitude, longitude: gps.longitude)
        let newPosition = MapCameraPosition.camera(
            MapCamera(centerCoordinate: coord, distance: 350, heading: 0, pitch: 0)
        )

        let isSeeked: Bool
        if animated, let currentCamera = cameraPosition.camera {
            let dLat = coord.latitude  - currentCamera.centerCoordinate.latitude
            let dLon = coord.longitude - currentCamera.centerCoordinate.longitude
            isSeeked = sqrt(dLat * dLat + dLon * dLon) * 111_000 > 80
        } else {
            isSeeked = false
        }

        if animated && !isSeeked {
            withAnimation(.mapFrame) { cameraPosition = newPosition }
        } else {
            cameraPosition = newPosition
            hasSetInitialPosition = true
        }
    }

    private func fitTrailBounds() {
        let coords = routeSamples.map(\.coordinate)
        guard !coords.isEmpty else { return }
        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }
        let center = CLLocationCoordinate2D(
            latitude:  (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta:  max(0.01, (lats.max()! - lats.min()!) * 1.3),
            longitudeDelta: max(0.01, (lons.max()! - lons.min()!) * 1.3)
        )
        withAnimation(.ui) {
            cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
        }
        hasSetInitialPosition = true
    }
}

// MARK: - Array Helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Export Error

enum ExportError: LocalizedError {
    case noVideoTracks
    case exportSessionFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTracks:         return "No video tracks found for the selected view mode"
        case .exportSessionFailed:   return "Could not create export session"
        case .exportFailed(let msg): return msg
        }
    }
}

// MARK: - Crop & Export Sheet

struct CropExportSheet: View {
    let clip: TeslaClip
    let viewMode: ViewMode
    let players: [CameraChannel: AVPlayer]
    let seiTimeline: [(seconds: Double, metadata: SeiMetadata)]
    let gpsTrail: [GPSTrailPoint]
    let totalDuration: Double
    let mapStyle: MapStyleOption
    let mapFollowsVehicle: Bool
    let showMap: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var inPoint: Double = 0
    @State private var outPoint: Double
    @State private var isExporting = false
    @State private var exportProgress: Float = 0
    @State private var exportError: String? = nil
    @State private var exportDone = false
    @State private var exportShowsMap: Bool
    @State private var exportShowsGraph: Bool = true
    @State private var exportShowsFSDBadge: Bool = true

    init(clip: TeslaClip, viewMode: ViewMode, players: [CameraChannel: AVPlayer],
         seiTimeline: [(seconds: Double, metadata: SeiMetadata)],
         gpsTrail: [GPSTrailPoint], totalDuration: Double,
         mapStyle: MapStyleOption, mapFollowsVehicle: Bool, showMap: Bool) {
        self.clip = clip
        self.viewMode = viewMode
        self.players = players
        self.seiTimeline = seiTimeline
        self.gpsTrail = gpsTrail
        self.totalDuration = totalDuration
        self.mapStyle = mapStyle
        self.mapFollowsVehicle = mapFollowsVehicle
        self.showMap = showMap
        _outPoint = State(initialValue: totalDuration)
        _exportShowsMap = State(initialValue: showMap)
    }

    private var selectedDuration: Double { max(0, outPoint - inPoint) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Crop & Export")
                        .font(.title2.weight(.bold))
                    Text(clip.title)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isExporting)
            }

            // View mode info
            HStack(spacing: 6) {
                Image(systemName: "video.fill").font(.caption)
                Text("View: \(viewMode.rawValue)  ·  1920×1080  ·  H.264 MP4")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.blue.opacity(0.15), in: Capsule())
            .foregroundStyle(.blue)

            Divider()

            // Trim range
            VStack(alignment: .leading, spacing: 10) {
                Text("Select Range")
                    .font(.headline)

                // Speed graph with selected range highlighted
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        SpeedGraphView(
                            seiTimeline: seiTimeline,
                            currentSeconds: inPoint,
                            totalDuration: totalDuration
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        // dim excluded left region
                        let x1 = CGFloat(inPoint / max(totalDuration, 1)) * geo.size.width
                        let x2 = CGFloat(outPoint / max(totalDuration, 1)) * geo.size.width
                        Rectangle()
                            .fill(.black.opacity(0.55))
                            .frame(width: x1)
                        // dim excluded right region
                        Rectangle()
                            .fill(.black.opacity(0.55))
                            .frame(width: max(0, geo.size.width - x2))
                            .offset(x: x2)
                        // in/out markers
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: 2)
                            .offset(x: x1)
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: 2)
                            .offset(x: x2 - 2)
                    }
                }
                .frame(height: 44)

                // In-point row
                trimRow(
                    label: "IN", labelColor: .green,
                    time: inPoint,
                    range: 0...(outPoint - 0.5),
                    binding: Binding(
                        get: { inPoint },
                        set: { inPoint = $0 }
                    )
                )

                // Out-point row
                trimRow(
                    label: "OUT", labelColor: .red,
                    time: outPoint,
                    range: (inPoint + 0.5)...totalDuration,
                    binding: Binding(
                        get: { outPoint },
                        set: { outPoint = $0 }
                    )
                )

                // Duration + reset
                HStack {
                    Image(systemName: "clock").font(.caption).foregroundStyle(.secondary)
                    Text("Duration: **\(formatTime(selectedDuration))**")
                        .font(.caption)
                    Spacer()
                    Button("Reset") { inPoint = 0; outPoint = totalDuration }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }

            Divider()

            // Export overlays
            VStack(alignment: .leading, spacing: 10) {
                Text("Burned-in Overlays").font(.headline)

                HStack(spacing: 16) {
                    Label(exportShowsFSDBadge ? "Live telemetry HUD + FSD/AP" : "Live telemetry HUD", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.caption).foregroundStyle(.secondary)
                    Label(exportShowsGraph ? "Speed / G graph" : "Graph excluded from export", systemImage: exportShowsGraph ? "chart.xyaxis.line" : "chart.xyaxis.line")
                        .font(.caption).foregroundStyle(.secondary)
                    Label(exportShowsMap ? "Live map route + marker" : "Map excluded from export", systemImage: exportShowsMap ? "map" : "map.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Toggle(isOn: $exportShowsFSDBadge) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include FSD / AP badge")
                            .font(.callout.weight(.semibold))
                        Text("Exports the autopilot status badge inside the telemetry HUD.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $exportShowsGraph) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include speed profile graph")
                            .font(.callout.weight(.semibold))
                        Text("Exports the bottom speed and acceleration graph.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $exportShowsMap) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include map overlay")
                            .font(.callout.weight(.semibold))
                        Text("Exports the route map and vehicle marker in the top-right corner.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Spacer()

            // Progress / status
            if isExporting {
                VStack(spacing: 6) {
                    ProgressView(value: Double(exportProgress))
                        .progressViewStyle(.linear)
                    Text("Exporting… \(Int(exportProgress * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if exportDone {
                Label("Export complete — opened in Finder", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout.weight(.medium))
            } else if let err = exportError {
                Label("Failed: \(err)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red).font(.caption)
            }

            // Action buttons
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .disabled(isExporting)

                Button {
                    beginExport()
                } label: {
                    Label("Export Video", systemImage: "square.and.arrow.down")
                        .font(.headline).padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting || selectedDuration < 0.5)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: 500, height: 560)
    }

    // MARK: - Trim row

    private func trimRow(
        label: String,
        labelColor: Color,
        time: Double,
        range: ClosedRange<Double>,
        binding: Binding<Double>
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(labelColor)
                .frame(width: 32)

            Text(formatTime(time))
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .frame(width: 66, alignment: .leading)

            Slider(value: binding, in: range)

            Button("↑ Now") {
                if let t = currentPlayerTime() {
                    binding.wrappedValue = max(range.lowerBound, min(range.upperBound, t))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private func currentPlayerTime() -> Double? {
        let player = players[.front] ?? players.values.first
        guard let player else { return nil }
        let t = CMTimeGetSeconds(player.currentTime())
        return t.isFinite ? t : nil
    }

    private func formatTime(_ s: Double) -> String {
        guard s.isFinite && s >= 0 else { return "00:00" }
        let total = Int(s)
        let h = total / 3600; let m = (total % 3600) / 60; let sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    // MARK: - Start Export

    private func beginExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let safeName = clip.title
            .replacingOccurrences(of: " • ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safeName)_\(viewMode.rawValue).mp4"
        panel.message = "Choose where to save the exported video"

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        isExporting = true
        exportError = nil
        exportDone = false
        exportProgress = 0

        let config = VideoExportEngine.ExportConfig(
            clip: clip,
            viewMode: viewMode,
            inPoint: inPoint,
            outPoint: outPoint,
            seiTimeline: seiTimeline,
            gpsTrail: gpsTrail,
            mapStyle: mapStyle,
            mapFollowsVehicle: mapFollowsVehicle,
            showFSDBadge: exportShowsFSDBadge,
            showSpeedGraph: exportShowsGraph,
            showMap: exportShowsMap,
            outputURL: outputURL
        )

        Task {
            do {
                try await VideoExportEngine.export(config: config) { p in
                    Task { @MainActor in exportProgress = p }
                }
                await MainActor.run {
                    isExporting = false
                    exportDone = true
                    exportProgress = 1.0
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Video Export Engine

final class VideoExportEngine {

    struct ExportConfig {
        let clip: TeslaClip
        let viewMode: ViewMode
        let inPoint: Double
        let outPoint: Double
        let seiTimeline: [(seconds: Double, metadata: SeiMetadata)]
        let gpsTrail: [GPSTrailPoint]
        let mapStyle: MapStyleOption
        let mapFollowsVehicle: Bool
        let showFSDBadge: Bool
        let showSpeedGraph: Bool
        let showMap: Bool
        let outputURL: URL
    }

    static let outputSize = CGSize(width: 1920, height: 1080)

    private static let exportFPS: Double = 30
    private static let mapFPS: Double = 30
    private static let renderScale: CGFloat = 4
    private static let textRenderScale: CGFloat = 6
    private static let hudRenderScale: CGFloat = 2
    private static let hudBaseSize = CGSize(width: 340, height: 128)
    private static let hudFrame = CGRect(
        x: 24,
        y: 30,
        width: hudBaseSize.width * hudRenderScale,
        height: hudBaseSize.height * hudRenderScale
    )
    private static let mapPadding: CGFloat = 16
    private static let mapFrame = CGRect(
        x: outputSize.width - 280 - mapPadding,
        y: mapPadding + 8,
        width: 280,
        height: 210
    )
    private static let graphPadding: CGFloat = 18
    private static let graphFrame = CGRect(
        x: hudFrame.maxX + graphPadding,
        y: 30,
        width: max(420, mapFrame.minX - (hudFrame.maxX + graphPadding * 2)),
        height: 72
    )

    private static let glassCornerRadius: CGFloat = 14
    private static let mapCornerRadius: CGFloat = 14
    private static let graphCornerRadius: CGFloat = 12

    private struct RouteSample {
        let seconds: Double
        let coordinate: CLLocationCoordinate2D
    }

    private struct MapState {
        let coordinate: CLLocationCoordinate2D
        let heading: Double
    }

    private struct HUDSample {
        let relativeTime: Double
        let metadata: SeiMetadata?
        let currentDate: Date
        let blinkerOnPhase: Bool
    }

    private struct ExportHUDRenderState: Hashable {
        let timeText: String
        let speedText: String
        let dateText: String
        let autopilotLabel: String
        let gearText: String
        let steeringAngleText: String
        let steeringAngleDegrees: Int
        let brakePressed: Bool
        let leftBlinkerOn: Bool
        let rightBlinkerOn: Bool
        let acceleratorPressed: Bool
    }

    private struct ColorSpec: Hashable {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let a: CGFloat

        var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
        var cgColor: CGColor { nsColor.cgColor }
    }

    private struct TextFrame: Hashable {
        let text: String
        let color: ColorSpec
    }

    private struct BlinkerFrame: Hashable {
        let capsuleColor: ColorSpec
        let arrowColor: ColorSpec
        let scale: CGFloat
    }

    private struct BadgeFrame: Hashable {
        let text: TextFrame
        let background: ColorSpec
        let opacity: CGFloat
    }

    private struct PedalFrame: Hashable {
        let background: ColorSpec
        let groove: ColorSpec
        let scale: CGFloat
    }

    private struct MapFrameSample {
        let relativeTime: Double
        let image: CGImage?
        let trailPath: CGPath?
        let markerPoint: CGPoint?
        let heading: Double
    }

    private struct ExportGraphBackground {
        let speedFillPath: CGPath
        let speedLinePath: CGPath
        let gForcePath: CGPath
        let brakeTicksPath: CGPath?
        let maxSpeedText: String
        let maxGForceText: String
    }

    private struct TextSpec {
        let size: CGSize
        let font: NSFont
        let alignment: NSTextAlignment
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let textWhite = ColorSpec(r: 1, g: 1, b: 1, a: 1)
    private static let textSecondary = ColorSpec(r: 1, g: 1, b: 1, a: 0.65)
    private static let textTertiary = ColorSpec(r: 1, g: 1, b: 1, a: 0.35)
    private static let glassFill = ColorSpec(r: 1, g: 1, b: 1, a: 0.10)
    private static let glassStroke = ColorSpec(r: 1, g: 1, b: 1, a: 0.15)
    private static let glassHighlight = ColorSpec(r: 1, g: 1, b: 1, a: 0.18)
    private static let glassShadowTint = ColorSpec(r: 0, g: 0, b: 0, a: 0.10)
    private static let mapBorder = ColorSpec(r: 1, g: 1, b: 1, a: 0.12)
    private static let blue = ColorSpec(r: 0.11, g: 0.50, b: 0.98, a: 1)
    private static let blueSoft = ColorSpec(r: 0.11, g: 0.50, b: 0.98, a: 0.25)
    private static let yellow = ColorSpec(r: 1.0, g: 0.84, b: 0.16, a: 1)
    private static let red = ColorSpec(r: 1.0, g: 0.23, b: 0.19, a: 1)
    private static let orange = ColorSpec(r: 1.0, g: 0.58, b: 0.16, a: 1)
    private static let green = ColorSpec(r: 0.20, g: 0.86, b: 0.35, a: 1)
    private static let gray = ColorSpec(r: 0.62, g: 0.64, b: 0.68, a: 1)
    private static let badgeFill = ColorSpec(r: 1, g: 1, b: 1, a: 0.08)
    private static let pillFill = ColorSpec(r: 1, g: 1, b: 1, a: 0.12)

    // Channels included in each view mode
    static func channels(for mode: ViewMode) -> [CameraChannel] {
        switch mode {
        case .front:        return [.front]
        case .frontFocused: return Array(CameraChannel.allCases)
        case .grid4:        return [.front, .back, .left_repeater, .right_repeater]
        case .gridAll:      return Array(CameraChannel.allCases)
        }
    }

    // Destination rect in 1920×1080 for each channel (origin = bottom-left for Core Animation)
    static func destRect(for channel: CameraChannel, mode: ViewMode) -> CGRect {
        let W = outputSize.width
        let H = outputSize.height

        switch mode {
        case .front:
            return CGRect(x: 0, y: 0, width: W, height: H)

        case .frontFocused:
            let mainH = H * 0.78
            let stripH = H - mainH
            let stripChannels: [CameraChannel] = [.back, .left_repeater, .right_repeater, .left_pillar, .right_pillar]
            if channel == .front {
                return CGRect(x: 0, y: stripH, width: W, height: mainH)
            }
            let idx = CGFloat(stripChannels.firstIndex(of: channel) ?? 0)
            let cellW = W / CGFloat(stripChannels.count)
            return CGRect(x: idx * cellW, y: 0, width: cellW, height: stripH)

        case .grid4:
            let order: [CameraChannel] = [.front, .back, .left_repeater, .right_repeater]
            let idx = order.firstIndex(of: channel) ?? 0
            let col = CGFloat(idx % 2)
            let row = CGFloat(idx / 2)
            return CGRect(x: col * W / 2, y: row * H / 2, width: W / 2, height: H / 2)

        case .gridAll:
            let order = Array(CameraChannel.allCases)
            let idx = order.firstIndex(of: channel) ?? 0
            let col = CGFloat(idx % 2)
            let row = CGFloat(idx / 2)
            return CGRect(x: col * W / 2, y: row * H / 3, width: W / 2, height: H / 3)
        }
    }

    // MARK: - Export

    static func export(
        config: ExportConfig,
        progress: @escaping (Float) -> Void
    ) async throws {
        let channels = channels(for: config.viewMode)
        let sortedMoments = config.clip.moments.sorted { $0.timestamp < $1.timestamp }
        let exportStart = max(0, config.inPoint)
        let exportEnd = max(exportStart, config.outPoint)
        let requestedDuration = exportEnd - exportStart
        guard requestedDuration > 0 else {
            throw ExportError.exportFailed("Invalid export range")
        }

        let composition = AVMutableComposition()
        var trackMap: [CameraChannel: AVMutableCompositionTrack] = [:]

        // VIDEO TRACKS
        for channel in channels {
            let urls = sortedMoments.compactMap { $0.files[channel] }
            guard !urls.isEmpty else { continue }

            guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }

            var cursor = CMTime.zero
            for url in urls {
                let asset = AVURLAsset(url: url)
                guard let srcVideo = try? await asset.loadTracks(withMediaType: .video).first else { continue }
                guard let dur = try? await asset.load(.duration) else { continue }
                guard dur > .zero else { continue }
                let segmentStart = CMTimeGetSeconds(cursor)
                let segmentEnd = segmentStart + CMTimeGetSeconds(dur)
                let overlapStart = max(exportStart, segmentStart)
                let overlapEnd = min(exportEnd, segmentEnd)

                if overlapEnd > overlapStart {
                    let sourceStart = CMTime(seconds: overlapStart - segmentStart, preferredTimescale: 600)
                    let destStart = CMTime(seconds: overlapStart - exportStart, preferredTimescale: 600)
                    let overlapDuration = CMTime(seconds: overlapEnd - overlapStart, preferredTimescale: 600)
                    try? videoTrack.insertTimeRange(
                        CMTimeRange(start: sourceStart, duration: overlapDuration),
                        of: srcVideo,
                        at: destStart
                    )
                }
                cursor = CMTimeAdd(cursor, dur)
            }

            if videoTrack.timeRange.duration > .zero {
                trackMap[channel] = videoTrack
            }
        }

        guard !trackMap.isEmpty else { throw ExportError.noVideoTracks }

        let compositionDuration = composition.duration
        guard compositionDuration > .zero else {
            throw ExportError.exportFailed("Export composition is empty")
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: compositionDuration)
        instruction.backgroundColor = NSColor.black.cgColor

        var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []

        for channel in channels {
            guard let compTrack = trackMap[channel] else { continue }
            let dest = destRect(for: channel, mode: config.viewMode)

            let naturalSize = compTrack.naturalSize.applying(compTrack.preferredTransform)
            let srcW = abs(naturalSize.width)
            let srcH = abs(naturalSize.height)
            guard srcW > 0, srcH > 0 else { continue }

            let scale = max(dest.width / srcW, dest.height / srcH)
            let scaledW = srcW * scale
            let scaledH = srcH * scale
            let tx = dest.minX + (dest.width - scaledW) / 2
            let ty = dest.minY + (dest.height - scaledH) / 2

            let transform = compTrack.preferredTransform
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: tx, y: ty))

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
            layerInstruction.setTransform(transform, at: .zero)
            layerInstructions.append(layerInstruction)
        }

        instruction.layerInstructions = layerInstructions

        let (parentLayer, videoLayer) = try await buildOverlayLayers(
            config: config,
            exportDuration: CMTimeGetSeconds(compositionDuration),
            absoluteStart: exportStart
        )

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(exportFPS))
        videoComposition.instructions = [instruction]
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else { throw ExportError.exportSessionFailed }

        if FileManager.default.fileExists(atPath: config.outputURL.path) {
            try? FileManager.default.removeItem(at: config.outputURL)
        }

        let isValid = try await videoComposition.isValid(
            for: composition,
            timeRange: instruction.timeRange,
            validationDelegate: nil
        )
        guard isValid else {
            throw ExportError.exportFailed("Video composition validation failed")
        }

        session.videoComposition = videoComposition
        session.outputURL = config.outputURL
        session.outputFileType = .mp4

        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            progress(session.progress)
        }
        RunLoop.main.add(timer, forMode: .common)

        await session.export()
        timer.invalidate()
        progress(1)

        if let error = session.error as NSError? {
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            let underlyingText = underlying.map { " | underlying=\($0.domain) \($0.code): \($0.localizedDescription)" } ?? ""
            throw ExportError.exportFailed(
                "Export failed [status=\(session.status.rawValue)] \(error.domain) \(error.code): \(error.localizedDescription)\(underlyingText)"
            )
        }

        guard session.status == .completed else {
            throw ExportError.exportFailed("Export failed [status=\(session.status.rawValue)] with no AVFoundation error")
        }
    }

    // MARK: - Overlay Layers

    @MainActor
    private static func buildOverlayLayers(
        config: ExportConfig,
        exportDuration: Double,
        absoluteStart: Double
    ) async throws -> (parent: CALayer, video: CALayer) {
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: outputSize)
        parentLayer.isGeometryFlipped = false

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        guard exportDuration > 0 else { return (parentLayer, videoLayer) }

        if let hudLayer = makeHUDOverlayLayer(config: config, duration: exportDuration, absoluteStart: absoluteStart) {
            parentLayer.addSublayer(hudLayer)
        }

        if config.showSpeedGraph,
           let graphLayer = makeSpeedGraphOverlayLayer(config: config, duration: exportDuration, absoluteStart: absoluteStart) {
            parentLayer.addSublayer(graphLayer)
        }

        if config.showMap {
            do {
                if let mapLayer = try await makeMapOverlayLayer(config: config, duration: exportDuration, absoluteStart: absoluteStart) {
                    parentLayer.addSublayer(mapLayer)
                }
            } catch {
                parentLayer.addSublayer(makeUnavailableMapLayer())
            }
        }

        return (parentLayer, videoLayer)
    }

    // MARK: - HUD Overlay

    @MainActor
    private static func makeHUDOverlayLayer(
        config: ExportConfig,
        duration: Double,
        absoluteStart: Double
    ) -> CALayer? {
        let layer = CALayer()
        layer.frame = hudFrame
        layer.contentsScale = renderScale
        layer.contentsGravity = .resize

        if config.seiTimeline.isEmpty {
            layer.contents = renderExportHUDImage(
                current: nil,
                seiState: .unavailable,
                playerSeconds: absoluteStart,
                clipStartDate: config.clip.date,
                showAutopilotBadge: config.showFSDBadge
            )
            return layer
        }

        let samples = makeHUDSamples(config: config, duration: duration, absoluteStart: absoluteStart)
        guard !samples.isEmpty else { return nil }

        var compactFrames: [(time: Double, sample: HUDSample, state: ExportHUDRenderState)] = []
        for sample in samples {
            let state = makeExportHUDRenderState(from: sample, showAutopilotBadge: config.showFSDBadge)
            if compactFrames.last?.state != state {
                compactFrames.append((time: sample.relativeTime, sample: sample, state: state))
            }
        }

        guard let first = compactFrames.first else { return nil }
        var cache: [ExportHUDRenderState: CGImage] = [:]

        func image(for frame: (time: Double, sample: HUDSample, state: ExportHUDRenderState)) -> CGImage? {
            if let cached = cache[frame.state] {
                return cached
            }
            let rendered = renderExportHUDImage(
                current: frame.sample.metadata,
                seiState: .loaded(1),
                playerSeconds: absoluteStart + frame.time,
                clipStartDate: config.clip.date,
                showAutopilotBadge: config.showFSDBadge
            )
            if let rendered {
                cache[frame.state] = rendered
            }
            return rendered
        }

        guard let firstImage = image(for: first) else { return nil }
        layer.contents = firstImage

        let keyTimes = normalizedKeyTimes(for: compactFrames.map(\.time), duration: duration)
        let values = compactFrames.compactMap(image(for:))
        guard values.count == compactFrames.count else { return layer }

        applyKeyframeAnimation(
            to: layer,
            keyPath: "contents",
            values: values,
            keyTimes: keyTimes,
            duration: duration,
            calculationMode: .discrete
        )

        return layer
    }

    // MARK: - Speed Graph Overlay

    @MainActor
    private static func makeSpeedGraphOverlayLayer(
        config: ExportConfig,
        duration: Double,
        absoluteStart: Double
    ) -> CALayer? {
        let trimmedTimeline = trimmedSEISamples(config: config)
        guard trimmedTimeline.count > 1,
              let background = makeGraphBackground(
                timeline: trimmedTimeline,
                duration: duration,
                size: graphFrame.size
              ) else { return nil }

        let shadowLayer = CALayer()
        shadowLayer.frame = graphFrame
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.28
        shadowLayer.shadowRadius = 10
        shadowLayer.shadowOffset = CGSize(width: 0, height: 4)
        shadowLayer.shadowPath = CGPath(
            roundedRect: shadowLayer.bounds,
            cornerWidth: graphCornerRadius,
            cornerHeight: graphCornerRadius,
            transform: nil
        )

        let clipLayer = CALayer()
        clipLayer.frame = shadowLayer.bounds
        clipLayer.cornerRadius = graphCornerRadius
        clipLayer.masksToBounds = true
        clipLayer.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        shadowLayer.addSublayer(clipLayer)

        let canvasLayer = CALayer()
        canvasLayer.frame = clipLayer.bounds
        canvasLayer.isGeometryFlipped = true
        clipLayer.addSublayer(canvasLayer)

        let fillLayer = CAShapeLayer()
        fillLayer.frame = canvasLayer.bounds
        fillLayer.path = background.speedFillPath
        fillLayer.fillColor = blueSoft.cgColor
        canvasLayer.addSublayer(fillLayer)

        let speedLayer = CAShapeLayer()
        speedLayer.frame = canvasLayer.bounds
        speedLayer.path = background.speedLinePath
        speedLayer.fillColor = nil
        speedLayer.strokeColor = blue.nsColor.withAlphaComponent(0.78).cgColor
        speedLayer.lineWidth = 1.5
        speedLayer.lineJoin = .round
        speedLayer.lineCap = .round
        canvasLayer.addSublayer(speedLayer)

        let gForceLayer = CAShapeLayer()
        gForceLayer.frame = canvasLayer.bounds
        gForceLayer.path = background.gForcePath
        gForceLayer.fillColor = nil
        gForceLayer.strokeColor = orange.nsColor.withAlphaComponent(0.88).cgColor
        gForceLayer.lineWidth = 1.2
        gForceLayer.lineJoin = .round
        gForceLayer.lineCap = .round
        canvasLayer.addSublayer(gForceLayer)

        if let brakeTicksPath = background.brakeTicksPath {
            let brakeTicksLayer = CAShapeLayer()
            brakeTicksLayer.frame = canvasLayer.bounds
            brakeTicksLayer.path = brakeTicksPath
            brakeTicksLayer.fillColor = nil
            brakeTicksLayer.strokeColor = red.nsColor.withAlphaComponent(0.72).cgColor
            brakeTicksLayer.lineWidth = 1
            canvasLayer.addSublayer(brakeTicksLayer)
        }

        let titleLayer = makeTextContentLayer(frame: CGRect(x: 6, y: 4, width: 90, height: 10))
        clipLayer.addSublayer(titleLayer)
        applyStaticText(
            to: titleLayer,
            value: TextFrame(text: "SPEED / ACCEL", color: ColorSpec(r: 1, g: 1, b: 1, a: 0.22)),
            spec: TextSpec(size: titleLayer.bounds.size, font: NSFont.systemFont(ofSize: 7, weight: .semibold), alignment: .left)
        )

        let maxSpeedLayer = makeTextContentLayer(frame: CGRect(x: graphFrame.width - 96, y: graphFrame.height - 14, width: 92, height: 10))
        clipLayer.addSublayer(maxSpeedLayer)
        applyStaticText(
            to: maxSpeedLayer,
            value: TextFrame(text: background.maxSpeedText, color: ColorSpec(r: 1, g: 1, b: 1, a: 0.30)),
            spec: TextSpec(size: maxSpeedLayer.bounds.size, font: NSFont.systemFont(ofSize: 8, weight: .regular), alignment: .right)
        )

        let maxGForceLayer = makeTextContentLayer(frame: CGRect(x: graphFrame.width - 96, y: graphFrame.height - 26, width: 92, height: 10))
        clipLayer.addSublayer(maxGForceLayer)
        applyStaticText(
            to: maxGForceLayer,
            value: TextFrame(text: background.maxGForceText, color: ColorSpec(r: orange.r, g: orange.g, b: orange.b, a: 0.65)),
            spec: TextSpec(size: maxGForceLayer.bounds.size, font: NSFont.systemFont(ofSize: 8, weight: .regular), alignment: .right)
        )

        let playheadLayer = CALayer()
        playheadLayer.frame = CGRect(x: 0, y: 0, width: 1.5, height: graphFrame.height)
        playheadLayer.backgroundColor = NSColor.white.withAlphaComponent(0.88).cgColor
        canvasLayer.addSublayer(playheadLayer)

        let currentLabelLayer = makeTextContentLayer(frame: CGRect(x: 4, y: graphFrame.height - 16, width: 180, height: 12))
        clipLayer.addSublayer(currentLabelLayer)

        applyGraphPlayheadAnimations(
            to: playheadLayer,
            labelLayer: currentLabelLayer,
            config: config,
            duration: duration,
            absoluteStart: absoluteStart
        )

        let border = CAShapeLayer()
        border.frame = clipLayer.bounds
        border.path = CGPath(
            roundedRect: clipLayer.bounds,
            cornerWidth: graphCornerRadius,
            cornerHeight: graphCornerRadius,
            transform: nil
        )
        border.fillColor = NSColor.clear.cgColor
        border.strokeColor = glassStroke.cgColor
        border.lineWidth = 1
        clipLayer.addSublayer(border)

        return shadowLayer
    }

    @MainActor
    private static func addStaticUnavailableHUD(to content: CALayer) {
        let label = makeTextContentLayer(frame: hudRect(x: 12, y: 34, width: 316, height: 20))
        content.addSublayer(label)
        applyStaticText(
            to: label,
            value: TextFrame(text: "No telemetry data", color: textTertiary),
            spec: TextSpec(size: label.bounds.size, font: NSFont.systemFont(ofSize: 12, weight: .medium), alignment: .left)
        )
    }

    @MainActor
    private static func makeHUDSamples(
        config: ExportConfig,
        duration: Double,
        absoluteStart: Double
    ) -> [HUDSample] {
        sampleTimes(duration: duration, fps: exportFPS).map { relativeTime in
            let absoluteTime = absoluteStart + relativeTime
            let phaseIndex = Int((max(0, absoluteTime) / 0.33).rounded(.down))
            return HUDSample(
                relativeTime: relativeTime,
                metadata: nearestSEIFrame(to: absoluteTime, in: config.seiTimeline)?.metadata,
                currentDate: config.clip.date.addingTimeInterval(absoluteTime),
                blinkerOnPhase: phaseIndex.isMultiple(of: 2)
            )
        }
    }

    @MainActor
    private static func renderExportHUDImage(
        current: SeiMetadata?,
        seiState: SEIState,
        playerSeconds: Double,
        clipStartDate: Date,
        showAutopilotBadge: Bool
    ) -> CGImage? {
        let renderer = ImageRenderer(
            content: CompactTelemetryHUD(
                current: current,
                seiState: seiState,
                playerSeconds: playerSeconds,
                clipStartDate: clipStartDate,
                showAutopilotBadge: showAutopilotBadge
            )
            .frame(width: hudBaseSize.width, height: hudBaseSize.height, alignment: .topLeading)
            .scaleEffect(hudRenderScale, anchor: .topLeading)
            .frame(width: hudFrame.width, height: hudFrame.height, alignment: .topLeading)
            .environment(\.colorScheme, .dark)
        )
        renderer.scale = renderScale
        renderer.proposedSize = ProposedViewSize(hudFrame.size)
        return renderer.cgImage
    }

    private static func makeExportHUDRenderState(from sample: HUDSample, showAutopilotBadge: Bool) -> ExportHUDRenderState {
        let metadata = sample.metadata
        let autopilotLabel: String
        if showAutopilotBadge {
            switch metadata?.autopilotState {
            case .selfDriving: autopilotLabel = "FSD"
            case .autosteer: autopilotLabel = "AP"
            case .tacc: autopilotLabel = "TACC"
            default: autopilotLabel = ""
            }
        } else {
            autopilotLabel = ""
        }

        let gearText: String
        switch metadata?.gearState {
        case .park: gearText = "P"
        case .reverse: gearText = "R"
        case .neutral: gearText = "N"
        case .drive: gearText = "D"
        default: gearText = "–"
        }

        let steering = Int((metadata?.steeringWheelAngle ?? 0).rounded())
        return ExportHUDRenderState(
            timeText: timeFormatter.string(from: sample.currentDate),
            speedText: "\(Int((metadata?.vehicleSpeedMps ?? 0) * 2.237))",
            dateText: dateFormatter.string(from: sample.currentDate),
            autopilotLabel: autopilotLabel,
            gearText: gearText,
            steeringAngleText: String(format: "%+.0f°", Double(metadata?.steeringWheelAngle ?? 0)),
            steeringAngleDegrees: steering,
            brakePressed: metadata?.brakeApplied ?? false,
            leftBlinkerOn: (metadata?.blinkerOnLeft ?? false) && sample.blinkerOnPhase,
            rightBlinkerOn: (metadata?.blinkerOnRight ?? false) && sample.blinkerOnPhase,
            acceleratorPressed: (metadata?.acceleratorPedalPosition ?? 0) > 0.05
        )
    }

    @MainActor
    private static func applyGraphPlayheadAnimations(
        to playheadLayer: CALayer,
        labelLayer: CALayer,
        config: ExportConfig,
        duration: Double,
        absoluteStart: Double
    ) {
        let frameTimes = sampleTimes(duration: duration, fps: exportFPS)
        guard !frameTimes.isEmpty else { return }

        let playheadPositions = frameTimes.map { relativeTime -> (Double, NSValue) in
            let x = min(CGFloat(relativeTime / max(duration, 0.001)) * graphFrame.width, graphFrame.width - 1)
            return (
                relativeTime,
                NSValue(point: NSPoint(x: x + playheadLayer.bounds.width / 2, y: graphFrame.height / 2))
            )
        }

        playheadLayer.position = playheadPositions[0].1.pointValue
        applyKeyframeAnimation(
            to: playheadLayer,
            keyPath: "position",
            values: playheadPositions.map(\.1),
            keyTimes: normalizedKeyTimes(for: playheadPositions.map(\.0), duration: duration),
            duration: duration,
            calculationMode: .linear
        )

        let labelWidth = labelLayer.bounds.width
        let labelFrames = frameTimes.compactMap { relativeTime -> (time: Double, value: TextFrame)? in
            let absoluteTime = absoluteStart + relativeTime
            guard let metadata = nearestSEIFrame(to: absoluteTime, in: config.seiTimeline)?.metadata else { return nil }
            let mph = Int(metadata.vehicleSpeedMps * 2.237)
            let gForce = combinedGForce(for: metadata)
            return (
                time: relativeTime,
                value: TextFrame(
                    text: "\(mph) mph  •  \(String(format: "%.2fG", gForce))",
                    color: ColorSpec(r: 1, g: 1, b: 1, a: 0.82)
                )
            )
        }

        if let firstFrame = labelFrames.first {
            applyStaticText(
                to: labelLayer,
                value: firstFrame.value,
                spec: TextSpec(size: labelLayer.bounds.size, font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold), alignment: .left)
            )
        }
        applyTextFrames(
            to: labelLayer,
            frames: labelFrames,
            duration: duration,
            spec: TextSpec(size: labelLayer.bounds.size, font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold), alignment: .left)
        )

        let labelPositions = frameTimes.map { relativeTime -> (Double, NSValue) in
            let playX = min(CGFloat(relativeTime / max(duration, 0.001)) * graphFrame.width, graphFrame.width - 1)
            let originX = min(max(playX + 6, 3), graphFrame.width - labelWidth - 3)
            return (
                relativeTime,
                NSValue(point: NSPoint(x: originX + labelWidth / 2, y: labelLayer.frame.midY))
            )
        }
        labelLayer.position = labelPositions[0].1.pointValue
        applyKeyframeAnimation(
            to: labelLayer,
            keyPath: "position",
            values: labelPositions.map(\.1),
            keyTimes: normalizedKeyTimes(for: labelPositions.map(\.0), duration: duration),
            duration: duration,
            calculationMode: .linear
        )
    }

    // MARK: - Map Overlay

    // Follow-cam support types

    private struct FollowCamWaypoint {
        let seconds: Double
        let coordinate: CLLocationCoordinate2D
    }

    private struct WaypointSnapshot {
        let seconds: Double
        let coordinate: CLLocationCoordinate2D   // center of this snapshot (the vehicle's GPS position at snapshot time)
        let snapshot: MKMapSnapshotter.Snapshot
        let image: CGImage?
    }

    /// Cluster route samples by distance so we generate one map snapshot per ~50 m of travel.
    private static func collectFollowCamWaypoints(
        route: [RouteSample],
        distanceThreshold: Double = 50
    ) -> [FollowCamWaypoint] {
        guard !route.isEmpty else { return [] }
        var waypoints: [FollowCamWaypoint] = []
        var lastCoord: CLLocationCoordinate2D? = nil
        for sample in route {
            let coord = sample.coordinate
            if let last = lastCoord {
                let dlat = (coord.latitude  - last.latitude)  * 111_000
                let dlon = (coord.longitude - last.longitude) * 111_000 * cos(last.latitude * .pi / 180)
                if sqrt(dlat * dlat + dlon * dlon) < distanceThreshold { continue }
            }
            waypoints.append(FollowCamWaypoint(seconds: sample.seconds, coordinate: coord))
            lastCoord = coord
        }
        // Always include first and last points so we have coverage at clip boundaries.
        if let first = route.first, waypoints.first?.seconds != first.seconds {
            waypoints.insert(FollowCamWaypoint(seconds: first.seconds, coordinate: first.coordinate), at: 0)
        }
        if let last = route.last, waypoints.last?.seconds != last.seconds {
            waypoints.append(FollowCamWaypoint(seconds: last.seconds, coordinate: last.coordinate))
        }
        return waypoints
    }

    /// Take one MKMapSnapshotter snapshot per waypoint, centred at 350 m — identical zoom to LiveMapView.
    @MainActor
    private static func makeFollowCamSnapshots(
        waypoints: [FollowCamWaypoint],
        mapStyle: MapStyleOption
    ) async -> [WaypointSnapshot] {
        var result: [WaypointSnapshot] = []
        for waypoint in waypoints {
            let options = MKMapSnapshotter.Options()
            options.camera = MKMapCamera(
                lookingAtCenter: waypoint.coordinate,
                fromDistance: 350,
                pitch: 0,
                heading: 0
            )
            options.size = CGSize(width: mapFrame.width * renderScale, height: mapFrame.height * renderScale)
            options.mapType = mapType(for: mapStyle)
            options.showsBuildings = false
            do {
                let snap = try await MKMapSnapshotter(options: options).start()
                result.append(WaypointSnapshot(seconds: waypoint.seconds, coordinate: waypoint.coordinate, snapshot: snap, image: cgImage(from: snap.image)))
            } catch {
                // If satellite tiles fail, try standard for this waypoint.
                if mapStyle == .satellite {
                    let fb = MKMapSnapshotter.Options()
                    fb.camera = options.camera
                    fb.size = options.size
                    fb.mapType = .standard
                    fb.showsBuildings = false
                    if let snap = try? await MKMapSnapshotter(options: fb).start() {
                        result.append(WaypointSnapshot(seconds: waypoint.seconds, coordinate: waypoint.coordinate, snapshot: snap, image: cgImage(from: snap.image)))
                    }
                }
            }
        }
        return result
    }

    /// Approximate squared geographic distance between two coordinates (metres²), fast enough for comparisons.
    private static func geoDistSq(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dlat = (a.latitude  - b.latitude)  * 111_000
        let dlon = (a.longitude - b.longitude) * 111_000 * cos(a.latitude * .pi / 180)
        return dlat * dlat + dlon * dlon
    }

    /// Build MapFrameSamples using per-waypoint follow-cam snapshots.
    ///
    /// Snapshot selection is **position-based** (nearest centre coordinate to the vehicle's current
    /// GPS position), NOT time-based. Time-based selection breaks when the vehicle is stationary: the
    /// mid-point between two waypoints in time would switch to the next snapshot while the car hasn't
    /// moved yet, showing the wrong map area.
    private static func makeFollowCamMapFrameSamples(
        duration: Double,
        absoluteStart: Double,
        waypointSnapshots: [WaypointSnapshot],
        route: [RouteSample],
        seiTimeline: [(seconds: Double, metadata: SeiMetadata)]
    ) -> [MapFrameSample] {
        guard !waypointSnapshots.isEmpty else { return [] }

        // Approximate viewport radius at 350 m altitude: visible area ≈ 400 m radius.
        // We keep a generous 600 m window so the trail visibly enters from the edge.
        let trailWindowMetres: Double = 600

        return sampleTimes(duration: duration, fps: mapFPS).map { relativeTime in
            let absoluteTime = absoluteStart + relativeTime
            let state = mapState(at: absoluteTime, seiTimeline: seiTimeline, route: route)

            // ── Pick the snapshot whose centre is geographically closest to the vehicle ──
            // Falls back to nearest-in-time when no GPS is available.
            let ws: WaypointSnapshot
            if let vehicleCoord = state?.coordinate {
                ws = waypointSnapshots.min(by: {
                    geoDistSq($0.coordinate, vehicleCoord) < geoDistSq($1.coordinate, vehicleCoord)
                })!
            } else {
                ws = waypointSnapshots.min(by: {
                    abs($0.seconds - absoluteTime) < abs($1.seconds - absoluteTime)
                })!
            }

            // ── Build trail: only include GPS points within the viewport window ──
            // Filtering out far-away points prevents extreme-coordinate path segments
            // that can cause CAShapeLayer rendering artefacts.
            let allTrailCoords = visibleTrail(in: route, upTo: absoluteTime)
            let trailCoords: [CLLocationCoordinate2D]
            if let vehicleCoord = state?.coordinate {
                let windowSq = trailWindowMetres * trailWindowMetres
                trailCoords = allTrailCoords.filter { geoDistSq($0, vehicleCoord) <= windowSq }
            } else {
                trailCoords = allTrailCoords
            }

            return MapFrameSample(
                relativeTime: relativeTime,
                image: ws.image,
                trailPath: makeTrailPath(
                    snapshot: ws.snapshot,
                    coordinates: trailCoords,
                    canvasHeight: mapFrame.height
                ),
                markerPoint: state.map {
                    mapOverlayPoint(ws.snapshot.point(for: $0.coordinate), canvasHeight: mapFrame.height)
                },
                heading: state?.heading ?? 0
            )
        }
    }

    @MainActor
    private static func makeMapOverlayLayer(
        config: ExportConfig,
        duration: Double,
        absoluteStart: Double
    ) async throws -> CALayer? {
        let route = trimmedRouteSamples(config: config)
        guard !route.isEmpty else {
            return makeUnavailableMapLayer()
        }

        let shadowLayer = CALayer()
        shadowLayer.frame = mapFrame
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.45
        shadowLayer.shadowRadius = 14
        shadowLayer.shadowOffset = CGSize(width: 0, height: 5)
        shadowLayer.shadowPath = CGPath(roundedRect: shadowLayer.bounds, cornerWidth: mapCornerRadius, cornerHeight: mapCornerRadius, transform: nil)

        let clipLayer = CALayer()
        clipLayer.frame = shadowLayer.bounds
        clipLayer.cornerRadius = mapCornerRadius
        clipLayer.masksToBounds = true
        shadowLayer.addSublayer(clipLayer)

        let backgroundLayer = CALayer()
        backgroundLayer.frame = clipLayer.bounds
        backgroundLayer.contentsGravity = .resize
        backgroundLayer.contentsScale = renderScale
        clipLayer.addSublayer(backgroundLayer)

        let trailLayer = CAShapeLayer()
        trailLayer.frame = clipLayer.bounds
        trailLayer.fillColor = nil
        trailLayer.strokeColor = blue.nsColor.withAlphaComponent(0.92).cgColor
        trailLayer.lineWidth = 4
        trailLayer.lineCap = .round
        trailLayer.lineJoin = .round
        clipLayer.addSublayer(trailLayer)

        let markerLayer = makeMarkerLayer()
        clipLayer.addSublayer(markerLayer)

        let border = CAShapeLayer()
        border.frame = clipLayer.bounds
        border.path = CGPath(roundedRect: clipLayer.bounds, cornerWidth: mapCornerRadius, cornerHeight: mapCornerRadius, transform: nil)
        border.fillColor = NSColor.clear.cgColor
        border.strokeColor = mapBorder.cgColor
        border.lineWidth = 1
        clipLayer.addSublayer(border)

        // Generate frame samples: follow-cam (per-waypoint snapshots at 350 m zoom) or full-route overview.
        let samples: [MapFrameSample]
        if config.mapFollowsVehicle {
            let waypoints = collectFollowCamWaypoints(route: route)
            guard !waypoints.isEmpty else { return makeUnavailableMapLayer() }
            let waypointSnapshots = await makeFollowCamSnapshots(waypoints: waypoints, mapStyle: config.mapStyle)
            guard !waypointSnapshots.isEmpty else { return makeUnavailableMapLayer() }
            samples = makeFollowCamMapFrameSamples(
                duration: duration,
                absoluteStart: absoluteStart,
                waypointSnapshots: waypointSnapshots,
                route: route,
                seiTimeline: config.seiTimeline
            )
        } else {
            let overview = try await makeOverviewSnapshot(
                route: route,
                mapStyle: config.mapStyle,
                size: CGSize(width: mapFrame.width * renderScale, height: mapFrame.height * renderScale)
            )
            let overviewImage = cgImage(from: overview.image)
            samples = makeOverviewMapFrameSamples(
                duration: duration,
                absoluteStart: absoluteStart,
                route: route,
                overviewSnapshot: overview,
                overviewImage: overviewImage,
                seiTimeline: config.seiTimeline
            )
        }
        guard let first = samples.first else { return nil }

        backgroundLayer.contents = first.image
        trailLayer.path = first.trailPath
        if let markerPoint = first.markerPoint {
            markerLayer.position = markerPoint
            markerLayer.opacity = 1
        } else {
            markerLayer.opacity = 0
        }
        markerLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(first.heading * .pi / 180)))

        applyBackgroundImageAnimation(to: backgroundLayer, samples: samples, duration: duration)
        applyOptionalPathAnimation(to: trailLayer, samples: samples, duration: duration)
        applyMarkerAnimations(to: markerLayer, samples: samples, duration: duration)

        return shadowLayer
    }

    @MainActor
    private static func makeUnavailableMapLayer() -> CALayer {
        let shadowLayer = CALayer()
        shadowLayer.frame = mapFrame
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.45
        shadowLayer.shadowRadius = 14
        shadowLayer.shadowOffset = CGSize(width: 0, height: 5)

        let clipLayer = CALayer()
        clipLayer.frame = shadowLayer.bounds
        clipLayer.cornerRadius = mapCornerRadius
        clipLayer.masksToBounds = true
        clipLayer.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        shadowLayer.addSublayer(clipLayer)

        let label = makeTextContentLayer(frame: CGRect(x: 20, y: 92, width: 240, height: 16))
        clipLayer.addSublayer(label)
        applyStaticText(
            to: label,
            value: TextFrame(text: "No GPS Signal", color: textTertiary),
            spec: TextSpec(size: label.bounds.size, font: NSFont.systemFont(ofSize: 11, weight: .medium), alignment: .center)
        )

        let border = CAShapeLayer()
        border.frame = clipLayer.bounds
        border.path = CGPath(roundedRect: clipLayer.bounds, cornerWidth: mapCornerRadius, cornerHeight: mapCornerRadius, transform: nil)
        border.fillColor = NSColor.clear.cgColor
        border.strokeColor = mapBorder.cgColor
        border.lineWidth = 1
        clipLayer.addSublayer(border)
        return shadowLayer
    }

    private static func makeOverviewMapFrameSamples(
        duration: Double,
        absoluteStart: Double,
        route: [RouteSample],
        overviewSnapshot: MKMapSnapshotter.Snapshot,
        overviewImage: CGImage?,
        seiTimeline: [(seconds: Double, metadata: SeiMetadata)]
    ) -> [MapFrameSample] {
        let frameTimes = sampleTimes(duration: duration, fps: mapFPS)

        return frameTimes.map { relativeTime in
            let absoluteTime = absoluteStart + relativeTime
            let state = mapState(at: absoluteTime, seiTimeline: seiTimeline, route: route)
            return MapFrameSample(
                relativeTime: relativeTime,
                image: overviewImage,
                trailPath: makeTrailPath(
                    snapshot: overviewSnapshot,
                    coordinates: visibleTrail(in: route, upTo: absoluteTime),
                    canvasHeight: mapFrame.height
                ),
                markerPoint: state.map { mapOverlayPoint(overviewSnapshot.point(for: $0.coordinate), canvasHeight: mapFrame.height) },
                heading: state?.heading ?? 0
            )
        }
    }

    private static func makeOverviewSnapshot(
        route: [RouteSample],
        mapStyle: MapStyleOption,
        size: CGSize
    ) async throws -> MKMapSnapshotter.Snapshot {
        let options = MKMapSnapshotter.Options()
        options.region = regionForOverview(route: route)
        options.size = size
        options.mapType = mapType(for: mapStyle)
        options.showsBuildings = false
        do {
            return try await MKMapSnapshotter(options: options).start()
        } catch {
            guard mapStyle == .satellite else { throw error }

            let fallbackOptions = MKMapSnapshotter.Options()
            fallbackOptions.region = options.region
            fallbackOptions.size = size
            fallbackOptions.mapType = .standard
            fallbackOptions.showsBuildings = false
            return try await MKMapSnapshotter(options: fallbackOptions).start()
        }
    }

    private static func makeTrailPath(
        snapshot: MKMapSnapshotter.Snapshot,
        coordinates: [CLLocationCoordinate2D],
        canvasHeight: CGFloat
    ) -> CGPath? {
        guard coordinates.count > 1 else { return nil }

        let path = CGMutablePath()
        for (index, coordinate) in coordinates.enumerated() {
            let point = mapOverlayPoint(snapshot.point(for: coordinate), canvasHeight: canvasHeight)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private static func mapOverlayPoint(_ point: CGPoint, canvasHeight: CGFloat) -> CGPoint {
        let scaledY = point.y / renderScale
        return CGPoint(x: point.x / renderScale, y: canvasHeight - scaledY)
    }

    private static func hudRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x, y: hudFrame.height - y - height, width: width, height: height)
    }

    // MARK: - HUD Builders

    @MainActor
    private static func glassCardLayer(
        frame: CGRect,
        shadowOpacity: Float,
        shadowRadius: CGFloat,
        shadowOffset: CGSize
    ) -> CALayer {
        let root = CALayer()
        root.frame = frame
        root.shadowColor = NSColor.black.cgColor
        root.shadowOpacity = shadowOpacity
        root.shadowRadius = shadowRadius
        root.shadowOffset = shadowOffset
        root.shadowPath = CGPath(roundedRect: root.bounds, cornerWidth: glassCornerRadius, cornerHeight: glassCornerRadius, transform: nil)

        let clip = CALayer()
        clip.frame = root.bounds
        clip.cornerRadius = glassCornerRadius
        clip.masksToBounds = true
        root.addSublayer(clip)

        let fill = CAShapeLayer()
        fill.frame = clip.bounds
        fill.path = CGPath(roundedRect: clip.bounds, cornerWidth: glassCornerRadius, cornerHeight: glassCornerRadius, transform: nil)
        fill.fillColor = glassFill.cgColor
        clip.addSublayer(fill)

        let topSheen = CAGradientLayer()
        topSheen.frame = clip.bounds
        topSheen.colors = [glassHighlight.cgColor, NSColor.clear.cgColor]
        topSheen.locations = [0, 0.55]
        clip.addSublayer(topSheen)

        let bottomTint = CAGradientLayer()
        bottomTint.frame = clip.bounds
        bottomTint.colors = [NSColor.clear.cgColor, glassShadowTint.cgColor]
        bottomTint.locations = [0.55, 1]
        clip.addSublayer(bottomTint)

        let border = CAShapeLayer()
        border.frame = clip.bounds
        border.path = fill.path
        border.fillColor = NSColor.clear.cgColor
        border.strokeColor = glassStroke.cgColor
        border.lineWidth = 1
        clip.addSublayer(border)

        return root
    }

    @MainActor
    private static func makeTextContentLayer(frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.contentsScale = textRenderScale
        layer.contentsGravity = .center
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .linear
        return layer
    }

    @MainActor
    private static func makeBadgeLayer(
        frame: CGRect,
        cornerRadius: CGFloat
    ) -> (container: CALayer, background: CAShapeLayer, text: CALayer) {
        let container = CALayer()
        container.frame = frame
        container.opacity = 1

        let background = CAShapeLayer()
        background.frame = container.bounds
        background.path = CGPath(roundedRect: container.bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        background.fillColor = gray.cgColor
        container.addSublayer(background)

        let text = makeTextContentLayer(frame: container.bounds.insetBy(dx: 4, dy: 2))
        container.addSublayer(text)
        return (container, background, text)
    }

    private enum BlinkerDirection { case left, right }

    @MainActor
    private static func makeBlinkerLayer(
        frame: CGRect,
        direction: BlinkerDirection
    ) -> (container: CALayer, capsule: CAShapeLayer, arrow: CAShapeLayer) {
        let container = CALayer()
        container.frame = frame

        let capsule = CAShapeLayer()
        capsule.frame = container.bounds
        capsule.path = CGPath(roundedRect: container.bounds, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2, transform: nil)
        capsule.fillColor = pillFill.cgColor
        capsule.strokeColor = glassStroke.cgColor
        capsule.lineWidth = 1
        container.addSublayer(capsule)

        let arrow = CAShapeLayer()
        arrow.frame = container.bounds
        arrow.fillColor = textSecondary.cgColor
        arrow.path = blinkerArrowPath(in: container.bounds.insetBy(dx: 6, dy: 4), direction: direction)
        container.addSublayer(arrow)

        return (container, capsule, arrow)
    }

    @MainActor
    private static func makeSteeringWheelLayer(frame: CGRect) -> CALayer {
        let container = CALayer()
        container.frame = frame
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        container.position = CGPoint(x: frame.midX, y: frame.midY)

        let outerRing = CAShapeLayer()
        outerRing.frame = container.bounds
        outerRing.path = CGPath(ellipseIn: container.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        outerRing.fillColor = NSColor.clear.cgColor
        outerRing.strokeColor = NSColor.white.withAlphaComponent(0.25).cgColor
        outerRing.lineWidth = 2
        container.addSublayer(outerRing)

        let wheel = CAShapeLayer()
        wheel.frame = container.bounds
        wheel.path = steeringWheelPath(in: container.bounds.insetBy(dx: 8, dy: 8))
        wheel.fillColor = NSColor.clear.cgColor
        wheel.strokeColor = textWhite.cgColor
        wheel.lineWidth = 1.8
        wheel.lineCap = .round
        wheel.lineJoin = .round
        container.addSublayer(wheel)

        return container
    }

    @MainActor
    private static func makePedalIndicatorLayer(
        frame: CGRect
    ) -> (container: CALayer, background: CAShapeLayer, grooves: [CAShapeLayer]) {
        let container = CALayer()
        container.frame = frame

        let background = CAShapeLayer()
        background.frame = container.bounds
        background.path = CGPath(roundedRect: container.bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        background.fillColor = badgeFill.cgColor
        background.strokeColor = glassStroke.cgColor
        background.lineWidth = 1
        container.addSublayer(background)

        let grooveYs: [CGFloat] = [7, 13, 19]
        let grooves = grooveYs.map { y -> CAShapeLayer in
            let groove = CAShapeLayer()
            groove.path = {
                let path = CGMutablePath()
                path.addRoundedRect(in: CGRect(x: 6, y: y, width: 10, height: 1.5), cornerWidth: 0.75, cornerHeight: 0.75)
                return path
            }()
            groove.fillColor = NSColor.white.withAlphaComponent(0.35).cgColor
            container.addSublayer(groove)
            return groove
        }

        return (container, background, grooves)
    }

    @MainActor
    private static func makeBrakeIndicatorLayer(
        frame: CGRect
    ) -> (container: CALayer, background: CAShapeLayer, grooves: [CAShapeLayer]) {
        let container = CALayer()
        container.frame = frame

        let background = CAShapeLayer()
        background.frame = container.bounds
        background.path = CGPath(roundedRect: container.bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        background.fillColor = badgeFill.cgColor
        background.strokeColor = glassStroke.cgColor
        background.lineWidth = 1
        container.addSublayer(background)

        let grooveXs: [CGFloat] = [7, 13, 19]
        let grooves = grooveXs.map { x -> CAShapeLayer in
            let groove = CAShapeLayer()
            groove.path = {
                let path = CGMutablePath()
                path.addRoundedRect(in: CGRect(x: x, y: 5, width: 1.5, height: 10), cornerWidth: 0.75, cornerHeight: 0.75)
                return path
            }()
            groove.fillColor = NSColor.white.withAlphaComponent(0.35).cgColor
            container.addSublayer(groove)
            return groove
        }

        return (container, background, grooves)
    }

    @MainActor
    private static func makeMarkerLayer() -> CALayer {
        let marker = CALayer()
        marker.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        marker.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        let halo = CAShapeLayer()
        halo.frame = marker.bounds
        halo.path = CGPath(ellipseIn: marker.bounds, transform: nil)
        halo.fillColor = blueSoft.cgColor
        marker.addSublayer(halo)

        let dot = CAShapeLayer()
        dot.frame = CGRect(x: 9, y: 9, width: 14, height: 14)
        dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
        dot.fillColor = blue.cgColor
        marker.addSublayer(dot)

        let arrow = CAShapeLayer()
        arrow.frame = dot.frame
        arrow.path = markerArrowPath(in: arrow.bounds)
        arrow.fillColor = textWhite.cgColor
        marker.addSublayer(arrow)

        return marker
    }

    // MARK: - HUD Animation Helpers

    @MainActor
    private static func applyTextFrames(
        to layer: CALayer,
        frames: [(time: Double, value: TextFrame)],
        duration: Double,
        spec: TextSpec
    ) {
        guard let first = frames.first else { return }
        var cache: [String: CGImage] = [:]
        layer.contents = rasterizedTextImage(value: first.value, spec: spec, cache: &cache)

        let compact = compactDiscreteFrames(frames)
        guard compact.count > 1 else { return }

        let keyTimes = normalizedKeyTimes(for: compact.map(\.time), duration: duration)
        let values = compact.compactMap { rasterizedTextImage(value: $0.value, spec: spec, cache: &cache) }
        guard values.count == compact.count else { return }

        applyKeyframeAnimation(
            to: layer,
            keyPath: "contents",
            values: values,
            keyTimes: keyTimes,
            duration: duration,
            calculationMode: .discrete
        )
    }

    @MainActor
    private static func applyStaticText(
        to layer: CALayer,
        value: TextFrame,
        spec: TextSpec
    ) {
        var cache: [String: CGImage] = [:]
        layer.contents = rasterizedTextImage(value: value, spec: spec, cache: &cache)
    }

    @MainActor
    private static func applyBadgeFrames(
        badge: (container: CALayer, background: CAShapeLayer, text: CALayer),
        frames: [(time: Double, value: BadgeFrame)],
        duration: Double,
        font: NSFont
    ) {
        guard let first = frames.first?.value else { return }

        badge.background.fillColor = first.background.cgColor
        badge.container.opacity = Float(first.opacity)
        applyStaticText(
            to: badge.text,
            value: first.text,
            spec: TextSpec(size: badge.text.bounds.size, font: font, alignment: .center)
        )

        let compact = compactDiscreteFrames(frames)

        applyDiscreteValues(
            to: badge.background,
            keyPath: "fillColor",
            frames: compact.map { ($0.time, $0.value.background.cgColor) },
            duration: duration
        )
        applyDiscreteValues(
            to: badge.container,
            keyPath: "opacity",
            frames: compact.map { ($0.time, NSNumber(value: Double($0.value.opacity))) },
            duration: duration
        )
        applyTextFrames(
            to: badge.text,
            frames: compact.map { ($0.time, $0.value.text) },
            duration: duration,
            spec: TextSpec(size: badge.text.bounds.size, font: font, alignment: .center)
        )
    }

    @MainActor
    private static func applyBlinkerFrames(
        blinker: (container: CALayer, capsule: CAShapeLayer, arrow: CAShapeLayer),
        frames: [(time: Double, value: BlinkerFrame)],
        duration: Double
    ) {
        guard let first = frames.first?.value else { return }
        blinker.capsule.fillColor = first.capsuleColor.cgColor
        blinker.arrow.fillColor = first.arrowColor.cgColor
        blinker.container.transform = CATransform3DMakeScale(first.scale, first.scale, 1)

        let compact = compactDiscreteFrames(frames)
        applyDiscreteValues(
            to: blinker.capsule,
            keyPath: "fillColor",
            frames: compact.map { ($0.time, $0.value.capsuleColor.cgColor) },
            duration: duration
        )
        applyDiscreteValues(
            to: blinker.arrow,
            keyPath: "fillColor",
            frames: compact.map { ($0.time, $0.value.arrowColor.cgColor) },
            duration: duration
        )
        applyDiscreteValues(
            to: blinker.container,
            keyPath: "transform.scale",
            frames: compact.map { ($0.time, NSNumber(value: Double($0.value.scale))) },
            duration: duration
        )
    }

    @MainActor
    private static func applyPedalFrames(
        pedal: (container: CALayer, background: CAShapeLayer, grooves: [CAShapeLayer]),
        frames: [(time: Double, value: PedalFrame)],
        duration: Double
    ) {
        guard let first = frames.first?.value else { return }
        pedal.background.fillColor = first.background.cgColor
        pedal.container.transform = CATransform3DMakeScale(first.scale, first.scale, 1)
        for groove in pedal.grooves {
            groove.fillColor = first.groove.cgColor
        }

        let compact = compactDiscreteFrames(frames)
        applyDiscreteValues(
            to: pedal.background,
            keyPath: "fillColor",
            frames: compact.map { ($0.time, $0.value.background.cgColor) },
            duration: duration
        )
        applyDiscreteValues(
            to: pedal.container,
            keyPath: "transform.scale",
            frames: compact.map { ($0.time, NSNumber(value: Double($0.value.scale))) },
            duration: duration
        )
        for groove in pedal.grooves {
            applyDiscreteValues(
                to: groove,
                keyPath: "fillColor",
                frames: compact.map { ($0.time, $0.value.groove.cgColor) },
                duration: duration
            )
        }
    }

    /// Animates `backgroundLayer.contents` when the map background changes across frames (follow-cam).
    /// For the overview case all frames share the same CGImage instance, so compactAnyFrames returns
    /// a single entry and we exit early — no animation overhead.
    @MainActor
    private static func applyBackgroundImageAnimation(
        to layer: CALayer,
        samples: [MapFrameSample],
        duration: Double
    ) {
        let imageFrames: [(Double, Any)] = samples.compactMap { sample in
            guard let image = sample.image else { return nil }
            return (sample.relativeTime, image as Any)
        }
        let compact = compactAnyFrames(imageFrames)
        guard compact.count > 1 else { return }
        applyKeyframeAnimation(
            to: layer,
            keyPath: "contents",
            values: compact.map(\.value),
            keyTimes: normalizedKeyTimes(for: compact.map(\.time), duration: duration),
            duration: duration,
            calculationMode: .discrete
        )
    }

    @MainActor
    private static func applyOptionalPathAnimation(
        to layer: CAShapeLayer,
        samples: [MapFrameSample],
        duration: Double
    ) {
        guard !samples.isEmpty else { return }

        let pathFrames = samples.compactMap { sample in
            sample.trailPath.map { (time: sample.relativeTime, value: $0) }
        }
        guard let firstPath = pathFrames.first else {
            layer.path = nil
            layer.opacity = 0
            return
        }

        layer.path = firstPath.value
        layer.opacity = Float(samples.first?.trailPath == nil ? 0 : 1)

        applyDiscreteValues(
            to: layer,
            keyPath: "opacity",
            frames: samples.map { ($0.relativeTime, NSNumber(value: Double($0.trailPath == nil ? 0 : 1))) },
            duration: duration
        )

        let compact = compactAnyFrames(pathFrames.map { ($0.time, $0.value as Any) })
        guard compact.count > 1 else { return }
        applyKeyframeAnimation(
            to: layer,
            keyPath: "path",
            values: compact.map(\.value),
            keyTimes: normalizedKeyTimes(for: compact.map(\.time), duration: duration),
            duration: duration,
            calculationMode: .discrete
        )
    }

    @MainActor
    private static func applyMarkerAnimations(
        to layer: CALayer,
        samples: [MapFrameSample],
        duration: Double
    ) {
        let positionFrames = samples.map {
            ($0.relativeTime, NSValue(point: NSPoint(x: $0.markerPoint?.x ?? layer.position.x, y: $0.markerPoint?.y ?? layer.position.y)))
        }
        applyDiscreteValues(to: layer, keyPath: "opacity", frames: samples.map {
            ($0.relativeTime, NSNumber(value: Double($0.markerPoint == nil ? 0 : 1)))
        }, duration: duration)

        applyKeyframeAnimation(
            to: layer,
            keyPath: "position",
            values: positionFrames.map(\.1),
            keyTimes: normalizedKeyTimes(for: positionFrames.map(\.0), duration: duration),
            duration: duration,
            calculationMode: .linear
        )

        let rotationValues = unwrapAngles(samples.map(\.heading)).map { NSNumber(value: $0 * .pi / 180) }
        applyKeyframeAnimation(
            to: layer,
            keyPath: "transform.rotation.z",
            values: rotationValues,
            keyTimes: normalizedKeyTimes(for: samples.map(\.relativeTime), duration: duration),
            duration: duration,
            calculationMode: .linear
        )
    }

    @MainActor
    private static func applyDiscreteValues(
        to layer: CALayer,
        keyPath: String,
        frames: [(Double, Any)],
        duration: Double
    ) {
        let compact = compactAnyFrames(frames)
        guard compact.count > 1 else { return }
        applyKeyframeAnimation(
            to: layer,
            keyPath: keyPath,
            values: compact.map(\.value),
            keyTimes: normalizedKeyTimes(for: compact.map(\.time), duration: duration),
            duration: duration,
            calculationMode: .discrete
        )
    }

    @MainActor
    private static func applyKeyframeAnimation(
        to layer: CALayer,
        keyPath: String,
        values: [Any],
        keyTimes: [NSNumber],
        duration: Double,
        calculationMode: CAAnimationCalculationMode
    ) {
        guard values.count > 1, values.count == keyTimes.count else { return }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = duration
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        animation.calculationMode = calculationMode
        layer.add(animation, forKey: keyPath)
    }

    @MainActor
    private static func rasterizedTextImage(
        value: TextFrame,
        spec: TextSpec,
        cache: inout [String: CGImage]
    ) -> CGImage? {
        let key = [
            value.text,
            "\(value.color.r)", "\(value.color.g)", "\(value.color.b)", "\(value.color.a)",
            spec.font.fontName,
            "\(spec.font.pointSize)",
            "\(spec.alignment.rawValue)",
            "\(spec.size.width)x\(spec.size.height)",
            "scale=\(textRenderScale)"
        ].joined(separator: "|")

        if let cached = cache[key] { return cached }

        let alignment: Alignment
        switch spec.alignment {
        case .center:
            alignment = .center
        case .right:
            alignment = .trailing
        default:
            alignment = .leading
        }

        let text = Text(value.text)
            .font(.custom(spec.font.fontName, size: spec.font.pointSize))
            .lineLimit(1)
            .foregroundStyle(Color(nsColor: value.color.nsColor))
            .frame(width: spec.size.width, height: spec.size.height, alignment: alignment)

        let renderer = ImageRenderer(content: text)
        renderer.scale = textRenderScale
        renderer.proposedSize = ProposedViewSize(spec.size)

        let image = renderer.cgImage
        if let image {
            cache[key] = image
        }
        return image
    }

    // MARK: - Visual State

    private static func gearBadgeFrame(for gear: SeiMetadata.Gear?) -> BadgeFrame {
        let text: String
        let color: ColorSpec

        switch gear {
        case .park:
            text = "P"
            color = gray
        case .drive:
            text = "D"
            color = green
        case .reverse:
            text = "R"
            color = red
        case .neutral:
            text = "N"
            color = yellow
        default:
            text = "–"
            color = gray
        }

        return BadgeFrame(
            text: TextFrame(text: text, color: ColorSpec(r: 0, g: 0, b: 0, a: 1)),
            background: color,
            opacity: 1
        )
    }

    private static func autopilotBadgeFrame(for state: SeiMetadata.AutopilotState?) -> BadgeFrame {
        let label: String?
        switch state {
        case .selfDriving: label = "FSD"
        case .autosteer:   label = "AP"
        case .tacc:        label = "TACC"
        default:           label = nil
        }

        return BadgeFrame(
            text: TextFrame(text: label ?? "", color: blue),
            background: ColorSpec(r: blue.r, g: blue.g, b: blue.b, a: 0.25),
            opacity: label == nil ? 0 : 1
        )
    }

    private static func blinkerFrame(isActive: Bool, isBlinkOnPhase: Bool) -> BlinkerFrame {
        let isOn = isActive && isBlinkOnPhase
        return BlinkerFrame(
            capsuleColor: isOn ? yellow : pillFill,
            arrowColor: isOn ? ColorSpec(r: 0, g: 0, b: 0, a: 1) : ColorSpec(r: 1, g: 1, b: 1, a: 0.55),
            scale: isOn ? 1 : 0.94
        )
    }

    private static func pedalIndicatorFrame(isPressed: Bool) -> PedalFrame {
        PedalFrame(
            background: isPressed ? ColorSpec(r: blue.r, g: blue.g, b: blue.b, a: 0.85) : badgeFill,
            groove: isPressed ? textWhite : ColorSpec(r: 1, g: 1, b: 1, a: 0.35),
            scale: isPressed ? 1 : 0.96
        )
    }

    private static func brakeIndicatorFrame(isPressed: Bool) -> PedalFrame {
        PedalFrame(
            background: isPressed ? ColorSpec(r: red.r, g: red.g, b: red.b, a: 0.92) : badgeFill,
            groove: isPressed ? textWhite : ColorSpec(r: 1, g: 1, b: 1, a: 0.35),
            scale: isPressed ? 1 : 0.96
        )
    }

    private static func lateralGForce(for metadata: SeiMetadata?) -> Double {
        guard let metadata else { return 0 }
        return sqrt(
            pow(metadata.linearAccelerationMps2X, 2) +
            pow(metadata.linearAccelerationMps2Y, 2)
        ) / 9.81
    }

    private static func longitudinalGForce(for metadata: SeiMetadata?) -> Double {
        guard let metadata else { return 0 }
        return abs(metadata.linearAccelerationMps2Z) / 9.81
    }

    private static func combinedGForce(for metadata: SeiMetadata) -> Double {
        let lat = lateralGForce(for: metadata)
        let lon = longitudinalGForce(for: metadata)
        return sqrt(lat * lat + lon * lon)
    }

    // MARK: - Drawing Helpers

    private static func steeringWheelPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let midX = rect.midX
        let minY = rect.minY
        let maxY = rect.maxY
        let minX = rect.minX
        let maxX = rect.maxX

        path.move(to: CGPoint(x: midX, y: minY))
        path.addLine(to: CGPoint(x: midX, y: rect.midY + 1))
        path.move(to: CGPoint(x: midX, y: rect.midY + 1))
        path.addLine(to: CGPoint(x: minX + 2, y: maxY - 2))
        path.move(to: CGPoint(x: midX, y: rect.midY + 1))
        path.addLine(to: CGPoint(x: maxX - 2, y: maxY - 2))
        path.addArc(center: CGPoint(x: midX, y: rect.midY + 2), radius: rect.width / 2 - 1.5, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        return path
    }

    private static func blinkerArrowPath(in rect: CGRect, direction: BlinkerDirection) -> CGPath {
        let path = CGMutablePath()
        if direction == .left {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + 1, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }

    private static func markerArrowPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + 1))
        path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 2))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 5))
        path.addLine(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
        path.closeSubpath()
        return path
    }

    private static func makeGraphBackground(
        timeline: [(seconds: Double, metadata: SeiMetadata)],
        duration: Double,
        size: CGSize
    ) -> ExportGraphBackground? {
        guard size.width > 0, size.height > 0, duration > 0, !timeline.isEmpty else { return nil }

        let sampled = sampledSEITimeline(timeline, maxPoints: max(Int(size.width * 2), 320))
        guard sampled.count > 1 else { return nil }

        let speeds = sampled.map { $0.metadata.vehicleSpeedMps }
        let gForces = sampled.map { combinedGForce(for: $0.metadata) }
        let maxSpeed = max(Double(speeds.max() ?? 1.0), 1.0)
        let maxGForce = max(gForces.max() ?? 0.2, 0.2)
        let pad: CGFloat = 6

        func speedPoint(_ sample: (seconds: Double, metadata: SeiMetadata)) -> CGPoint {
            let x = CGFloat(sample.seconds / duration) * size.width
            let speedRatio = CGFloat(Double(sample.metadata.vehicleSpeedMps) / maxSpeed)
            let graphHeight = size.height - pad * 2
            let y = size.height - pad - speedRatio * graphHeight
            return CGPoint(x: x, y: y)
        }

        func gForcePoint(_ sample: (seconds: Double, metadata: SeiMetadata)) -> CGPoint {
            let x = CGFloat(sample.seconds / duration) * size.width
            let gRatio = CGFloat(combinedGForce(for: sample.metadata) / maxGForce)
            let graphHeight = size.height - pad * 2
            let y = size.height - pad - gRatio * graphHeight
            return CGPoint(x: x, y: y)
        }

        let fillPath = CGMutablePath()
        fillPath.move(to: CGPoint(x: 0, y: size.height))
        sampled.forEach { fillPath.addLine(to: speedPoint($0)) }
        if let last = sampled.last {
            fillPath.addLine(to: CGPoint(x: speedPoint(last).x, y: size.height))
        }
        fillPath.closeSubpath()

        let speedLinePath = CGMutablePath()
        for (index, sample) in sampled.enumerated() {
            let point = speedPoint(sample)
            if index == 0 {
                speedLinePath.move(to: point)
            } else {
                speedLinePath.addLine(to: point)
            }
        }

        let gForcePath = CGMutablePath()
        for (index, sample) in sampled.enumerated() {
            let point = gForcePoint(sample)
            if index == 0 {
                gForcePath.move(to: point)
            } else {
                gForcePath.addLine(to: point)
            }
        }

        let brakePath = CGMutablePath()
        var hasBrakeTicks = false
        for sample in sampled where sample.metadata.brakeApplied {
            let x = CGFloat(sample.seconds / duration) * size.width
            brakePath.move(to: CGPoint(x: x, y: size.height - 3))
            brakePath.addLine(to: CGPoint(x: x, y: size.height))
            hasBrakeTicks = true
        }

        return ExportGraphBackground(
            speedFillPath: fillPath,
            speedLinePath: speedLinePath,
            gForcePath: gForcePath,
            brakeTicksPath: hasBrakeTicks ? brakePath : nil,
            maxSpeedText: "\(Int(maxSpeed * 2.237)) mph max",
            maxGForceText: String(format: "%.2fG max", maxGForce)
        )
    }

    private static func sampledSEITimeline(
        _ timeline: [(seconds: Double, metadata: SeiMetadata)],
        maxPoints: Int
    ) -> [(seconds: Double, metadata: SeiMetadata)] {
        guard timeline.count > maxPoints else { return timeline }
        let step = max(1, timeline.count / maxPoints)
        var sampled = stride(from: 0, to: timeline.count, by: step).map { timeline[$0] }
        if let last = timeline.last, sampled.last?.seconds != last.seconds {
            sampled.append(last)
        }
        return sampled
    }

    // MARK: - Route Helpers

    private static func sampleTimes(duration: Double, fps: Double) -> [Double] {
        guard duration > 0 else { return [0] }
        let step = 1 / fps
        var times = stride(from: 0.0, through: duration, by: step).map { min($0, duration) }
        if times.last != duration {
            times.append(duration)
        }
        return times
    }

    private static func trimmedSEISamples(
        config: ExportConfig
    ) -> [(seconds: Double, metadata: SeiMetadata)] {
        config.seiTimeline
            .filter { $0.seconds >= config.inPoint && $0.seconds <= config.outPoint }
            .map { (seconds: $0.seconds - config.inPoint, metadata: $0.metadata) }
    }

    private static func trimmedRouteSamples(config: ExportConfig) -> [RouteSample] {
        resolvedMapRouteSamples(
            seiTimeline: config.seiTimeline,
            gpsTrail: config.gpsTrail,
            from: config.inPoint,
            to: config.outPoint
        )
        .map { RouteSample(seconds: $0.seconds, coordinate: $0.coordinate) }
    }

    private static func visibleTrail(
        in route: [RouteSample],
        upTo absoluteTime: Double
    ) -> [CLLocationCoordinate2D] {
        visibleResolvedMapTrail(
            in: route.map { ResolvedMapRouteSample(seconds: $0.seconds, coordinate: $0.coordinate) },
            upTo: absoluteTime
        )
    }

    private static func mapState(
        at absoluteTime: Double,
        seiTimeline: [(seconds: Double, metadata: SeiMetadata)],
        route: [RouteSample]
    ) -> MapState? {
        if let gps = interpolatedGPSPoint(at: absoluteTime, in: seiTimeline) {
            return MapState(
                coordinate: CLLocationCoordinate2D(latitude: gps.latitude, longitude: gps.longitude),
                heading: gps.heading
            )
        }

        guard let nearest = nearestRouteSample(at: absoluteTime, in: route) else { return nil }
        return MapState(coordinate: nearest.coordinate, heading: 0)
    }

    private static func nearestRouteSample(
        at absoluteTime: Double,
        in route: [RouteSample]
    ) -> RouteSample? {
        guard !route.isEmpty else { return nil }
        var lo = 0
        var hi = route.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if route[mid].seconds < absoluteTime {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo == 0 { return route[0] }
        if lo >= route.count { return route[route.count - 1] }
        let previous = route[lo - 1]
        let next = route[lo]
        return abs(previous.seconds - absoluteTime) <= abs(next.seconds - absoluteTime) ? previous : next
    }

    private static func interpolatedGPSPoint(
        at absoluteTime: Double,
        in timeline: [(seconds: Double, metadata: SeiMetadata)]
    ) -> GPSPoint? {
        guard !timeline.isEmpty else { return nil }

        var lo = 0
        var hi = timeline.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if timeline[mid].seconds < absoluteTime {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        let point: GPSPoint
        if lo == 0 {
            let first = timeline[0].metadata
            point = GPSPoint(latitude: first.latitudeDeg, longitude: first.longitudeDeg, heading: first.headingDeg)
        } else if lo >= timeline.count {
            let last = timeline[timeline.count - 1].metadata
            point = GPSPoint(latitude: last.latitudeDeg, longitude: last.longitudeDeg, heading: last.headingDeg)
        } else {
            let previous = timeline[lo - 1]
            let next = timeline[lo]
            let span = next.seconds - previous.seconds
            let alpha = span > 0 ? min(1, max(0, (absoluteTime - previous.seconds) / span)) : 0
            point = GPSPoint(
                latitude: previous.metadata.latitudeDeg + alpha * (next.metadata.latitudeDeg - previous.metadata.latitudeDeg),
                longitude: previous.metadata.longitudeDeg + alpha * (next.metadata.longitudeDeg - previous.metadata.longitudeDeg),
                heading: lerpAngle(previous.metadata.headingDeg, next.metadata.headingDeg, alpha)
            )
        }

        guard abs(point.latitude) > 0.0001 || abs(point.longitude) > 0.0001 else { return nil }
        return point
    }

    private static func regionForOverview(route: [RouteSample]) -> MKCoordinateRegion {
        let coords = route.map(\.coordinate)
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2,
                longitude: ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.01, ((lats.max() ?? 0) - (lats.min() ?? 0)) * 1.3),
                longitudeDelta: max(0.01, ((lons.max() ?? 0) - (lons.min() ?? 0)) * 1.3)
            )
        )
    }

    private static func mapType(for style: MapStyleOption) -> MKMapType {
        switch style {
        case .standard: return .standard
        case .satellite: return .satellite
        }
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var diff = b - a
        while diff > 180 { diff -= 360 }
        while diff < -180 { diff += 360 }
        return a + t * diff
    }

    private static func unwrapAngles(_ values: [Double]) -> [Double] {
        guard let first = values.first else { return [] }
        var result = [first]
        for angle in values.dropFirst() {
            var adjusted = angle
            var diff = adjusted - result[result.count - 1]
            while diff > 180 { adjusted -= 360; diff = adjusted - result[result.count - 1] }
            while diff < -180 { adjusted += 360; diff = adjusted - result[result.count - 1] }
            result.append(adjusted)
        }
        return result
    }

    private static func normalizedKeyTimes(for times: [Double], duration: Double) -> [NSNumber] {
        guard duration > 0 else { return Array(repeating: 0, count: times.count).map(NSNumber.init(value:)) }
        return times.map { NSNumber(value: min(1, max(0, $0 / duration))) }
    }

    private static func compactDiscreteFrames<T: Hashable>(_ frames: [(time: Double, value: T)]) -> [(time: Double, value: T)] {
        guard let first = frames.first else { return [] }
        var result = [first]
        for frame in frames.dropFirst() where frame.value != result.last?.value {
            result.append(frame)
        }
        return result
    }

    private static func compactAnyFrames(_ frames: [(Double, Any)]) -> [(time: Double, value: Any)] {
        guard let first = frames.first else { return [] }
        var result: [(time: Double, value: Any)] = [(time: first.0, value: first.1)]
        for frame in frames.dropFirst() {
            if !anyValuesEqual(frame.1, result.last?.value) {
                result.append((time: frame.0, value: frame.1))
            }
        }
        return result
    }

    private static func anyValuesEqual(_ lhs: Any, _ rhs: Any?) -> Bool {
        guard let rhs else { return false }
        switch (lhs, rhs) {
        case let (lhs as NSNumber, rhs as NSNumber):
            return lhs == rhs
        case let (lhs as CGColor, rhs as CGColor):
            return lhs == rhs
        case let (lhs as CGPath, rhs as CGPath):
            return lhs == rhs
        case let (lhs as CGImage, rhs as CGImage):
            return lhs === rhs
        case let (lhs as NSValue, rhs as NSValue):
            return lhs == rhs
        default:
            return false
        }
    }
}

// MARK: - Preview

#Preview {
    VideoPlayerView(clip: TeslaClip(
        folderURL: nil,
        title: "Preview",
        date: Date(),
        type: .recent,
        thumbnailURL: nil,
        moments: [],
        durationSeconds: 0
    ))
}
