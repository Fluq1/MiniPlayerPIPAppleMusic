
import SwiftUI
import AppKit
import Combine
import ImageIO

// MARK: - Utilities (Logging & Optimization)

func log(_ msg: String) {
    // Logging disabled by user request
}

func downsample(imageData: Data, to pointSize: CGSize, scale: CGFloat = 2.0) -> NSImage? {
    let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, imageSourceOptions) else { return nil }
    
    let maxDimensionInPixels = max(pointSize.width, pointSize.height) * scale
    let downsampleOptions = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels
    ] as CFDictionary
    
    guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else { return nil }
    return NSImage(cgImage: downsampledImage, size: pointSize)
}

// MARK: - Models

struct PlaylistTrack: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let persistentID: String
}

// MARK: - Music Controller

class MusicController: ObservableObject {
    @Published var songTitle: String = "Connecting..."
    @Published var artistName: String = "Waiting..."
    @Published var albumName: String = ""
    @Published var artworkImage: NSImage? = nil
    @Published var isPlaying: Bool = false
    @Published var errorMessage: String? = nil
    
    // Playlist support
    // Playlist support
    @Published var playlistTracks: [PlaylistTrack] = []
    
    // Playback info
    @Published var duration: Double = 1.0
    @Published var playerPosition: Double = 0.0
    @Published var volume: Int = 50
    @Published var isShuffle: Bool = false
    @Published var repeatMode: String = "off" // off, one, all
    
    private var timer: Timer?
    private var lastArtDataCount: Int = 0
    private var currentPID: String = "" 
    
    private var pollCounter = 0
    private var simulationTimer: Timer?
    
    init() {
        // Initial fetch
        DispatchQueue.global(qos: .userInitiated).async { self.updateStatus() }
        setupNotifications()
        startSimulation()
    }
    
