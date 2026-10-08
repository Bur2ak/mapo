import SwiftUI

/// First-run / empty library. One clear action, and the whole window is a
/// drop target (handled by `ContentView`).
struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model
    let isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .scaleEffect(isDropTargeted ? 1.08 : 1)

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

            HStack(spacing: 12) {
                Button("Klasör Seç…") { FolderPicker.present(model: model) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.accent)
                Button("GitHub'dan Ekle…") { NotificationCenter.default.post(name: .showGitHubSheet, object: nil) }
            }
            .controlSize(.large)

            Button("Önce örnek bir haritaya bak") { Task { await model.openSample() } }
                .buttonStyle(.link)
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
