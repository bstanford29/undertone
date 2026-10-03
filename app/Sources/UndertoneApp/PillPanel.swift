import AppKit
import Combine
import SwiftUI

/// A nonactivating panel that the user drags by its background. The panel
/// never becomes key or main, so a click on it cannot steal focus from the
/// frontmost app. Mouse tracking happens in `sendEvent` so the SwiftUI
/// content cannot swallow the drag.
final class DraggablePillPanel: NSPanel {
    /// Mouse-down inside the panel, with the cursor in screen coordinates.
    var onDragBegin: ((CGPoint) -> Void)?
    /// Cursor moved while the button is down.
    var onDragMove: ((CGPoint) -> Void)?
    /// Mouse-up, ending the drag.
    var onDragEnd: ((CGPoint) -> Void)?
    /// Escape pressed while dragging.
    var onDragCancel: (() -> Void)?
    /// A right click, which opens the Flow menu.
    var onRightClick: ((NSEvent) -> Void)?

    private var isTracking = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            isTracking = true
            onDragBegin?(NSEvent.mouseLocation)
            return
        case .leftMouseDragged where isTracking:
            onDragMove?(NSEvent.mouseLocation)
            return
        case .leftMouseUp where isTracking:
            isTracking = false
            onDragEnd?(NSEvent.mouseLocation)
            return
        case .rightMouseDown:
            onRightClick?(event)
            return
        case .keyDown where isTracking && event.keyCode == 53:
            isTracking = false
            onDragCancel?()
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, isTracking else {
            super.keyDown(with: event)
            return
        }
        isTracking = false
        onDragCancel?()
    }

    /// Stops tracking when the drag is cancelled from outside the panel,
    /// for example by the controller's Escape monitor.
    func stopTracking() {
        isTracking = false
    }
}

/// Hosts the dock's SwiftUI content and reports where the pointer is. The
/// tracking area is `.activeAlways` because the panel is never key: without
/// it the dock would only open while Undertone is the frontmost app.
final class DockTrackingView: NSView {
    /// The pointer in panel coordinates, or nil once it leaves the panel.
    var onPointer: ((CGPoint?) -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { onPointer?(nil) }

    private func report(_ event: NSEvent) {
        onPointer?(convert(event.locationInWindow, from: nil))
    }
}

/// A transparent, click-through panel that never activates. It hosts the
/// drop-zone outlines shown behind the pill during a drag.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Everything the dock's views read that is not in `AppModel`: where the
/// pointer is, whether the controls are fanned out, and the drag chrome.
@MainActor
final class FlowBarChrome: ObservableObject {
    @Published var hovered: DockControl?
    @Published var open = false
    @Published var lifted = false
    @Published var pulse: CGFloat = 1.0

    var scale: CGFloat { (lifted ? 1.06 : 1.0) * pulse }
}

/// The four drop zones and which one is armed.
@MainActor
final class DropZoneChrome: ObservableObject {
    @Published var zones: [PillDropZone] = []
    @Published var armedEdge: PillEdge?
    @Published var visible = false
    /// The screen frame the zone rects are expressed in.
    @Published var screenFrame: CGRect = .zero
}

/// Shows the drop-zone outlines on the screen under the cursor while the
/// pill is dragged.
@MainActor
final class DropZoneOverlayController {
    private let chrome = DropZoneChrome()
    private let panel: OverlayPanel

    init() {
        panel = OverlayPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        // One level below the pill so the pill always draws on top.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: DropZoneOverlayView(chrome: chrome))
    }

    /// Places the overlay on `screen` and fades the zones in.
    func show(zones: [PillDropZone], on screen: NSScreen) {
        chrome.zones = zones
        chrome.armedEdge = nil
        chrome.screenFrame = screen.frame
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        chrome.visible = true
    }

    func setArmed(_ edge: PillEdge?) {
        guard chrome.armedEdge != edge else { return }
        chrome.armedEdge = edge
    }

    /// Fades the zones out, then hides the panel.
    func hide() {
        guard chrome.visible else { return }
        chrome.visible = false
        chrome.armedEdge = nil
        let panel = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }
}

/// Capsule outlines at the four docked positions, drawn in the overlay
/// panel's top-left coordinate space.
struct DropZoneOverlayView: View {
    @ObservedObject var chrome: DropZoneChrome

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(chrome.zones) { zone in
                let armed = chrome.armedEdge == zone.edge
                RoundedRectangle(cornerRadius: min(zone.rect.width, zone.rect.height) / 2, style: .continuous)
                    .fill(Color.white.opacity(armed ? 0.18 : 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: min(zone.rect.width, zone.rect.height) / 2, style: .continuous)
                            .strokeBorder(Color.white.opacity(armed ? 0.80 : 0.35), lineWidth: 1.5)
                    )
                    .frame(width: zone.rect.width, height: zone.rect.height)
                    .scaleEffect(armed ? 1.08 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: armed)
                    .offset(
                        x: zone.rect.minX - chrome.screenFrame.minX,
                        y: chrome.screenFrame.maxY - zone.rect.maxY
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(chrome.visible ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: chrome.visible)
        .allowsHitTesting(false)
    }
}

/// Turns the model plus the pointer into the one thing the dock draws.
@MainActor
enum FlowBarState {
    static func viewState(model: AppModel, hovered: DockControl?, open: Bool) -> FlowBarViewState {
        switch model.pillState {
        case .idle:
            return open ? .hover(hovered) : .nub
        case .meetingDetected(let detected):
            return .nudge(detected)
        default:
            guard let spec = FlowBarDock.ribbon(for: model.ribbonInputs) else { return .nub }
            return .ribbon(spec)
        }
    }
}

@MainActor
final class PillPanelController {
    private let panel: DraggablePillPanel
    private let model: AppModel
    private let chrome = FlowBarChrome()
    private let overlay = DropZoneOverlayController()
    private let tracking = DockTrackingView()
    private var subscriptions = Set<AnyCancellable>()
    private lazy var menuBuilder = FlowMenuBuilder { [weak self] command in self?.model.runFlowMenu(command) }

