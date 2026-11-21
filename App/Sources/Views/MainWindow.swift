import SwiftUI
import AppKit
import LessonNotesCore

struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 280)
        } detail: {
            ZStack {
                Theme.bg.ignoresSafeArea()
                if let req = model.reviewRequest {
                    ConfirmationScreen(request: req)
                        .id(req.id)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .opacity.combined(with: .scale(scale: 0.98))))
                } else {
                    Group {
                        switch model.sidebar ?? .dashboard {
                        case .dashboard: DashboardView()
                        case .history: HistoryView()
                        case .students: StudentsView()
                        case .videos: VideosView()
                        case .usage: UsageView()
                        case .settings: SettingsView()
                        }
                    }
                    .id(model.sidebar ?? .dashboard)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .animation(Theme.spring, value: model.reviewRequest?.id)
            .animation(.easeOut(duration: 0.22), value: model.sidebar)
            .toolbarBackground(Theme.bg, for: .windowToolbar)
            .scrollContentBackground(.hidden)
        }
        .tint(Theme.forest)
        .alert(item: $model.retryConfirmation) { c in
            Alert(title: Text("Transcribe \(c.pupil.isEmpty ? "this lesson" : c.pupil + "'s lesson") again?"),
                  message: Text(c.reason),
                  primaryButton: .default(Text("Transcribe Again")) { model.confirmRetry(c) },
                  secondaryButton: .cancel())
        }
        .sheet(isPresented: $model.showImport) {
            ImportView(roots: model.importRoots)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
                .environmentObject(model)
                .environmentObject(model.whisper)
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                HStack(spacing: 10) {
                    IconBadge(systemName: "exclamationmark.triangle", tone: .clay, size: 28)
                    Text(banner).font(.system(size: 13)).foregroundStyle(Theme.ink).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { withAnimation(Theme.spring) { model.banner = nil } }.buttonStyle(.softCompact)
                }
                .cardSurface(padding: 12, radius: 16, fill: Theme.clay)
                .padding()
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast, onView: toast.lessonId == nil ? nil : {
                    model.toast = nil
                    if let id = toast.lessonId { model.openLesson(id) }
                })
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
                    .task(id: toast.id) {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        if model.toast?.id == toast.id { withAnimation(Theme.spring) { model.toast = nil } }
                    }
            }
        }
        .animation(Theme.spring, value: model.toast)
        .animation(Theme.spring, value: model.banner)
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Brand, navigation and status line.
struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Namespace private var selectionSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                AppLogo(size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lesson Notes").font(Theme.serif(21)).foregroundStyle(Theme.ink)
                    Text("LetsMeet").font(.system(size: 9.5, weight: .medium)).tracking(1.6).textCase(.uppercase).foregroundStyle(Theme.ink3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 22)

            VStack(spacing: 2) {
                ForEach(SidebarItem.allCases) { item in navButton(item) }
            }

            Spacer(minLength: 12)
            footer
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.ignoresSafeArea())
    }

    func navButton(_ item: SidebarItem) -> some View {
        let selected = (model.sidebar ?? .dashboard) == item && model.reviewRequest == nil
        let count = badge(for: item)
        return Button {
            withAnimation(Theme.spring) {
                model.reviewRequest = nil
                model.sidebar = item
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 18)
                Text(item.title).font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.onForest)
                        .padding(.horizontal, 7).padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.forest))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(selected ? Theme.ink : Theme.ink2)
            .padding(.horizontal, 11).padding(.vertical, 8.5)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Theme.surface)
                        .shadow(color: .black.opacity(0.06), radius: 1.5, x: 0, y: 1)
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "\(item.title), \(count)" : item.title)
        .animation(Theme.spring, value: count)
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.isOnline { status("Offline", color: Theme.clayInk) }
            if model.isPaused && !model.isDemo { status("Processing paused", color: Theme.sandInk) }
            if model.settings.openAIPaused { status("OpenAI paused", color: Theme.lavInk) }
            status(watchLine + " · v\(AppInfo.version)", color: model.settings.watchFolder && model.zoomFolderURL != nil ? Theme.sage : Theme.ink3)
        }
        .padding(.horizontal, 8)
    }

    var watchLine: String {
        model.settings.watchFolder && model.zoomFolderURL != nil ? "Watching Zoom folder" : "Not watching"
    }

    func status(_ text: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.ink3).lineLimit(1)
        }
    }

    func badge(for item: SidebarItem) -> Int {
        switch item {
        case .dashboard: return model.detections.count + model.attentionJobs.count
        case .videos: return model.failedVideoJobs.count
        default: return 0
        }
    }
}