    func setupNotifications() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleMusicNotification),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
    }
    
    @objc func handleMusicNotification() {
        // When Music.app sends an update, refresh our state.
        // We add a small delay to allow file system/metadata to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.updateStatus()
        }
    }
    
    func startSimulation() {
        // Local Dead-Reckoning Timer
        // This does NOT call AppleScript. It simply increments the local counter.
        // Zero CPU cost compared to IPC.
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isPlaying {
                // Determine duration cap
                let maxDur = self.duration > 0 ? self.duration : 100000.0
                if self.playerPosition < maxDur {
                    self.playerPosition += 1.0
                }
            }
        }
    }
    
    // Legacy polling removed in favor of Events + Simulation
    
    func updateStatus(retryCount: Int = 0) {
        let scriptSource = """
        try
            tell application "Music"
                set isPl to (player state is playing)
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set dur to duration of current track
                set pos to player position
                set vol to sound volume
                set shuf to shuffle enabled
                set rep to song repeat
                set pid to persistent ID of current track
                
                set artData to missing value
                try
                    if (count of artworks of current track) > 0 then
                        set artData to data of artwork 1 of current track
                    end if
                end try
                
                return {isPl, t, a, al, artData, dur, pos, vol, shuf, rep, pid}
            end tell
        on error errStr
            return {false, "Error", errStr, "", missing value, 0, 0, 50, false, "off", ""}
        end try
        """
        
        var error: NSDictionary?
        if let script = NSAppleScript(source: scriptSource) {
            let result = script.executeAndReturnError(&error)
            
            DispatchQueue.main.async {
                if let err = error {
                    self.errorMessage = "Script Error: \(err)"
                    return
                }
                
                if result.numberOfItems == 11 {
                    self.errorMessage = nil
                    
                    self.isPlaying = result.atIndex(1)?.booleanValue ?? false
                    let t = result.atIndex(2)?.stringValue ?? "Unknown"
                    let a = result.atIndex(3)?.stringValue ?? "Unknown"
                    let al = result.atIndex(4)?.stringValue ?? ""
                    let artDesc = result.atIndex(5)
                    self.duration = result.atIndex(6)?.doubleValue ?? 1.0
                    self.playerPosition = result.atIndex(7)?.doubleValue ?? 0.0
                    self.volume = Int(result.atIndex(8)?.int32Value ?? 50)
                    self.isShuffle = result.atIndex(9)?.booleanValue ?? false
                    
                    if let repDesc = result.atIndex(10) {
                        // Normalize to lowercase to handle potential "Off"/"All"/"One" capitalization differences
                        self.repeatMode = (repDesc.stringValue ?? "off").lowercased()
                    }
                    
                    let pid = result.atIndex(11)?.stringValue ?? ""
                    
                    if t == "Error" {
                        self.songTitle = "Connection Failed"
                        self.artistName = "Check Permissions"
                        self.artworkImage = nil
                    } else {
                        // Reset art cache if song changed (using Persistent ID for accuracy)
                        // If PID is empty (rare), fall back to title check
                        let songChanged = !pid.isEmpty ? (self.currentPID != pid) : (self.songTitle != t)
                        
                        if songChanged {
                            self.lastArtDataCount = -1 
                            self.currentPID = pid
                            
                            // If song changed, schedule a robust re-check in 2 seconds
                            // to catch slow-loading artwork.
                            // Only retry if we haven't already retried multiple times for this song to avoid loops.
                            if retryCount == 0 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    self.updateStatus(retryCount: 1)
                                }
                            }
                        }
                        
                        self.songTitle = t
                        self.artistName = a
                        self.albumName = al
                        
                        if let data = artDesc?.data {
                            if data.count != self.lastArtDataCount {
                                self.lastArtDataCount = data.count
                                // Try downsampling first for performance
                                if let downsampled = downsample(imageData: data, to: CGSize(width: 300, height: 300)) {
                                    self.artworkImage = downsampled
                                } else {
                                    // Fallback to raw data if downsampling fails
                                    self.artworkImage = NSImage(data: data)
                                }
                            }
                        } else {
                            // If artwork is missing during a fresh load, trigger a retry
                             if self.artworkImage == nil && retryCount < 2 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    self.updateStatus(retryCount: retryCount + 1)
                                }
                            }
                            
                            self.artworkImage = nil
                            self.lastArtDataCount = 0
                        }
                    }
                }
            }
        }
    }
    
    
    func fetchPlaylist() {
        DispatchQueue.global(qos: .userInitiated).async {
            let scriptSource = """
            tell application "Music"
                set nList to name of every track of current playlist
                set idList to persistent ID of every track of current playlist
                return {nList, idList}
            end tell
            """
            
            var error: NSDictionary?
            if let script = NSAppleScript(source: scriptSource) {
                let result = script.executeAndReturnError(&error)
                if error == nil && result.numberOfItems == 2 {
                    if let namesDesc = result.atIndex(1), let idsDesc = result.atIndex(2) {
                        let count = namesDesc.numberOfItems
                        let safeCount = min(count, 500)
                        
                        var newTracks: [PlaylistTrack] = []
                        for i in 1...safeCount {
                            if let n = namesDesc.atIndex(i)?.stringValue,
                               let pid = idsDesc.atIndex(i)?.stringValue {
                                newTracks.append(PlaylistTrack(name: n, persistentID: pid))
                            }
                        }
                        
                        DispatchQueue.main.async {
                            self.playlistTracks = newTracks
                        }
                    }
                }
            }
        }
    }
    
    func playTrack(persistentID: String) {
        run("play (first track whose persistent ID is \"\(persistentID)\")")
    }
    
    func togglePlayPause() { run("playpause") }
    func nextTrack() { run("next track") }
    func previousTrack() { run("previous track") }
    
    // New Control Methods
    func setVolume(_ vol: Int) {
        run("set sound volume to \(vol)")
        self.volume = vol // optimistically update
    }
    
    func seek(to position: Double) {
        run("set player position to \(position)")
        self.playerPosition = position
    }
    
    func toggleShuffle() {
        let newState = !isShuffle
        run("set shuffle enabled to \(newState)")
        self.isShuffle = newState
        
        // Refresh playlist to reflect shuffle state if possible
        // Note: Apple API might not return shuffled order immediately or at all for 'current playlist'
        // but it's worth a refresh.
        self.fetchPlaylist() 
    }
    
    // Mute Logic
    private var preMuteVolume: Int = 50
    var isMuted: Bool { volume == 0 }
    
    func toggleMute() {
        if isMuted {
            // Unmute: restore previous volume (or default to 50 if it was 0)
            let newVol = preMuteVolume > 0 ? preMuteVolume : 50
            setVolume(newVol)
        } else {
            // Mute: save current volume and set to 0
            preMuteVolume = volume
            setVolume(0)
        }
    }
    
    func toggleRepeat() {
        // Cycle: off -> all -> one -> off
        // Normalize current mode
        let current = repeatMode.lowercased()
        
        var nextMode = "off"
        if current == "off" { nextMode = "all" }
        else if current == "all" { nextMode = "one" }
        else { nextMode = "off" }
        
        run("set song repeat to \(nextMode)")
        self.repeatMode = nextMode // Optimistic update
        
        // Force a status update to confirm, as repeat toggles don't always trigger notifications
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.updateStatus()
        }
    }
    
    func run(_ code: String) {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Music\" to \(code)")?.executeAndReturnError(&error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.updateStatus() }
    }
}

