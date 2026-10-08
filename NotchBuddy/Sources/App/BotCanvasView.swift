import SwiftUI

/// SwiftUI wrapper: TimelineView drives a Canvas that calls BotEngine.draw().
/// Uses a shared engine per-task; the main bot uses AppState's shared engine.
struct BotCanvasView: View {
    @ObservedObject var state: AppState
    var particleOverhang: CGFloat = 0
    /// When set, overrides island-based eye-tracking (used by desktop Mochi).
    /// CGPoint in the same coord space as state.mousePosition (DesktopSpace, y-down).
    var lookOriginOverride: CGPoint? = nil

    // One engine per view instance (main bot)
    @StateObject private var engine = BotEngine()

    private var canvasContent: some View {
        TimelineView(.animation(paused: state.mode == .hidden)) { timeline in
            Canvas { context, size in
                var ctx = context
                drawBot(context: &ctx, size: size, date: timeline.date)
            }
        }
    }

    var body: some View {
        canvasContent
            .modifier(BotCanvasStateModifier(engine: engine, state: state))
            .modifier(BotCanvasNotificationsModifier(engine: engine))
            .onAppear {
                engine.setState(state.effectiveState, force: true)
                let isWardrobe = state.mode == .expanded && state.view == .wardrobe
                let isFocusMain = state.focusId == state.mainPillId || state.focusId == nil
                let showOutfit = isFocusMain || state.mode != .expanded || isWardrobe
                engine.setOutfit(showOutfit ? state.resolvedOutfit : .none, animated: false)
            }
    }

    private func lookX(state: AppState, size: CGSize) -> CGFloat {
        if let origin = lookOriginOverride {
            return tanh((state.mousePosition.x - origin.x) / 260)
        }
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             progress: state.uploadProgress,
                                             nw: state.notchWidth, nh: state.notchHeight)
        let (botCx, botCy, _, _) = botPosition(mode: state.mode, view: state.view,
                                                islandW: islandW, islandH: islandH,
                                                uploadProgress: state.uploadProgress)
        let bot = islandBotPoint(islandW: islandW, botCx: botCx, botCy: botCy)
        return tanh((state.mousePosition.x - bot.x) / 260)
    }

    /// Bot centre in DesktopSpace, like state.mousePosition. The island is centred at the
    /// top of its screen, which can be any display, anywhere in the arrangement.
    private func islandBotPoint(islandW: CGFloat, botCx: CGFloat, botCy: CGFloat) -> CGPoint {
        let screen = IslandWindowController.islandScreen().frame
        return DesktopSpace.topDown(CGPoint(x: screen.midX - islandW / 2 + botCx,
                                            y: screen.maxY - botCy),
                                    desktopTop: IslandWindowController.desktopTop)
    }

    private func lookY(state: AppState, size: CGSize) -> CGFloat {
        if let origin = lookOriginOverride {
            return -tanh((state.mousePosition.y - origin.y) / 200)
        }
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             progress: state.uploadProgress,
                                             nw: state.notchWidth, nh: state.notchHeight)
        let actualH: CGFloat = (state.mode == .expanded && state.view == .prompt)
            ? min(300, 240 + CGFloat(state.chatHistory.count) * 40)
            : islandH
        let (botCx, botCy, _, _) = botPosition(mode: state.mode, view: state.view,
                                                islandW: islandW, islandH: actualH,
                                                uploadProgress: state.uploadProgress)
        let bot = islandBotPoint(islandW: islandW, botCx: botCx, botCy: botCy)
        return -tanh((state.mousePosition.y - bot.y) / 200)
    }

    private func computeBodyColor() -> CGColor? {
        #if !APPSTORE
        if state.showingPlanDetail {
            let hex = state.planDetailIsCodex
                ? CodexPlanGauge.color(state.codexPlanUsage)
                : ClaudePlanGauge.color(for: state.claudePlanUsage.flatMap { ClaudePlanGauge.dominantPct($0) })
            return cgColorFromHex(hex)
        }
        #endif

        if let task = state.focusTask, task.isIntegration, task.source != .claudeCode, task.id != "integration_claude" {
            return cgColorFromHex(task.color)
        }
        return nil
    }

    private func computeDancing() -> Bool {
        #if !APPSTORE
        let active = AppState.shared.activeIntegrations
        let music = AppState.shared.musicPlaying && active.contains("integration_music")
        let spotify = SpotifyController.shared.isPlaying && active.contains(SpotifyController.pillId)
        guard music || spotify else { return false }
        let allowed: Set<BotState> = [.idle, .working, .thinking, .searching, .finished]
        guard allowed.contains(state.effectiveState) else { return false }
        if state.mode == .compact { return true }
        guard state.mode == .expanded && state.view == .overview else { return false }
        return (music && state.focusId == "integration_music")
            || (spotify && state.focusId == SpotifyController.pillId)
        #else
        return false
        #endif
    }

    private func drawBot(context: inout GraphicsContext, size: CGSize, date: Date) {
        let now = date.timeIntervalSinceReferenceDate
        let dt = min(0.05, now - engine.lastTime)
        engine.lookX = lookX(state: state, size: size)
        engine.lookY = lookY(state: state, size: size)
        engine.particleOverhang = particleOverhang
        if engine.morph > 0.3 {
            engine.slotHTarget = state.fileDragOver ? 0.20 : 0
        } else {
            engine.slotHTarget = 0
            if engine.morph < 0.05 { engine.slotH = 0; engine.slotHVel = 0 }
        }
        engine.bodyColor = computeBodyColor()
        engine.setDancing(computeDancing())
        let isWardrobe = state.mode == .expanded && state.view == .wardrobe
        let isFocusMain = state.focusId == state.mainPillId || state.focusId == nil
        let showOutfit = isFocusMain || state.mode != .expanded || isWardrobe
        engine.setOutfit(showOutfit ? state.resolvedOutfit : .none,
                         animated: state.view != .wardrobe)

        engine.update(dt: dt)
        engine.applyDance(&context, size: size)
        if engine.outfit != .none && engine.outfitPresence > 0.05 && abs(engine.roll) > 0.001 {
            let center = engine.bodyCenter(size: size)
            var rigidCtx = context
            rigidCtx.translateBy(x: center.x, y: center.y)
            rigidCtx.rotate(by: .radians(engine.roll))
            rigidCtx.translateBy(x: -center.x, y: -center.y)
            engine.drawHandsBehind(context: rigidCtx, size: size)
            engine.drawOutfitBehind(context: rigidCtx, size: size)
            engine.draw(context: rigidCtx, size: size)
            engine.drawOutfitFront(context: rigidCtx, size: size)
        } else {
            engine.drawHandsBehind(context: context, size: size)
            engine.drawOutfitBehind(context: context, size: size)
            engine.draw(context: context, size: size)
            engine.drawOutfitFront(context: context, size: size)
        }
        engine.drawHandsAndExtras(context: context, size: size)
    }
}

