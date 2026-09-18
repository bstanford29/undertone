import AppKit
import Combine
import Foundation
import SwiftUI

/// Where a committed Quick note goes.
enum QuickNoteDestination: Equatable {
    /// A meeting is recording, so the note joins that meeting's Notes tab.
    case meetingNotes(sessionID: String)
    /// Today's Obsidian daily note, because a vault is configured.
    case dailyNote(path: String)
    /// No vault, so the note lands beside Undertone's own files.
    case localFallback(path: String)

    /// The file this note is written to, or nil when the engine stores it.
    var filePath: String? {
        switch self {
        case .meetingNotes: return nil
        case .dailyNote(let path), .localFallback(let path): return path
        }
    }
}

/// Pure routing and text rules for Quick note. Kept free of AppKit so the
/// decision can be tested without a vault, an engine, or a screen.
enum QuickNoteRouter {
    /// The YYYY-MM-DD stamp both file destinations are named after.
    static func dateStamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// A recording meeting wins. Otherwise a configured vault wins. Otherwise
    /// the note stays in `~/.undertone/quicknotes`.
    static func destination(
        recordingSessionID: String?,
        vaultPath: String?,
        date: Date,
        home: String,
        timeZone: TimeZone = .current
    ) -> QuickNoteDestination {
        if let recordingSessionID, !recordingSessionID.isEmpty {
            return .meetingNotes(sessionID: recordingSessionID)
        }
        let stamp = dateStamp(date, timeZone: timeZone)
        let vault = vaultPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !vault.isEmpty {
            return .dailyNote(path: (vault as NSString).appendingPathComponent("Daily/\(stamp).md"))
        }
        return .localFallback(path: (home as NSString).appendingPathComponent(".undertone/quicknotes/\(stamp).md"))
    }

    /// Appends with one newline between the old text and the new. Never
    /// overwrites, and never leaves a blank first line.
    static func appended(existing: String?, addition: String) -> String {
        let addition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let existing, !existing.isEmpty else { return addition }
        let trimmed = String(existing.reversed().drop { $0 == "\n" }.reversed())
        guard !trimmed.isEmpty else { return addition }
        return trimmed + "\n" + addition
    }

    /// Writes `text` to the end of `path`, creating the folder and the file
    /// when they are missing.
    static func appendToFile(_ text: String, path: String) throws {
        let url = URL(fileURLWithPath: path)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let merged = appended(existing: existing, addition: text) + "\n"
        try merged.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The text the open Quick note panel holds, so the panel controller and the
/// SwiftUI view share one draft.
@MainActor
final class QuickNoteDraft: ObservableObject {
    @Published var text = ""
    @Published var errorMessage: String?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
}

/// The only Undertone overlay allowed to take keyboard focus. It is still a
/// nonactivating panel, so the app behind it keeps its menu bar; the caret
/// moves here only while the panel is open.
final class QuickNoteWindow: NSPanel {
    var onEscape: (() -> Void)?
    var onCommit: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.contains(.command) {
            onCommit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class QuickNotePanelController {
    private let panel: QuickNoteWindow
    private let draft = QuickNoteDraft()
    private weak var model: AppModel?
    private(set) var isOpen = false

    static let panelSize = CGSize(width: 360, height: 220)

    init(model: AppModel) {
        self.model = model
        panel = QuickNoteWindow(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: QuickNoteView(draft: draft))
        panel.onEscape = { [weak self] in self?.close() }
        panel.onCommit = { [weak self] in self?.commit() }
        draft.onCommit = { [weak self] in self?.commit() }
        draft.onCancel = { [weak self] in self?.close() }
    }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard !isOpen else { return }
        draft.errorMessage = nil
        isOpen = true
        place()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Escape closes without saving.
    func close() {
        guard isOpen else { return }
        isOpen = false
        draft.text = ""
        draft.errorMessage = nil
        panel.orderOut(nil)
    }

    private func commit() {
        guard let model else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            close()
            return
        }
        if let failure = model.commitQuickNote(text) {
            draft.errorMessage = failure
            return
        }
        close()
    }

    /// Opens near the dock, on the screen the dock is on, without covering it.
    private func place() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = Self.panelSize
        let margin: CGFloat = 24
        let edge = model?.pillEdge ?? .bottom
        var origin: CGPoint
        switch edge {
        case .right:
            origin = CGPoint(x: visible.maxX - size.width - 80, y: visible.midY - size.height / 2)
        case .left:
            origin = CGPoint(x: visible.minX + 80, y: visible.midY - size.height / 2)
        case .bottom:
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 80)
        case .top:
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 80)
        }
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
    }
}

/// A small dark card with one text field. Same chrome family as the dock:
/// near-black fill, 12 point radius, a faint rim so it reads on a dark wall.
struct QuickNoteView: View {
    @ObservedObject var draft: QuickNoteDraft
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 13, weight: .regular))
                Text("Quick note")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Esc closes")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            TextEditor(text: $draft.text)
                .focused($focused)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 12)

            if let message = draft.errorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.40))
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }

            HStack(spacing: 8) {
                Text("Cmd+Return saves")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button("Save") { draft.onCommit?() }
                    .buttonStyle(QuickNoteButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: QuickNotePanelController.panelSize.width,
               height: QuickNotePanelController.panelSize.height)
        .background(Color(red: 0.067, green: 0.067, blue: 0.067), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .onAppear { focused = true }
    }
}

struct QuickNoteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(red: 0.067, green: 0.067, blue: 0.067))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color(white: configuration.isPressed ? 0.82 : 0.96),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
