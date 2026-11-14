import AppKit
import ScreenSaver

@objc(RaceFlyoverView)
public final class RaceFlyoverView: ScreenSaverView {
    /// Every live instance in this process. The screensaver host creates a new
    /// view each time the preview restarts or settings change, and doesn't always
    /// release the old ones, so we stop the ones it has detached.
    private static let instances = NSHashTable<RaceFlyoverView>.weakObjects()
    private static var nextSerial = 0
    /// Creation order, used to pick which screen leads when screens show the same course.
    private let serial: Int = {
        RaceFlyoverView.nextSerial += 1
        return RaceFlyoverView.nextSerial
    }()

    private let settings = Settings()
    private(set) var config: Config
    private(set) var engine: FlyoverEngine?
    /// Live Apple Maps with 3D terrain and buildings outside legacyScreenSaver.
    private var liveMap: MapFlyoverView?
    /// Flat Apple Maps imagery used by legacyScreenSaver and when the live map can't draw.
    private var tileGround: TileGroundView?
    private let stylized = StylizedView()
    private let glassLayer = GlassPanelsView()
    /// Liquid Glass pin, above the scene and below the overlay panels.
    private let hud = HUDOverlayView()
    private let areaNamer = AreaNamer()
    private let stats = FrameStats()
    /// Set when a newer view has taken over this screen; this one stays dark.
    private var superseded = false
    /// When the latest frame will be on screen.
    private(set) var lastTick: CFTimeInterval = 0
    /// Frame rate asked of the display with "Drop to 30 fps when needed": falls to
    /// 30 if 60 can't be kept up.
    private var linkFPS: Float = 60
    private var rateWindow: (start: CFTimeInterval, frames: Int) = (0, 0)
    /// Display-synchronised clock (falls back to the screensaver timer if the
    /// host never delivers callbacks).
    private var link: CADisplayLink?
    private var lastLinkTick: CFTimeInterval = 0
    /// Set if the live 3D map can't draw in this host; map styles then use flat imagery.
    private var liveFailed = false
    /// Flat imagery chosen on purpose (preview snapshots), so never retry the live map.
    private var flatForced = false
    /// Times the live map has been tried again after falling back (at a new course).
    private var liveRetries = 0
    private var lastCourseID: String?
    /// Set if Apple Maps couldn't produce imagery at all; map styles then use Midnight.
    private var mapFailed = false
    /// Used by the preview app.
    var paused = false