    private var dragState: PillDragState?
    private var dragZones: [PillDropZone] = []
    private var dragScreen: NSScreen?
    private var escapeMonitors: [Any] = []
    private var dockEscapeMonitors: [Any] = []
    /// Set while the drop animation runs so state updates do not fight it.
    private var isSettling = false

    private var intent = DockHoverIntent()
    private var openTimer: DispatchWorkItem?
    private var closeTimer: DispatchWorkItem?
    /// The panel-local point the current press started at, for click routing.
    private var pressPoint: CGPoint?

    private static let settleDuration: TimeInterval = 0.26
    private static let liftDuration: TimeInterval = 0.12

    init(model: AppModel) {
        self.model = model
        panel = DraggablePillPanel(
            contentRect: NSRect(origin: .zero, size: FlowBarDock.panelSize(for: .nub, edge: .bottom)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The shadow is drawn in SwiftUI so it can rise with the lift.
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: FlowBarDockView(chrome: chrome).environmentObject(model))
        hosting.autoresizingMask = [.width, .height]
        tracking.addSubview(hosting)
        hosting.frame = tracking.bounds
        panel.contentView = tracking
        tracking.onPointer = { [weak self] point in self?.pointerMoved(to: point) }

        panel.onDragBegin = { [weak self] cursor in self?.beginDrag(cursor: cursor) }
        panel.onDragMove = { [weak self] cursor in self?.moveDrag(cursor: cursor) }
        panel.onDragEnd = { [weak self] cursor in self?.endDrag(cursor: cursor) }
        panel.onDragCancel = { [weak self] in self?.cancelDrag() }
        panel.onRightClick = { [weak self] event in self?.showFlowMenu(event) }
        model.$pillState.sink { [weak self] state in
            MainActor.assumeIsolated { self?.pillStateChanged(to: state) }
        }.store(in: &subscriptions)
        // Anything that changes what the ribbon holds changes its width, so
        // the panel has to resize with it.
        let resize: () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        }
        model.$pillEdge.sink { _ in resize() }.store(in: &subscriptions)
        model.$pillOffset.sink { _ in resize() }.store(in: &subscriptions)
        model.$pillPersistent.sink { _ in resize() }.store(in: &subscriptions)
        model.$pillHiddenUntil.sink { _ in resize() }.store(in: &subscriptions)
        model.$commandMode.sink { _ in resize() }.store(in: &subscriptions)
        model.$dictationLocked.sink { _ in resize() }.store(in: &subscriptions)
        model.$workingNote.sink { _ in resize() }.store(in: &subscriptions)
        model.$errorOffersRetry.sink { _ in resize() }.store(in: &subscriptions)
        model.$dictationTargetBundleID.sink { _ in resize() }.store(in: &subscriptions)
        model.meetings.$lastAutoStop.sink { _ in resize() }.store(in: &subscriptions)
        update()
    }

    // MARK: - Placement

    private var viewState: FlowBarViewState {
        FlowBarState.viewState(model: model, hovered: chrome.hovered, open: intent.isOpen)
    }

    private func pillStateChanged(to state: PillState) {
        // Anything but idle replaces the capsule, so the hover intent must
        // not keep it alive underneath a ribbon.
        if state != .idle, intent.isOpen {
            _ = intent.forceClosed()
            cancelHoverTimers()
            chrome.open = false
            chrome.hovered = nil
            removeDockEscapeMonitors()
        }
        if state == .idle { model.setPillHovered(false) }
        update()
    }

    private func update() {
        guard let screen = dockingScreen() else { panel.orderOut(nil); return }
        let resting = model.pillState == .idle
        guard !resting || (model.pillPersistent && !model.pillHidden) else {
            panel.orderOut(nil)
            return
        }
        place(in: screen.visibleFrame)
        panel.orderFrontRegardless()
        syncHover()
    }

    private func place(in visibleFrame: CGRect) {
        guard !isSettling, dragState == nil else { return }
        let size = FlowBarDock.panelSize(for: viewState, edge: model.pillEdge, newNote: model.newNoteAction)
        let frame = PillPlacement.frame(
            size: size, edge: model.pillEdge, offset: model.pillOffset, inset: 0, in: visibleFrame
        )
        guard frame != panel.frame else { return }
        // The panel frame snaps and the SwiftUI content animates inside it.
        panel.setFrame(frame, display: true)
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Hover

    private var panelSize: CGSize { panel.frame.size }

    /// Re-reads the pointer after the panel resizes, since a stationary
    /// pointer gets no tracking callback when the window grows under it.
    private func syncHover() {
        let mouse = NSEvent.mouseLocation
        guard panel.frame.contains(mouse) else {
            pointerMoved(to: nil)
            return
        }
        pointerMoved(to: CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY))
    }

