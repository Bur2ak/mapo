import MapoCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ProjectSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            Group {
                if let project = model.selectedProject {
                    ProjectDetailView(project: project)
                        .id(project.id)
                } else {
                    EmptyLibraryView(isDropTargeted: isDropTargeted)
                }
            }
            .background(Palette.canvas)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !folders.isEmpty else { return false }
            Task { await model.addFolders(folders) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        #if DEBUG
        .task {
            let d = UserDefaults.standard
            if d.bool(forKey: "mapoOnboarding") { model.showOnboarding = true }
            if let out = d.string(forKey: "mapoDiagnosticsTo") {
                try? await Task.sleep(for: .seconds(2))
                try? Diagnostics.build(summary: Diagnostics.report(model: model), to: URL(fileURLWithPath: out))
            }
            if d.bool(forKey: "mapoSample") { model.finishOnboarding(); await model.openSample() }
            if let folder = d.string(forKey: "mapoIndexFolder") {
                model.finishOnboarding()
                await model.addFolders([URL(fileURLWithPath: folder)])
                if let id = model.selection { model.indexer.enqueue(id) }
            }
            if d.bool(forKey: "mapoOpenSettings") || d.string(forKey: "mapoSettingsTab") != nil { openSettings() }
            if d.bool(forKey: "mapoShowGitHub") {
                try? await Task.sleep(for: .milliseconds(600))
                NotificationCenter.default.post(name: .showGitHubSheet, object: nil)
                if d.bool(forKey: "mapoGitHubSignIn") { model.github.signIn() }
            }
        }
        #endif
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
                .environment(model)
                .interactiveDismissDisabled()
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}
