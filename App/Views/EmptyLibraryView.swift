import SwiftUI

/// First-run / empty library. One clear action, and the whole window is a
/// drop target (handled by `ContentView`).
struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model
    let isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isDropTargeted ? Palette.accent : Palette.labelMuted)
                .symbolEffect(.bounce, value: isDropTargeted)

            VStack(spacing: 6) {
                Text("Bir projenin haritasını çıkar")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.label)
                Text("Proje klasörünü bu pencereye bırak ya da seç. Kodun bilgisayarından çıkmaz.")
                    .font(.callout)
                    .foregroundStyle(Palette.labelMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button("Klasör Seç…") { FolderPicker.present(model: model) }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isDropTargeted)
    }
}