    private func pointerMoved(to point: CGPoint?) {
        guard dragState == nil else { return }
        guard let point else {
            applyHoverEffect(intent.pointerExited())
            model.setNudgeHovered(false)
            model.setPillHovered(false)
            setHovered(nil)
            return
        }
        switch viewState {
        case .nudge:
            // Reading the card pauses its countdown, so it cannot vanish
            // mid-sentence.
            model.setNudgeHovered(FlowBarDock.cardRect(edge: model.pillEdge, panelSize: panelSize).contains(point))
        case .ribbon(let spec):
            let rect = FlowBarDock.ribbonRect(spec, edge: model.pillEdge, panelSize: panelSize)
            model.setPillHovered(rect.insetBy(dx: -FlowBarMetrics.hitPadding, dy: -FlowBarMetrics.hitPadding)
                .contains(point))
        case .nub, .hover:
            model.setNudgeHovered(false)
            applyHoverEffect(intent.pointerEntered())
            let hovered = intent.isOpen
                ? FlowBarDock.control(at: point, hovered: chrome.hovered, newNote: model.newNoteAction,
                                      edge: model.pillEdge, panelSize: panelSize)
                : nil
            setHovered(hovered)
        }
    }

    private func setHovered(_ control: DockControl?) {
        guard chrome.hovered != control else { return }
        withAnimation(.easeOut(duration: reduceMotion ? FlowBarMetrics.reducedMotionFade : FlowBarMetrics.labelFadeDuration)) {
            chrome.hovered = control
        }
        update()
    }

    private func applyHoverEffect(_ effect: DockHoverIntent.Effect) {
        switch effect {
        case .none:
            break
        case .startOpenTimer:
            scheduleOpen()
        case .startCloseTimer:
            scheduleClose()
        case .cancelTimers:
            cancelHoverTimers()
        case .didOpen:
            setOpen(true)
        case .didClose:
            cancelHoverTimers()
            setOpen(false)
        }
    }

