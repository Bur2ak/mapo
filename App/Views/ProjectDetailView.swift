import AtlasCore
import SwiftUI

/// Project workspace. Faz 0: header only; the map arrives in Faz 1.
struct ProjectDetailView: View {
    let project: Project

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "map")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Palette.labelMuted)
            Text(project.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.label)
            Text("Henüz indekslenmedi")
                .font(.callout)
                .foregroundStyle(Palette.labelMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(project.name)
        .navigationSubtitle((project.rootPath as NSString).abbreviatingWithTildeInPath)
    }
}
