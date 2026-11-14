import SwiftUI
import AppKit
import LessonNotesCore

struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.sidebar) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.icon)
                        .badge(badge(for: item))
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    if !model.isOnline { Label("Offline", systemImage: "wifi.slash").foregroundStyle(.orange) }
                    if model.isPaused && !model.isDemo { Label("Processing paused", systemImage: "pause.circle").foregroundStyle(.orange) }
                    Text("Version \(AppInfo.version)").foregroundStyle(.tertiary)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
        } detail: {
            Group {
                switch model.sidebar ?? .dashboard {
                case .dashboard: DashboardView()
                case .history: HistoryView()
                case .students: StudentsView()
                case .settings: SettingsView()
                }
            }
        }
        .sheet(item: $model.reviewRequest) { req in
            ConfirmationSheet(request: req)
                .environmentObject(model)
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
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(banner).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.banner = nil }
                }
                .padding(10)
                .background(.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                .padding()
            }
        }
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    func badge(for item: SidebarItem) -> Int {
        switch item {
        case .dashboard: return model.detections.count + model.attentionJobs.count
        default: return 0
        }
    }
}