    private func scheduleOpen() {
        cancelHoverTimers()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyHoverEffect(self.intent.openTimerFired())
            }
        }
        openTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FlowBarMetrics.hoverOpenDelay, execute: work)
    }

    private func scheduleClose() {
        cancelHoverTimers()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyHoverEffect(self.intent.closeTimerFired())
            }
        }
        closeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FlowBarMetrics.hoverCloseDelay, execute: work)
    }

    private func cancelHoverTimers() {
        openTimer?.cancel(); openTimer = nil
        closeTimer?.cancel(); closeTimer = nil
    }

    private func setOpen(_ open: Bool) {
        guard chrome.open != open else { return }
        if open {
            // Grow the panel first so the capsule is not clipped. `update`
            // reads the intent, which is already open, not `chrome.open`.
            update()
            withAnimation(openAnimation) { chrome.open = true }
            installDockEscapeMonitors()
        } else {
            chrome.hovered = nil
            withAnimation(closeAnimation) { chrome.open = false }
            removeDockEscapeMonitors()
            DispatchQueue.main.asyncAfter(deadline: .now() + FlowBarMetrics.collapseDuration) {
                MainActor.assumeIsolated { [weak self] in self?.update() }
            }
        }
    }

    private var openAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: FlowBarMetrics.reducedMotionFade)
            : .timingCurve(0.2, 0.9, 0.3, 1.15, duration: FlowBarMetrics.fanOutDuration)
    }

    private var closeAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: FlowBarMetrics.reducedMotionFade)
            : .easeIn(duration: FlowBarMetrics.collapseDuration)
    }

    /// Escape collapses the capsule. It never stops a recording, and it never
    /// reaches the app in front while the capsule is open on purpose.
    private func installDockEscapeMonitors() {
        guard dockEscapeMonitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return event }
            let consumed = MainActor.assumeIsolated { [weak self] () -> Bool in
                guard let self, self.intent.isOpen else { return false }
                self.collapseDock()
                return true
            }
            return consumed ? nil : event
        }) {
            dockEscapeMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.intent.isOpen else { return }
                self.collapseDock()
            }
        }) {
            dockEscapeMonitors.append(global)
        }
    }

    private func removeDockEscapeMonitors() {
        for monitor in dockEscapeMonitors { NSEvent.removeMonitor(monitor) }
        dockEscapeMonitors = []
    }

    private func collapseDock() {
        applyHoverEffect(intent.escape())
    }

    // MARK: - Clicks

    /// Runs the action for a click that never moved. Drags do not land here.
    private func handleClick(at point: CGPoint) {
        switch viewState {
        case .nudge(let detected):
            switch FlowBarDock.nudgeAction(at: point, edge: model.pillEdge, panelSize: panelSize) {
            case .ignore: model.ignoreDetectedMeeting()
            case .startNote: model.startDetectedMeeting(detected)
            case nil: break
            }
        case .ribbon(let spec):
            if let action = FlowBarDock.ribbonAction(at: point, spec: spec, edge: model.pillEdge, panelSize: panelSize) {
                model.performRibbonAction(action)
            } else if case .listening = model.pillState {
                model.toggleDictationFromDock()
            }
        case .nub:
            // A click on the nub opens the capsule without waiting out the
            // hover delay.
            applyHoverEffect(intent.pointerEntered())
            applyHoverEffect(intent.openTimerFired())
        case .hover(let hovered):
            guard intent.isOpen,
                  let control = FlowBarDock.control(at: point, hovered: hovered, newNote: model.newNoteAction,
                                                    edge: model.pillEdge, panelSize: panelSize) else { return }
            activate(control)
        }
    }

    private func activate(_ control: DockControl) {
        switch control {
        case .dictate: model.toggleDictationFromDock()
        case .newNote: model.toggleMeetingCapture()
        case .scratchpad: model.toggleQuickNote()
        }
    }

    /// Right click: the Flow menu, for the things people change mid-day
    /// without opening a window.
    private func showFlowMenu(_ event: NSEvent) {
        guard dragState == nil else { return }
        let entries = FlowMenu.entries(cleanupLevel: model.cleanupLevel, microphones: AudioInputDevices.all())
        let menu = menuBuilder.menu(for: entries)
        let location = tracking.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: location, in: tracking)
    }

    // MARK: - Drag

    private func beginDrag(cursor: CGPoint) {
        guard !isSettling else { return }
        pressPoint = CGPoint(x: cursor.x - panel.frame.minX, y: cursor.y - panel.frame.minY)
        dragState = PillDragState(originFrame: panel.frame, cursor: cursor)
    }

    private func moveDrag(cursor: CGPoint) {
        guard var state = dragState else { return }
        if !state.didMove {
            guard !PillPlacement.isClick(from: state.originCursor, to: cursor) else { return }
            state.didMove = true
            startLift()
            showDropZones()
            installEscapeMonitors()
        }
        let frame = state.frame(forCursor: cursor)
        panel.setFrame(frame, display: true)

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let armed = PillPlacement.armedZone(pillCenter: center, zones: dragZones)
        if armed?.edge != state.armedEdge {
            state.armedEdge = armed?.edge
            overlay.setArmed(armed?.edge)
            if armed != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        dragState = state
    }

    private func endDrag(cursor: CGPoint) {
        guard let state = dragState else { return }
        dragState = nil
        teardownDrag()
        guard state.didMove else {
            if let pressPoint { handleClick(at: pressPoint) }
            pressPoint = nil
            return
        }
        pressPoint = nil
        let frame = state.frame(forCursor: cursor)
        guard let screen = dragScreen ?? dockingScreen() else { return }
        let visibleFrame = screen.visibleFrame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let edge: PillEdge
        let offset: Double
        if let armedEdge = state.armedEdge {
            edge = armedEdge
            offset = 0.5
        } else {
            edge = PillPlacement.nearestEdge(center: center, in: visibleFrame)
            offset = PillPlacement.normalizedOffset(center: center, edge: edge, in: visibleFrame)
        }
        settle(edge: edge, offset: offset, in: visibleFrame)
    }

    private func cancelDrag() {
        guard let state = dragState else { return }
        dragState = nil
        pressPoint = nil
        panel.stopTracking()
        teardownDrag()
        guard state.didMove else { return }
        guard !reduceMotion else {
            panel.setFrame(state.cancelledFrame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FlowBarMetrics.collapseDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(state.cancelledFrame, display: true)
        }
    }

    /// Animates the panel onto the chosen dock, pulses the pill, and persists
    /// the new position.
    private func settle(edge: PillEdge, offset: Double, in visibleFrame: CGRect) {
        let size = FlowBarDock.panelSize(for: viewState, edge: edge, newNote: model.newNoteAction)
        let target = PillPlacement.frame(size: size, edge: edge, offset: offset, inset: 0, in: visibleFrame)
        isSettling = true
        model.setPillDock(edge: edge, offset: offset)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        guard !reduceMotion else {
            panel.setFrame(target, display: true)
            isSettling = false
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.settleDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.isSettling = false
                self.pulse()
            }
        })
    }

    private func startLift() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: Self.liftDuration)) { chrome.lifted = true }
    }

    private func endLift() {
        guard chrome.lifted else { return }
        withAnimation(.easeOut(duration: Self.liftDuration)) { chrome.lifted = false }
    }

    /// The lock-in pulse: 1.0 -> 1.04 -> 1.0 over 180 ms.
    private func pulse() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.09)) { chrome.pulse = 1.04 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            MainActor.assumeIsolated {
                withAnimation(.easeOut(duration: 0.09)) { self.chrome.pulse = 1.0 }
            }
        }
    }

    private func showDropZones() {
        guard let screen = dockingScreen() else { return }
        dragScreen = screen
        // Zones always preview where the nub will sit, so the four outlines
        // read the same no matter which state the dock is in when it moves.
        let canonicalSize = CGSize(width: FlowBarMetrics.nubLength, height: FlowBarMetrics.nubThickness)
        dragZones = PillPlacement.dropZones(
            pillSize: canonicalSize, inset: FlowBarMetrics.nubInset, in: screen.visibleFrame,
            matchEdgeOrientation: true
        )
        overlay.show(zones: dragZones, on: screen)
    }

    private func teardownDrag() {
        endLift()
        overlay.hide()
        removeEscapeMonitors()
        dragZones = []
    }

    /// Escape cancels a drag. The panel never becomes key, so a local monitor
    /// catches Escape inside the app and a global monitor catches it while
    /// another app is frontmost.
    private func installEscapeMonitors() {
        guard escapeMonitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return event }
            let cancelled = MainActor.assumeIsolated { [weak self] () -> Bool in
                guard let self, self.dragState != nil else { return false }
                self.cancelDrag()
                return true
            }
            return cancelled ? nil : event
        }) {
            escapeMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.dragState != nil else { return }
                self.panel.stopTracking()
                self.cancelDrag()
            }
        }) {
            escapeMonitors.append(global)
        }
    }

    private func removeEscapeMonitors() {
        for monitor in escapeMonitors { NSEvent.removeMonitor(monitor) }
        escapeMonitors = []
    }

    /// The screen under the mouse pointer, falling back to the main screen.
    private func dockingScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

