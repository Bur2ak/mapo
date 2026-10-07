import AtlasCore
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
            if UserDefaults.standard.bool(forKey: "atlasOpenSettings") { openSettings() }
        }
        #endif
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}
