import AppKit
import Combine
import SwiftUI

@MainActor
final class MeetingRecordingPanelController {
    private let panel: NSPanel
    private let model: AppModel
    private var stateSubscription: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 86),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: MeetingRecordingPanelView().environmentObject(model))
        stateSubscription = Publishers.CombineLatest(model.meetings.$state, model.meetings.$currentSession)
            .removeDuplicates { $0.0 == $1.0 && $0.1?.status == $1.1?.status }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
        update()
    }

    private func update() {
        guard shouldShow else {
            panel.orderOut(nil)
            return
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 78))
        panel.orderFrontRegardless()
    }

    private var shouldShow: Bool {
        let meetings = model.meetings
        switch meetings.state {
        case .starting, .recording, .stopping, .summarizing:
            return true
        case .error:
            return meetings.currentSession?.status == "recording" || meetings.pendingCount > 0
        case .idle:
            // Preview uses a fixture session marked recording without starting
            // any capture, so the panel can be inspected safely there.
            return model.previewMode && meetings.currentSession?.status == "recording"
        }
    }
}

@MainActor
struct MeetingRecordingPanelView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let meetings = model.meetings
            HStack(spacing: 14) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: statusColor.opacity(0.6), radius: 5)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(statusTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Text(elapsed(at: context.date, meetings: meetings))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        AudioLevelMeter(label: "Me", level: meetings.microphoneLevel, tint: .blue, darkAppearance: true)
                        AudioLevelMeter(label: "Others", level: meetings.systemAudioLevel, tint: .cyan, darkAppearance: true)
                    }
                }

                Spacer(minLength: 4)

                if meetings.state == .recording {
                    Button("Stop") { meetings.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                        .disabled(model.previewMode || meetings.state != .recording)
                } else if meetings.state == .starting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Starting meeting capture")
                } else if case .error = meetings.state {
                    Button("Open Meetings") { model.showApp(.meetings) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(width: 430, height: 86)
            .background(.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.12))
            }
            .foregroundStyle(.white)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Meeting recording status")
            .accessibilityValue(statusTitle)
        }
    }

    private var statusTitle: String {
        switch model.meetings.state {
        case .starting: return "Preparing meeting"
        case .recording: return "Recording meeting"
        case .stopping: return "Flushing audio"
        case .summarizing: return "Writing meeting notes"
        case .error: return "Meeting needs attention"
        case .idle: return "Recording meeting"
        }
    }

    private var statusColor: Color {
        switch model.meetings.state {
        case .error: return .orange
        case .starting, .recording: return .red
        default: return .secondary
        }
    }

    private func elapsed(at date: Date, meetings: MeetingModel) -> String {
        switch meetings.state {
        case .stopping, .summarizing: return "finishing"
        default: break
        }
        let previewStart = model.previewMode && meetings.currentSession?.status == "recording"
            ? meetings.currentSession.map { Date(timeIntervalSince1970: $0.startedAt) }
            : nil
        guard let started = meetings.recordingStartedAt ?? previewStart else {
            switch meetings.state {
            case .starting: return "starting"
            case .stopping, .summarizing: return "finishing"
            default: return "ready"
            }
        }
        let seconds = max(0, Int(date.timeIntervalSince(started)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct AudioLevelMeter: View {
    let label: String
    let level: Double
    let tint: Color
    var darkAppearance = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(darkAppearance ? .white.opacity(0.72) : .secondary)
                .frame(width: 42, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(darkAppearance ? .white.opacity(0.16) : Color.primary.opacity(0.12))
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * visualLevel)
                }
            }
            .frame(width: 74, height: 5)
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private var visualLevel: Double {
        guard level.isFinite, level > 0.001 else { return 0 }
        let decibels = 20 * log10(min(1, level))
        return min(1, max(0, (decibels + 50) / 50))
    }
}