// MARK: - Colors

/// The ribbon's palette, from the Direction A mock-up.
enum FlowBarPalette {
    /// #141416, the ribbon and card fill.
    static let ribbonFill = Color(red: 0.078, green: 0.078, blue: 0.086)
    /// #3A3A3C, the hovered segment.
    static let segmentHover = Color(red: 0.227, green: 0.227, blue: 0.235)
    static let glyph = Color(red: 0.961, green: 0.961, blue: 0.969)
    /// #111111, the hover label.
    static let labelFill = Color(red: 0.067, green: 0.067, blue: 0.067)
    /// #33D9FF, the warm pinhole, the listening dot, and the waveform.
    static let cyan = Color(red: 0.200, green: 0.851, blue: 1.0)
    static let green = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let amber = Color(red: 0.949, green: 0.725, blue: 0.314)
    static let failure = Color(red: 1.0, green: 0.412, blue: 0.380)
    static let recordingRed = Color(red: 1.0, green: 0.271, blue: 0.227)
    /// #E7E0FF, the Command chip.
    static let command = Color(red: 0.906, green: 0.878, blue: 1.0)
    static let chipText = Color(red: 0.784, green: 0.784, blue: 0.800)
    static let keyText = Color(red: 0.631, green: 0.631, blue: 0.651)
    static let nubLight = Color(red: 0.557, green: 0.557, blue: 0.576)
    static let nubDark = Color(red: 0.631, green: 0.631, blue: 0.651)
    static let pinholeCold = Color(red: 0.43, green: 0.43, blue: 0.45)
}

// MARK: - The dock

