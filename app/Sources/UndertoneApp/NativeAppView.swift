import AppKit
import SwiftUI

enum AppPage: String, CaseIterable, Hashable, Identifiable {
    case home = "Home"
    case history = "History"
    case dictionary = "Dictionary"
    case meetings = "Meetings"
    case settings = "Settings"
    case permissions = "Permissions"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "waveform"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "text.book.closed"
        case .meetings: return "person.2"
        case .settings: return "gearshape"
        case .permissions: return "checkmark.shield"
        }
    }
}

@MainActor
struct NativeAppView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.previewMode {
                // NavigationSplitView's sidebar draws with a vibrant
                // material that renders solid black or white when the
                // preview window is captured offscreen with cacheDisplay,
                // so preview mode lays the two panes out with a plain
                // HStack instead. Production keeps the real
                // NavigationSplitView.
                HStack(spacing: 0) {
                    sidebar
                        .frame(minWidth: 180, idealWidth: 196, maxWidth: 220)
                    Divider()
                    detailContent
                }
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detailContent
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .frame(minWidth: 860, idealWidth: 1100, minHeight: 650)
        .background(nativeBackground)
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeader
            if usesOuterScroll {
                ScrollView { pageContent }
            } else {
                pageContent
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(nativeBackground)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentColor.opacity(0.18))
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Undertone").font(.headline)
                    Text("Private dictation")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text("WORKSPACE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)

            // .sidebar list style uses the same vibrant material that
            // renders solid in an offscreen preview capture (see body),
            // so preview mode falls back to a plain list.
            Group {
                if model.previewMode {
                    List(selection: pageSelection) {
                        ForEach(AppPage.allCases) { page in
                            Label(page.rawValue, systemImage: page.icon)
                                .tag(page)
                        }
                    }
                    .listStyle(.plain)
                } else {
                    List(selection: pageSelection) {
                        ForEach(AppPage.allCases) { page in
                            Label(page.rawValue, systemImage: page.icon)
                                .tag(page)
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .scrollContentBackground(.hidden)

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.engineReady ? .green : .orange)
                        .frame(width: 7, height: 7)
                    Text(model.engineReady ? "Engine ready" : "Engine status")
                        .font(.caption.weight(.semibold))
                }
                Text(model.engineStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(16)
        .background(sidebarBackground)
        .navigationSplitViewColumnWidth(min: 180, ideal: 196, max: 220)
    }

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.appPage.rawValue)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(pageSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label("Hold fn or F13 to dictate", systemImage: "hand.tap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(model.engineReady ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(model.engineStatusText)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(cardBackground, in: Capsule())
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.appPage {
        case .home: home
        case .history: HistoryView()
        case .dictionary: DictionaryView()
        case .meetings: MeetingView()
        case .settings: SettingsView()
        case .permissions:
            SetupView()
                .accessibilityElement(children: .contain)
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 18) {
            brandImage
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12)))

            HStack(spacing: 10) {
                Button(model.permissionSnapshot.dictationReady ? "Open History" : "Review Permissions") {
                    model.appPage = model.permissionSnapshot.dictationReady ? .history : .permissions
                }
                .buttonStyle(.borderedProminent)
                Button("Settings") { model.appPage = .settings }
                    .buttonStyle(.bordered)
            }

            HStack(alignment: .top, spacing: 16) {
                infoCard(title: "Hold to dictate", icon: "hand.tap", tint: .blue) {
                    Text("Hold fn or F13 while you speak, then release to transcribe and insert.")
                }
                infoCard(title: "Private by default", icon: "lock.shield", tint: .green) {
                    Text("Your audio and history stay on this Mac.")
                }
            }

            if !model.permissionSnapshot.dictationReady {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Finish setup before your first dictation")
                            .font(.subheadline.weight(.semibold))
                        Text("Microphone, Accessibility, and Input Monitoring are checked from the Permissions page.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Permissions") { model.appPage = .permissions }
                        .buttonStyle(.bordered)
                }
                .padding(14)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            }

        }
    }

    @ViewBuilder
    private func infoCard<Content: View>(title: String, icon: String, tint: Color,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.subheadline.weight(.semibold))
            }
            content()
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var brandImage: some View {
        if let url = Bundle.main.url(forResource: "UndertoneBrand", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(1730.0 / 909.0, contentMode: .fit)
        } else {
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.primary.opacity(0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text("Undertone")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
            }
            .aspectRatio(1730.0 / 909.0, contentMode: .fit)
        }
    }

    private var pageSubtitle: String {
        switch model.appPage {
        case .home: return "Dictation, history, and meeting notes."
        case .history: return "Review what you said and what was inserted."
        case .dictionary: return "Keep names, phrases, and replacements consistent."
        case .meetings: return "Capture local Me and Others notes when you choose."
        case .settings: return "Tune cleanup, sound, and meeting export settings."
        case .permissions: return "Check access before the first dictation."
        }
    }

    private var pageSelection: Binding<AppPage?> {
        Binding(
            get: { model.appPage },
            set: { if let page = $0 { model.appPage = page } }
        )
    }

    private var usesOuterScroll: Bool {
        switch model.appPage {
        case .home: return true
        case .history, .dictionary, .meetings, .settings: return false
        case .permissions: return true
        }
    }

    private var nativeBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var sidebarBackground: Color {
        Color(nsColor: .underPageBackgroundColor)
    }

    private var cardBackground: Color {
        Color.primary.opacity(0.055)
    }

}