// MARK: - Visual Components

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = blendingMode
        view.state = state
        view.material = material
        view.wantsLayer = true
        view.layer?.cornerRadius = 20
        view.layer?.masksToBounds = true
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.callback(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    func onWindow(action: @escaping (NSWindow?) -> Void) -> some View {
        self.background(WindowAccessor(callback: action))
    }
}

// MARK: - Main View

struct PipView: View {
    @StateObject var music = MusicController()
    @State private var isHovering = false
    @State private var window: NSWindow?
    @State private var showPlaylist = false
    @State private var isDarkTheme = true // Default to Dark
    
    var textColor: Color { isDarkTheme ? .white : .black }
    var secondaryTextColor: Color { isDarkTheme ? .white.opacity(0.8) : .black.opacity(0.7) }
    var iconColor: Color { isDarkTheme ? .white : .black }
    var blurMaterial: NSVisualEffectView.Material { isDarkTheme ? .hudWindow : .underWindowBackground }
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                
                if showPlaylist {
                    // MARK: Playlist View
                    VisualEffectView(material: blurMaterial, blendingMode: .behindWindow, state: .active)
                    
                    VStack {
                        HStack {
                            Text("Current Playlist")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(textColor)
                            Spacer()
                            Button(action: { 
                                withAnimation(.spring()) { showPlaylist = false }
                            }) {
                                Image(systemName: "chevron.down.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(secondaryTextColor)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding([.top, .horizontal], 10)
                        
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(music.playlistTracks) { track in
                                    Button(action: {
                                        music.playTrack(persistentID: track.persistentID)
                                    }) {
                                        HStack {
                                            Text(track.name)
                                                .font(.system(size: 11))
                                                .foregroundColor(textColor)
                                                .lineLimit(1)
                                            Spacer()
                                            if track.name == music.songTitle {
                                                Image(systemName: "speaker.wave.2.fill")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(iconColor)
                                            }
                                        }
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 8)
                                        .background(track.name == music.songTitle ? (isDarkTheme ? Color.white.opacity(0.2) : Color.black.opacity(0.1)) : Color.clear)
                                        .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                } else {
                    // MARK: Standard View
                    Group {
                        if let nsImage = music.artworkImage {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .blur(radius: isHovering ? 15 : 0)
                                .opacity(isHovering ? 0.6 : 1.0)
                                .animation(.easeInOut(duration: 0.3), value: isHovering)
                        } else {
                            VisualEffectView(material: blurMaterial, blendingMode: .behindWindow, state: .active)
                            
                            VStack(spacing: 4) {
                                Spacer()
                                Image(systemName: "music.note")
                                    .font(.system(size: 40))
                                    .foregroundColor(secondaryTextColor.opacity(0.5))
                                if let err = music.errorMessage {
                                    Text(err).font(.caption2).foregroundColor(.red).lineLimit(2)
                                }
                                Spacer()
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    
                    // Interaction Layer
                    if isHovering {
                        // Adaptive overlay for better contrast on images
                        // If checking music.artworkImage != nil ? always dark overlay : adaptive overlay
                        let overlayColor = music.artworkImage != nil ? Color.black.opacity(0.4) : (isDarkTheme ? Color.black.opacity(0.4) : Color.white.opacity(0.4))
                        let adaptiveText = music.artworkImage != nil ? Color.white : textColor
                        let adaptiveIcon = music.artworkImage != nil ? Color.white : iconColor
                        let adaptiveSecondary = music.artworkImage != nil ? Color.white.opacity(0.8) : secondaryTextColor
                        
                        RoundedRectangle(cornerRadius: 20).fill(overlayColor)
                        
                        VStack {
                            // Top Controls
                            HStack {
                                Button(action: {
                                    if let win = self.window {
                                        var frame = win.frame
                                        let newHeight: CGFloat = 200
                                        let newY = frame.origin.y + frame.size.height - newHeight
                                        win.setFrame(NSRect(x: frame.origin.x, y: newY, width: 200, height: newHeight), display: true, animate: true)
                                    }
                                }) {
                                    Image(systemName: "arrow.counterclockwise.circle.fill")
                                        .foregroundColor(adaptiveSecondary)
                                }
                                .buttonStyle(.plain)
                                .padding(10)
                                .help("Reset Size")
                                
                                Spacer()
                                
                                // Theme Toggle
                                Button(action: { isDarkTheme.toggle() }) {
                                    Image(systemName: isDarkTheme ? "sun.max.fill" : "moon.fill")
                                        .foregroundColor(adaptiveSecondary)
                                }
                                .buttonStyle(.plain)
                                .padding(10)
                                .help("Toggle Theme")
                                
                                Button(action: { NSApplication.shared.terminate(nil) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(adaptiveSecondary)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 10)
                                .padding(.vertical, 10)
                            }
                            
                            Spacer()
                            
                            // Info & Play Controls
                            VStack(spacing: 2) {
                                Text(music.songTitle)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(adaptiveText)
                                    .lineLimit(1)
                                    .padding(.horizontal)
                                
                                Text(music.artistName)
                                    .font(.system(size: 12))
                                    .foregroundColor(adaptiveSecondary)
                                    .lineLimit(1)
                                    .padding(.horizontal)
                            }
                            
                            // Progress Bar
                            if music.duration > 0 {
                                Slider(value: Binding(
                                    get: { music.playerPosition },
                                    set: { newValue in music.seek(to: newValue) }
                                ), in: 0...music.duration)
                                .accentColor(adaptiveText)
                                .padding(.horizontal, 20)
                                .scaleEffect(0.6) 
                                .frame(height: 10)
                            }
                            
                            HStack(spacing: 15) {
                                // Shuffle
                                Button(action: { music.toggleShuffle() }) {
                                    Image(systemName: "shuffle")
                                        .foregroundColor(music.isShuffle ? adaptiveIcon : adaptiveSecondary.opacity(0.4))
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .help("Shuffle")

                                Button(action: { music.previousTrack() }) { Image(systemName: "backward.fill").foregroundColor(adaptiveIcon) }.buttonStyle(.plain)
                                Button(action: { music.togglePlayPause() }) {
                                    Image(systemName: music.isPlaying ? "pause.fill" : "play.fill").font(.title).foregroundColor(adaptiveIcon)
                                }.buttonStyle(.plain)
                                Button(action: { music.nextTrack() }) { Image(systemName: "forward.fill").foregroundColor(adaptiveIcon) }.buttonStyle(.plain)
                                
                                // Mute Button (Restores Symmetry)
                                Button(action: { music.toggleMute() }) {
                                    Image(systemName: music.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        .foregroundColor(music.isMuted ? .red : adaptiveSecondary.opacity(0.4))
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .help(music.isMuted ? "Unmute" : "Mute")
                            }
                            .padding(.bottom, 10)
                            
                            // Bottom Controls (Playlist & Volume)
                            HStack {
                                Button(action: {
                                    music.fetchPlaylist()
                                    withAnimation(.spring()) { showPlaylist = true }
                                }) {
                                    Image(systemName: "list.bullet.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(adaptiveSecondary)
                                }
                                .buttonStyle(.plain)
                                .help("Playlist")
                                
                                Spacer()
                                
                                // Volume Slider
                                HStack(spacing: 4) {
                                    Image(systemName: "speaker.wave.1.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(adaptiveSecondary)
                                    
                                    Slider(value: Binding(
                                        get: { Double(music.volume) },
                                        set: { newValue in music.setVolume(Int(newValue)) }
                                    ), in: 0...100)
                                    .accentColor(adaptiveText)
                                    .frame(width: 60)
                                    .scaleEffect(0.7)
                                    
                                    Image(systemName: "speaker.wave.3.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(adaptiveSecondary)
                                }
                            }
                            .padding([.bottom, .horizontal], 10)
                        }
                    }
                }
            }
            .onWindow { w in
                self.window = w
                w?.isMovableByWindowBackground = true
            }
            .onHover { h in withAnimation { isHovering = h } }
        }
        .background(Color.clear)
    }
}

// MARK: - Window Classes

class PipWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        self.isMovableByWindowBackground = true
        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.minSize = NSSize(width: 150, height: 150)
        
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            self.setFrameOrigin(NSPoint(x: frame.maxX - 220, y: frame.minY + 40))
        }
    }
    override var canBecomeKey: Bool { return true }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup Window
        window = PipWindow()
        window.contentView = NSHostingView(rootView: PipView())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // Setup Menu Bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "MiniPlayer")
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show MiniPlayer", action: #selector(showApp), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(terminate), keyEquivalent: "q"))
        statusItem.menu = menu
    }
    
    @objc func showApp() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func terminate() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