/// One overlay that draws the nub, the hover capsule, every ribbon, and the
/// meeting card. It reads its own size, so the panel controller can resize
/// the window and the layout follows.
struct FlowBarDockView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var chrome: FlowBarChrome
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var edge: PillEdge { model.pillEdge }

    private var state: FlowBarViewState {
        FlowBarState.viewState(model: model, hovered: chrome.hovered, open: chrome.open)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                content(panelSize: geometry.size)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .scaleEffect(chrome.scale)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func content(panelSize: CGSize) -> some View {
        switch state {
        case .nub, .hover:
            // One branch for both, so the capsule keeps its identity and the
            // open animates instead of cutting.
            nub(panelSize: panelSize, hidden: chrome.open)
            capsule(panelSize: panelSize)
        case .ribbon(let spec):
            ribbon(spec, panelSize: panelSize)
        case .nudge(let detected):
            card(detected, panelSize: panelSize)
        }
    }

    // MARK: Nub

    private var nubFill: Color {
        (colorScheme == .dark ? FlowBarPalette.nubDark : FlowBarPalette.nubLight).opacity(0.95)
    }

    @ViewBuilder
    private func nub(panelSize: CGSize, hidden: Bool) -> some View {
        let rect = FlowBarDock.nubRect(edge: edge, panelSize: panelSize)
        let warm = model.engineHealth.warm
        RoundedRectangle(cornerRadius: FlowBarMetrics.nubRadius, style: .continuous)
            .fill(nubFill)
            .overlay(
                Circle()
                    .fill(warm ? FlowBarPalette.cyan : FlowBarPalette.pinholeCold)
                    .frame(width: FlowBarMetrics.nubDot, height: FlowBarMetrics.nubDot)
                    .shadow(color: warm ? FlowBarPalette.cyan.opacity(0.9) : .clear, radius: 2.5)
            )
            .frame(width: rect.width, height: rect.height)
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
            .opacity(hidden ? 0 : 1)
            .scaleEffect(x: edge.isHorizontal ? (hidden ? 0.6 : 1) : 1,
                         y: edge.isHorizontal ? 1 : (hidden ? 0.6 : 1))
            .animation(.easeOut(duration: FlowBarMetrics.nubFadeDuration), value: hidden)
            .place(rect, in: panelSize)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(warm ? "Undertone, ready" : "Undertone, models loading")
    }

    // MARK: Hover capsule

    @ViewBuilder
    private func capsule(panelSize: CGSize) -> some View {
        let hovered = chrome.open ? chrome.hovered : nil
        let action = model.newNoteAction
        let rect = FlowBarDock.capsuleRect(hovered: hovered, newNote: action, edge: edge, panelSize: panelSize)
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(DockControl.allCases) { control in
                let frame = FlowBarDock.segmentFrame(control)
                segment(control, hovered: hovered == control)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .background(ribbonBackground(radius: RibbonMetrics.radius))
        .opacity(chrome.open ? 1 : 0)
        .scaleEffect(chrome.open || reduceMotion ? 1 : 0.7, anchor: capsuleAnchor)
        .animation(chrome.open ? openAnimation : closeAnimation, value: chrome.open)
        .place(rect, in: panelSize)
        .accessibilityElement(children: .contain)
        .accessibilityHidden(!chrome.open)

        if let hovered {
            let labelRect = FlowBarDock.labelRect(hovered, newNote: action, edge: edge, panelSize: panelSize)
            hoverLabel(hovered, action: action)
                .frame(width: labelRect.width, height: labelRect.height)
                .place(labelRect, in: panelSize)
                .transition(.opacity)
        }
    }

    /// The capsule grows out of the nub, so it scales from the docked edge.
    private var capsuleAnchor: UnitPoint {
        switch edge {
        case .bottom: return .bottom
        case .top: return .top
        case .left: return .leading
        case .right: return .trailing
        }
    }

    private var openAnimation: Animation {
        reduceMotion ? .easeOut(duration: FlowBarMetrics.reducedMotionFade)
            : .timingCurve(0.2, 0.9, 0.3, 1.15, duration: FlowBarMetrics.fanOutDuration)
    }

    private var closeAnimation: Animation {
        reduceMotion ? .easeOut(duration: FlowBarMetrics.reducedMotionFade)
            : .easeIn(duration: FlowBarMetrics.collapseDuration)
    }

    @ViewBuilder
    private func segment(_ control: DockControl, hovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: RibbonMetrics.segmentHeight / 2, style: .continuous)
            .fill(hovered ? FlowBarPalette.segmentHover : Color.clear)
            .overlay(segmentGlyph(control))
            .animation(.linear(duration: 0.12), value: hovered)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(FlowBarDock.accessibilityLabel(for: control, newNote: model.newNoteAction))
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func segmentGlyph(_ control: DockControl) -> some View {
        switch control {
        case .dictate:
            Image(systemName: "mic")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(FlowBarPalette.glyph)
        case .newNote:
            Circle()
                .strokeBorder(FlowBarPalette.glyph, lineWidth: 1.8)
                .overlay(Circle().fill(FlowBarPalette.glyph).frame(width: 5, height: 5))
                .frame(width: 14, height: 14)
        case .scratchpad:
            Image(systemName: "pencil")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(FlowBarPalette.glyph)
        }
    }

    @ViewBuilder
    private func hoverLabel(_ control: DockControl, action: FlowBarDock.NewNoteAction) -> some View {
        let label = FlowBarDock.labelText(for: control, newNote: action)
        HStack(spacing: RibbonMetrics.labelKeyGap) {
            Text(label.title)
                .font(.system(size: RibbonMetrics.labelFont, weight: .medium))
            if let shortcut = label.shortcut {
                Text(shortcut)
                    .font(.system(size: RibbonMetrics.keyFont, weight: .bold, design: .monospaced))
            }
        }
        .foregroundStyle(FlowBarPalette.glyph)
        .lineLimit(1)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowBarPalette.labelFill.opacity(0.98),
                    in: RoundedRectangle(cornerRadius: RibbonMetrics.labelHeight / 2, style: .continuous))
        .shadow(color: .black.opacity(0.30), radius: 8, y: 3)
        .accessibilityHidden(true)
    }

    // MARK: Ribbon

    /// The #141416 fill with a 1 point inset rim at 12% white, which keeps it
    /// readable on a dark wall.
    @ViewBuilder
    private func ribbonBackground(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(FlowBarPalette.ribbonFill)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
    }

    @ViewBuilder
    private func ribbon(_ spec: RibbonSpec, panelSize: CGSize) -> some View {
        let rect = FlowBarDock.ribbonRect(spec, edge: edge, panelSize: panelSize)
        HStack(spacing: RibbonMetrics.gap) {
            ForEach(Array(spec.pieces.enumerated()), id: \.offset) { _, piece in
                pieceView(piece)
                    .frame(width: RibbonSpec.width(of: piece), height: RibbonSpec.height(of: piece))
            }
        }
        .padding(.leading, spec.leadingPadding)
        .padding(.trailing, spec.trailingPadding)
        .frame(width: rect.width, height: rect.height, alignment: .leading)
        .background(ribbonBackground(radius: RibbonMetrics.radius))
        .place(rect, in: panelSize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ribbonAccessibilityLabel)
    }

    private var ribbonAccessibilityLabel: String {
        switch model.pillState {
        case .listening: return model.dictationLocked ? "Dictating, locked" : "Dictating"
        case .working: return "Cleaning up"
        case .inserted(let ms): return "Inserted, \(Int(ms.rounded())) milliseconds"
        case .guarded: return "Kept raw"
        case .error(let message): return message
        case .notice(let message): return message
        case .recording(let elapsed): return "Recording, \(FlowBarDock.timerText(elapsed))"
        case .idle, .meetingDetected: return "Undertone"
        }
    }

    @ViewBuilder
    private func pieceView(_ piece: RibbonPiece) -> some View {
        switch piece {
        case .dot(let dot):
            PulsingDot(color: dot == .listening ? FlowBarPalette.cyan : FlowBarPalette.recordingRed,
                       glow: dot == .listening)
        case .waveform:
            FlowingWaveform(level: model.listeningLevel)
        case .glyph(let glyph):
            glyphView(glyph)
        case .spinner:
            RingSpinner(size: RibbonMetrics.spinner)
        case .text(let text):
            Text(text)
                .font(.system(size: RibbonMetrics.textFont, weight: .medium))
                .foregroundStyle(FlowBarPalette.glyph)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .mono(let text, _):
            Text(text)
                .font(.system(size: RibbonMetrics.monoFont, weight: .medium, design: .monospaced))
                .foregroundStyle(FlowBarPalette.keyText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .clock(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(FlowBarDock.timerText(context.date.timeIntervalSince(since)))
                    .font(.system(size: RibbonMetrics.monoFont, weight: .medium, design: .monospaced))
                    .foregroundStyle(FlowBarPalette.keyText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .chip(let text):
            Text(text)
                .font(.system(size: RibbonMetrics.chipFont, weight: .medium))
                .foregroundStyle(FlowBarPalette.chipText)
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: RibbonMetrics.chipHeight / 2, style: .continuous))
        case .commandChip:
            Text(FlowBarText.commandMarker)
                .font(.system(size: RibbonMetrics.chipFont, weight: .semibold))
                .foregroundStyle(Color(red: 0.067, green: 0.067, blue: 0.067))
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FlowBarPalette.command,
                            in: RoundedRectangle(cornerRadius: RibbonMetrics.commandHeight / 2, style: .continuous))
                .accessibilityLabel("Command mode")
        case .button(let action):
            ribbonButton(action)
        case .meters:
            VStack(alignment: .leading, spacing: 3) {
                meterRow("Me", level: model.meetings.microphoneLevel, tint: FlowBarPalette.cyan)
                meterRow("All", level: model.meetings.systemAudioLevel, tint: FlowBarPalette.glyph)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Me and Others audio levels")
        }
    }

    @ViewBuilder
    private func glyphView(_ glyph: RibbonGlyph) -> some View {
        switch glyph {
        case .check:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FlowBarPalette.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowBarPalette.amber)
        case .failure:
            Image(systemName: "xmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowBarPalette.failure)
        case .lock:
            Image(systemName: "lock")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(FlowBarPalette.cyan)
                .accessibilityLabel("Locked")
        }
    }

    @ViewBuilder
    private func ribbonButton(_ action: RibbonAction) -> some View {
        if action == .stop {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(FlowBarPalette.recordingRed)
                .frame(width: 8, height: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.10), in: Circle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(action.accessibilityLabel)
                .accessibilityAddTraits(.isButton)
        } else {
            HStack(spacing: RibbonMetrics.keyGap) {
                Text(action.title)
                    .font(.system(size: RibbonMetrics.buttonFont, weight: .semibold))
                if let shortcut = action.shortcut {
                    Text(shortcut)
                        .font(.system(size: RibbonMetrics.keyFont, design: .monospaced))
                        .foregroundStyle(action.isSolid ? Color(white: 0.33) : FlowBarPalette.keyText)
                }
            }
            .foregroundStyle(action.isSolid ? Color(red: 0.067, green: 0.067, blue: 0.067) : FlowBarPalette.glyph)
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(action.isSolid ? FlowBarPalette.glyph : Color.white.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: RibbonMetrics.buttonHeight / 2, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(action.accessibilityLabel)
            .accessibilityAddTraits(.isButton)
        }
    }

    @ViewBuilder
    private func meterRow(_ label: String, level: Double, tint: Color) -> some View {
        HStack(spacing: RibbonMetrics.meterGap) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(FlowBarPalette.keyText)
                .lineLimit(1)
                .fixedSize()
                .frame(width: RibbonMetrics.meterLabel, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(tint)
                    .frame(width: RibbonMetrics.meterTrack * MeterScale.visual(level))
            }
            .frame(width: RibbonMetrics.meterTrack, height: 3)
            .animation(.easeOut(duration: 0.12), value: level)
        }
    }

    // MARK: Meeting card

    @ViewBuilder
    private func card(_ detected: DetectedMeeting, panelSize: CGSize) -> some View {
        let rect = FlowBarDock.cardRect(edge: edge, panelSize: panelSize)
        MeetingNudgeCard(detected: detected, fraction: model.nudgeFraction)
            .frame(width: rect.width, height: rect.height)
            .place(rect, in: panelSize)
    }
}

/// Meter levels arrive as linear RMS. A -50 to 0 dB scale makes speech fill
/// a visible share of a 28 point track.
enum MeterScale {
    static func visual(_ level: Double) -> Double {
        guard level.isFinite, level > 0.001 else { return 0 }
        let decibels = 20 * log10(min(1, level))
        return min(1, max(0, (decibels + 50) / 50))
    }
}

/// An 8 point dot that breathes between full and 40% opacity. Still under
/// Reduce Motion.
struct PulsingDot: View {
    let color: Color
    var glow = false
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: RibbonMetrics.dot, height: RibbonMetrics.dot)
            .shadow(color: glow ? color.opacity(0.8) : .clear, radius: 4)
            .opacity(dim ? 0.4 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: FlowBarMetrics.pulsePeriod / 2).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// The meeting card the pill grows into: which call, one question, and two
/// answers. 236 points wide on every dock.
struct MeetingNudgeCard: View {
    let detected: DetectedMeeting
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                MeetingBadgeView(detected: detected)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(FlowBarDock.cardTitle(for: detected))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FlowBarPalette.glyph)
                        .lineLimit(1)
                    Text(FlowBarDock.cardQuestion)
                        .font(.system(size: 11))
                        .foregroundStyle(FlowBarPalette.keyText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 8)
            HStack(spacing: RibbonMetrics.cardButtonGap) {
                cardButton("Not now", solid: false)
                cardButton("Start notes", solid: true)
            }
            .frame(height: RibbonMetrics.buttonHeight)
        }
        .padding(RibbonMetrics.cardPadding)
        .frame(width: RibbonMetrics.cardWidth, height: RibbonMetrics.cardHeight, alignment: .topLeading)
        .background(FlowBarPalette.ribbonFill)
        .overlay(alignment: .bottom) {
            // How long the card has left. Hovering it pauses the countdown,
            // so the bar stops with it.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.10)
                    Color.white.opacity(0.6).frame(width: geometry.size.width * max(0, min(1, fraction)))
                }
            }
            .frame(height: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: RibbonMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RibbonMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(FlowBarDock.nudgeTitle). \(FlowBarDock.nudgeReason(for: detected))")
    }

    @ViewBuilder
    private func cardButton(_ title: String, solid: Bool) -> some View {
        Text(title)
            .font(.system(size: RibbonMetrics.buttonFont, weight: .semibold))
            .foregroundStyle(solid ? Color(red: 0.067, green: 0.067, blue: 0.067) : FlowBarPalette.glyph)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(solid ? FlowBarPalette.glyph : Color.white.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: RibbonMetrics.buttonHeight / 2, style: .continuous))
            .accessibilityAddTraits(.isButton)
    }
}