private struct BotCanvasStateModifier: ViewModifier {
    let engine: BotEngine
    @ObservedObject var state: AppState

    func body(content: Content) -> some View {
        content
            .onChange(of: state.effectiveState) { _, newState in
                engine.setState(newState)
            }
            .onChange(of: state.view) { _, newView in
                // Morph up when upload view is active
                if state.mode == .expanded && newView == .upload {
                    engine.anim("morph", keys: [TweenKey(target: 1, duration: 550, ease: Ease.inOut)])
                } else if newView != .upload && newView != .uploading && engine.morph > 0.01 {
                    // Any other view (not mid-gulp): morph back
                    engine.anim("morph", keys: [TweenKey(target: 0, duration: 550, ease: Ease.inOut)])
                }
            }
            .onChange(of: state.mode) { _, newMode in
                // Hard-reset morph when island collapses
                if newMode != .expanded {
                    engine.tweens.removeValue(forKey: "morph")
                    engine.locks.remove("morph")
                    engine.morph = 0
                }
            }
    }
}

private struct BotCanvasNotificationsModifier: ViewModifier {
    let engine: BotEngine

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .triggerEmote)) { notif in
                if let emote = notif.object as? BotEmote {
                    engine.triggerEmote(emote)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .triggerSlap)) { _ in
                engine.slap()
            }
            .onReceive(NotificationCenter.default.publisher(for: .botBlink)) { _ in
                engine.blink()
            }
            .onReceive(NotificationCenter.default.publisher(for: .botSetTgEs)) { notif in
                if let v = notif.object as? CGFloat {
                    engine.tgEs = v
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .botGulp)) { _ in
                engine.gulp()
            }
            .onReceive(NotificationCenter.default.publisher(for: .botMorphTo)) { notif in
                if let target = notif.object as? CGFloat {
                    let dur: CGFloat = target > 0.5 ? 550 : 650
                    engine.anim("morph", keys: [TweenKey(target: target, duration: dur, ease: Ease.inOut)])
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in
                engine.greet()
            }
            .onReceive(NotificationCenter.default.publisher(for: .botWakeUp)) { _ in
                engine.wakeUp()
            }
    }
}

/// Mini bot canvas (for agent pills/column)
struct MiniBotCanvasView: View {
    let task: AgentTask
    var isDancing: Bool = false
    @StateObject private var engine: BotEngine

    init(task: AgentTask, isDancing: Bool = false) {
        self.task = task
        self.isDancing = isDancing
        _engine = StateObject(wrappedValue: {
            let e = BotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex(task.color)
            return e
        }())
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dt = min(0.05, now - engine.lastTime)
                engine.setDancing(isDancing)
                engine.update(dt: dt)
                var ctx = context
                engine.applyDance(&ctx, size: size)
                engine.draw(context: ctx, size: size)
            }
        }
        .onChange(of: task.state) { _, newState in
            engine.setState(newState)
        }
        // The colour is set once, when the engine is made: a colour picked in
        // Settings has to reach a mini Mochi that is already on screen.
        .onChange(of: task.color) { _, newColor in
            engine.bodyColor = cgColorFromHex(newColor)
        }
        .onAppear {
            engine.setState(task.state, force: true)
            if let emote = task.emote {
                engine.setPermanentEmote(emote)
            }
            // Direct eye override takes priority (e.g. .wide eyes for Research)
            if let eye = task.miniEye {
                engine.permanentEye = eye
                engine.eyeOverride = eye
                engine.eyeOverrideUntil = .greatestFiniteMagnitude
            }
        }
    }
}