    public override init?(frame: NSRect, isPreview: Bool) {
        config = settings.config
        super.init(frame: frame, isPreview: isPreview)
        Draw.typeface = config.typeface
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        Self.instances.add(self)
        for view in [stylized, glassLayer, hud] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        rebuildEngine()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)
        // legacyScreenSaver keeps running after the screensaver is dismissed on
        // recent macOS versions; stop animating so it doesn't burn CPU or GPU.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenSaverWillStop),
                                                            name: .init("com.apple.screensaver.willstop"), object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Uses the flat Apple Maps imagery instead of the live map (snapshots: the
    /// live map's Metal surface can't be captured).
    func useFlatMapImagery() {
        flatForced = true
        liveFailed = true
        installContent()
    }

    /// Set once the preview app overrides options from the command line, so
    /// saved settings don't replace them.
    private var hasOverrides = false

    /// Overrides options without saving them (preview app snapshots).
    func override(_ change: (inout Config) -> Void) {
        hasOverrides = true
        change(&config)
        applyConfig()
    }

    private func rebuildEngine() {
        let playlist = CourseLibrary.playlist(for: config.selection, settings: settings)
        guard !playlist.isEmpty else { return }
        let start = playlist.count > 1 ? Int.random(in: 0..<playlist.count) : 0
        engine = FlyoverEngine(playlist: playlist, config: config, startIndex: start)
        installContent()
        animationTimeInterval = 1.0 / Double(config.frameRate.rawValue)
    }

    private func applyConfig() {
        Draw.typeface = config.typeface
        let playlist = CourseLibrary.playlist(for: config.selection, settings: settings)
        if let engine {
            engine.update(playlist: playlist, config: config)
        } else {
            rebuildEngine()
        }
        installContent()
        animationTimeInterval = 1.0 / Double(config.frameRate.rawValue)
        // New settings: give 60 fps another chance.
        linkFPS = 60
        rateWindow = (0, 0)
        updateLinkRate()
        renderFrame()
    }

    @objc private func settingsChanged() {
        config = settings.config
        applyConfig()
    }

    @objc private func screenSaverWillStop() {
        guard !isPreview else { return }
        stopAnimationIfNeeded()
    }

    // MARK: - Content

    /// Map styles use Apple Maps except in the tiny System Settings thumbnail,
    /// which shows the Midnight look instead.
    private var wantsMap: Bool {
        config.style.usesTiles && !isPreview && !mapFailed && window != nil && bounds.width > 200
    }
    /// legacyScreenSaver can report a fully loaded map while compositing no imagery.
    /// Offscreen snapshots don't depend on the host window's Metal surface or visibility.
    private var wantsLive: Bool {
        wantsMap && !liveFailed && ProcessInfo.processInfo.processName != "legacyScreenSaver"
    }
    private var wantsTiles: Bool { wantsMap && !wantsLive }

    /// With "main display only", every other screen stays black and does no work.
    private var isIdleScreen: Bool {
        guard !isPreview, config.displays == .mainOnly, let screen = window?.screen else { return false }
        return screen != NSScreen.screens.first
    }

    /// The instance other screens follow when showing the same course.
    private var leader: RaceFlyoverView? {
        guard config.displays == .same, !isPreview else { return nil }
        let earliest = Self.instances.allObjects
            .filter { $0 !== self && !$0.isPreview && $0.window != nil && $0.isAnimating && !$0.isIdleScreen && $0.engine != nil }
            .min { $0.serial < $1.serial }
        guard let earliest, earliest.serial < serial else { return nil }
        return earliest
    }

    private func installContent() {
        guard let engine else { return }
        let idle = isIdleScreen
        for v in [stylized, glassLayer, hud] as [NSView] { v.isHidden = idle }
        if idle {
            tearDownLiveMap()
            tileGround?.removeFromSuperview()
            tileGround = nil
            return
        }
        if wantsLive {
            Self.reapOrphans()
            if liveMap == nil {
                let v = MapFlyoverView(frame: bounds)
                v.autoresizingMask = [.width, .height]
                v.onFailure = { [weak self] in
                    MapFlyoverView.log.notice("using flat imagery until the next course")
                    self?.liveFailed = true
                    self?.installContent()
                }
                addSubview(v, positioned: .below, relativeTo: stylized)
                liveMap = v
            }
            liveMap?.engine = engine
        } else {
            tearDownLiveMap()
        }
        stylized.isHidden = wantsLive
        if wantsTiles {
            if tileGround == nil {
                let v = TileGroundView(frame: bounds)
                v.autoresizingMask = [.width, .height]
                v.onFailure = { [weak self] in
                    self?.mapFailed = true
                    self?.installContent()
                }
                addSubview(v, positioned: .below, relativeTo: stylized)
                tileGround = v
            }
            tileGround?.style = config.style
        } else {
            tileGround?.removeFromSuperview()
            tileGround = nil
        }
        let theme = Theme.forStyle(config.style.usesTiles && !wantsMap ? .midnight : config.style)
            .with(pin: config.pinColor, trail: config.trailColor)
        stylized.engine = engine
        stylized.theme = theme
        stylized.tileMode = wantsTiles
        stylized.attribution = tileGround?.attribution
        stylized.isThumbnail = isPreview
        stylized.glassPin = config.pinStyle.usesGlass
        hud.engine = engine
        hud.area = isPreview ? nil : areaNamer
        hud.theme = theme
        hud.isThumbnail = isPreview
        hud.usesGlass = config.panels.usesGlass
        glassLayer.clear = config.panels == .clearGlass
        glassLayer.isHidden = !config.panels.usesGlass || isPreview
        // Glass follows the chosen look (light glass on light maps), not the system's appearance.
        glassLayer.appearance = NSAppearance(named: theme.isLight ? .aqua : .darkAqua)
    }

    private func tearDownLiveMap() {
        guard let liveMap else { return }
        liveMap.shutDown()
        liveMap.removeFromSuperview()
        self.liveMap = nil
    }

    /// Stops instances the host has detached but kept alive, and frees their maps.
    private static func reapOrphans() {
        for view in instances.allObjects where view.window == nil {
            view.stopAnimationIfNeeded()
            view.tearDownLiveMap()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimationIfNeeded()
            tearDownLiveMap()
        } else {
            Self.reapOrphans()
            if isAnimating { claimScreen() }
            installContent()
            if isAnimating { startLink() }
        }
    }

    private var targetFPS: Float {
        config.frameRate == .fps60 && config.adaptiveFPS ? linkFPS : Float(config.frameRate.rawValue)
    }

    private func startLink() {
        guard link == nil, window != nil else { return }
        if #available(macOS 14.0, *) {
            let l = displayLink(target: self, selector: #selector(linkTick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: min(24, targetFPS), maximum: targetFPS, preferred: targetFPS)
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    private func updateLinkRate() {
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(24, targetFPS), maximum: targetFPS, preferred: targetFPS)
    }

    @objc private func linkTick(_ l: CADisplayLink) {
        lastLinkTick = CACurrentMediaTime()
        // Advance to when this frame will actually be on screen, so motion is
        // even regardless of when the callback ran.
        advance(to: l.targetTimestamp)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The host sometimes creates the view at 0×0 and resizes it later.
        if config.style.usesTiles && (liveMap == nil) == wantsLive { installContent() }
    }

    // MARK: - Animation

    private func stopAnimationIfNeeded() {
        if isAnimating { stopAnimation() }
    }

    public override func startAnimation() {
        super.startAnimation()
        lastTick = 0
        claimScreen()
        startLink()
        // Settings may have changed in another process (System Settings) since
        // this instance was created.
        let latest = settings.config
        if !hasOverrides && latest != config {
            config = latest
            applyConfig()
        }
    }

    public override func stopAnimation() {
        super.stopAnimation()
        link?.invalidate()
        link = nil
    }

    /// The host can keep an older view attached to a hidden window and still
    /// animating, which doubles the map rendering. The newest view on a screen
    /// wins; older ones on the same screen stop and release their maps.
    /// Lets two views share a screen (the preview app's multi-screen test).
    static var allowSharedScreen = false

    private func claimScreen() {
        guard !isPreview, !Self.allowSharedScreen, let window else { return }
        superseded = false
        for other in Self.instances.allObjects where other !== self && !other.isPreview && other.serial < serial {
            if other.window == nil || other.window?.screen == window.screen {
                other.retire()
            }
        }
    }

    private func retire() {
        guard !superseded else { return }
        superseded = true
        stopAnimationIfNeeded()
        tearDownLiveMap()
        tileGround?.removeFromSuperview()
        tileGround = nil
        MapFlyoverView.log.notice("view #\(self.serial, privacy: .public) retired: a newer view took over its screen")
    }

    public override func animateOneFrame() {
        // The display link drives frames when it's running; this timer is the fallback.
        if CACurrentMediaTime() - lastLinkTick < 0.5 { return }
        advance(to: CACurrentMediaTime())
    }

    private func advance(to time: CFTimeInterval) {
        let dt = lastTick == 0 ? 0 : max(0, time - lastTick)
        lastTick = time
        guard window != nil, !isIdleScreen, !superseded else { return }
        FrameStats.shared = stats
        if dt > 0 { stats.frame(interval: dt) }
        if let engine {
            let landmarksReady = !config.showLandmarks || liveMap == nil || LandmarkStore.shared.isResolved(engine.course)
            engine.sceneReady = (liveMap?.isSettled ?? true) && landmarksReady
        }
        let wasIntro = engine?.phase == .intro, introTime = engine?.phaseTime ?? 0
        if !paused { engine?.step(min(0.25, dt)) }
        if wasIntro, let engine, engine.phase == .running {
            let held = max(0, introTime - FlyoverEngine.introDuration)
            MapFlyoverView.log.notice("\(engine.course.id, privacy: .public): run started after waiting \(String(format: "%.1f", held), privacy: .public) s for the scene to load (ready=\(engine.sceneReady, privacy: .public); map: \(self.liveMap?.loadState ?? "none", privacy: .public); landmarks=\(LandmarkStore.shared.isResolved(engine.course), privacy: .public))")
        }
        retryLiveMapIfNewCourse()
        if let leader = leader, let lead = leader.engine, let engine {
            engine.sync(to: lead, lag: time - leader.lastTick)
        }
        stats.measure("renderFrame") { renderFrame() }
        adaptFrameRate(at: time)
        let screen = window?.screen.map { ($0 == NSScreen.screens.first ? "main:" : "") + $0.localizedName } ?? "?"
        stats.reportIfDue(label: "view#\(serial) [\(screen)\(leader == nil ? "" : ", following #\(leader!.serial)")] \(config.style.rawValue)\(config.map3D ? "" : "-flat") \(Int(targetFPS))fps-target \(Int(bounds.width))x\(Int(bounds.height))")
    }

    /// After falling back to flat imagery, give the 3D map another go when the
    /// next course starts (the problem is often passing), a few times at most.
    private func retryLiveMapIfNewCourse() {
        let id = engine?.course.id
        defer { lastCourseID = id }
        guard id != lastCourseID, lastCourseID != nil, liveFailed, !flatForced, liveRetries < 3 else { return }
        liveRetries += 1
        liveFailed = false
        MapFlyoverView.log.notice("new course: trying the live 3D map again (retry \(self.liveRetries, privacy: .public))")
        installContent()
    }

    /// When the option is on: a steady 30 fps looks smoother than an uneven 40,
    /// so if 60 isn't being kept up (two big screens of 3D map can be too
    /// much), settle at 30.
    private func adaptFrameRate(at time: CFTimeInterval) {
        guard config.frameRate == .fps60, config.adaptiveFPS, linkFPS > 30, link != nil else { return }
        // Judge only the steady part of a run, not the map loading at the start.
        guard engine?.phase == .running else { rateWindow = (0, 0); return }
        if rateWindow.start == 0 || time - rateWindow.start > 30 { rateWindow = (time, 0); return }
        rateWindow.frames += 1
        let elapsed = time - rateWindow.start
        guard elapsed >= 4 else { return }
        let fps = Double(rateWindow.frames) / elapsed
        rateWindow = (time, 0)
        if fps < 50 {
            linkFPS = 30
            updateLinkRate()
            MapFlyoverView.log.notice("view #\(self.serial, privacy: .public) managed \(Int(fps), privacy: .public) fps of 60; settling at a steady 30")
        }
    }

    func renderFrame() {
        guard let engine else { needsDisplay = true; return }
        engine.aspect = Double(bounds.width / max(bounds.height, 1))
        if !isPreview && config.hud == .full && engine.phase != .intro {
            areaNamer.update(courseID: engine.course.id, coordinate: engine.course.sample(at: engine.distance).coordinate,
                             now: CACurrentMediaTime())
        }
        if let liveMap { stats.measure("mapCamera") { liveMap.render() } }
        tileGround?.update(camera: engine.camera, course: engine.course)
        if liveMap == nil { stylized.needsDisplay = true }
        hud.refresh()
        // Glass follows the panel positions from the HUD's previous draw (one
        // frame behind, which is invisible at these speeds).
        glassLayer.update(hud.usesGlass ? hud.glassPanels : [])
    }

    public override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
        if engine == nil {
            let msg = Draw.text("No courses found in the screensaver bundle.", size: 16, color: .white)
            Draw.string(msg, at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: 0.5)
        }
    }

    // MARK: - Options sheet

    public override var hasConfigureSheet: Bool { true }

    /// System Settings may ask for the sheet more than once; always hand back the
    /// same window, kept alive by this view, with its controls refreshed.
    public override var configureSheet: NSWindow? {
        // One Options window for the whole process. System Settings makes a new
        // copy of the screensaver each time Options is clicked, so a window per
        // copy left earlier ones behind, sometimes still attached to the last
        // session, and the next one could come up unresponsive. Before handing
        // the window over, make sure it's fully detached from any earlier use.
        let controller = Self.sharedSheet ?? ConfigSheetController(settings: settings)
        Self.sharedSheet = controller
        let window = controller.window
        if let parent = window.sheetParent { parent.endSheet(window) }
        if window.isVisible { window.orderOut(nil) }
        controller.prepare()
        MapFlyoverView.log.notice("options requested (view #\(self.serial, privacy: .public), preview=\(self.isPreview, privacy: .public))")
        return window
    }

    /// The Options sheet shared by every copy of the screensaver in this process.
    private static var sharedSheet: ConfigSheetController?
}