private extension View {
    /// Places a view at an AppKit (bottom-left origin) rect inside a
    /// top-leading SwiftUI stack of `panelSize`.
    func place(_ rect: CGRect, in panelSize: CGSize) -> some View {
        frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: panelSize.height - rect.maxY)
    }
}

/// A small ring with one bright arc turning through it. The system's own
/// small `ProgressView` draws spokes, which reads as a beachball at this size.
struct RingSpinner: View {
    var size: CGFloat = 14
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .strokeBorder(Color.white.opacity(0.25), lineWidth: 2)
            .overlay(
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(1)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
            )
            .frame(width: size, height: size)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
            }
            .accessibilityHidden(true)
    }
}

struct FlowingWaveform: View {
    let level: Double
    /// `true` when docked top/bottom (bars grow vertically, laid out
    /// left-to-right). `false` on the side docks, where the same drawing
    /// is rotated 90 degrees so the bars grow horizontally, stacked
    /// top-to-bottom.
    var isHorizontal: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var smoothedLevel = 0.0
    // Preserve the timer across microphone-driven view updates.
    @State private var envelopeTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private let cyan = Color(red: 0.20, green: 0.85, blue: 1.0)
    /// Seven bars, 2 points wide, 3 points apart, 4 to 16 points tall.
    private static let barCount = 7
    private static let barWidth = 2.0
    private static let barGap = 3.0
    private static let minBarHeight = 4.0
    private static let maxBarHeight = 16.0
    static let blockLength = CGFloat(Double(barCount) * barWidth + Double(barCount - 1) * barGap)
    private static let durations: [Double] = [0.29, 0.37, 0.43, 0.31, 0.47, 0.34, 0.41]
    private static let gains: [Double] = [0.72, 0.48, 0.88, 0.60, 0.94, 0.52, 0.82]
    private static let phaseOffsets: [Double] = [0.0, 1.1, 2.2, 0.5, 3.0, 1.7, 4.0]

    var body: some View {
        let visibleLevel = smoothedLevel
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            Canvas { context, physicalSize in
                // Bars are always laid out against the flat, left-to-right
                // orientation. On the side docks the canvas itself is
                // physically transposed, so the context is rotated 90 degrees
                // first and the drawing below runs unchanged against it.
                let size: CGSize
                if isHorizontal {
                    size = physicalSize
                } else {
                    size = CGSize(width: physicalSize.height, height: physicalSize.width)
                    context.translateBy(x: physicalSize.width, y: 0)
                    context.rotate(by: .degrees(90))
                }

                let now = timeline.date.timeIntervalSinceReferenceDate
                let totalWidth = Double(Self.blockLength)
                let startX = (size.width - CGFloat(totalWidth)) / 2
                let centerY = size.height / 2

                for index in Self.durations.indices {
                    let progress = reduceMotion ? 0.5 : 0.5 + 0.5 * sin((now / Self.durations[index]) * (2 * Double.pi) + Self.phaseOffsets[index])
                    let idleBreath = Self.minBarHeight + progress * 1.2
                    let speechHeight = visibleLevel * Self.maxBarHeight * Self.gains[index] * (0.78 + progress * 0.22)
                    let height = min(Self.maxBarHeight, max(Self.minBarHeight, visibleLevel <= 0.001 ? idleBreath : idleBreath + speechHeight))
                    let x = startX + CGFloat(index) * CGFloat(Self.barWidth + Self.barGap)
                    let rect = CGRect(x: x, y: centerY - CGFloat(height) / 2, width: Self.barWidth, height: CGFloat(height))
                    let color = visibleLevel <= 0.001
                        ? Color.white.opacity(0.65 + progress * 0.20)
                        : cyan.opacity(0.72 + min(visibleLevel, 1) * 0.28)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                }
            }
        }
        .frame(width: isHorizontal ? Self.blockLength : CGFloat(Self.maxBarHeight),
               height: isHorizontal ? CGFloat(Self.maxBarHeight) : Self.blockLength)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio level")
        .accessibilityValue(targetLevel == 0 ? "silent" : "active")
        .onAppear { smoothedLevel = targetLevel }
        .onReceive(envelopeTimer) { _ in advanceEnvelope() }
        .onChange(of: level) { _, _ in
            if reduceMotion { smoothedLevel = targetLevel }
        }
        .onChange(of: reduceMotion) { _, isReduced in
            if isReduced { smoothedLevel = targetLevel }
        }
    }

    private static func displayLevel(_ level: Double) -> Double {
        guard level.isFinite, level > 0 else { return 0 }
        let decibels = 20 * log10(min(1, level))
        return min(1, max(0, (decibels + 50) / 50))
    }

    private var targetLevel: Double {
        let visible = Self.displayLevel(level)
        return visible <= 0.08 ? 0 : visible
    }

    private func advanceEnvelope() {
        let target = targetLevel
        if reduceMotion {
            smoothedLevel = target
            return
        }
        let difference = target - smoothedLevel
        guard abs(difference) > 0.0005 else {
            smoothedLevel = target
            return
        }
        let coefficient = difference > 0 ? 0.30 : 0.14
        smoothedLevel += difference * coefficient
    }
}
