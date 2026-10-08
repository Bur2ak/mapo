import SwiftUI

/// First-run tour: what the map shows, how to read links, what agents get.
/// Three pages, then a sample map or the user's own folder.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    #if DEBUG
    @State private var page = UserDefaults.standard.integer(forKey: "mapoOnboardingPage")
    #else
    @State private var page = 0
    #endif

    private let pages: [(title: LocalizedStringKey, body: LocalizedStringKey, art: Art)] = [
        ("Kodunun haritası",
         "Mapo bir projeyi haritaya çevirir: her halka bir klasör, içindeki her daire bir dosya. Daire ne kadar büyükse dosya o kadar uzun. Kodun bilgisayarından çıkmaz.",
         .regions),
        ("Bağlantıları gör",
         "Bir dosyaya ya da fonksiyona tıkla: turuncu oklar kullandıklarını, mavi oklar onu kullananları gösterir. Klasöre tıklayınca içine girersin. \"Yol bul\" iki parça arasındaki zinciri, \"Etki alanı\" bir değişikliğin nereleri etkileyeceğini gösterir.",
         .links),
        ("Ajanına haritayı ver",
         "Claude Code, Codex, Cursor ya da Claude Desktop'ı Ayarlar › Entegrasyonlar'dan tek tıkla bağla. Ajanın \"bunu kim çağırıyor\", \"bu değişirse ne bozulur\" sorularını haritaya sorar.",
         .agents),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Illustration(art: pages[page].art)
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .background(Palette.canvas)
                .id(page)
                .transition(.opacity)

            VStack(alignment: .leading, spacing: 10) {
                Text(pages[page].title)
                    .font(.title2.weight(.semibold))
                Text(pages[page].body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .frame(height: 128, alignment: .top)

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Palette.accent : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Sayfa \(page + 1) / \(pages.count)"))
                Spacer()
                if page < pages.count - 1 {
                    Button("Atla") { model.finishOnboarding() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    Button("Devam") { withAnimation(.easeOut(duration: 0.18)) { page += 1 } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.accent)
                } else {
                    Button("Kendi Projemi Ekle…") {
                        model.finishOnboarding()
                        FolderPicker.present(model: model)
                    }
                    Button("Örnek Projeyle Başla") {
                        model.finishOnboarding()
                        Task { await model.openSample() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.accent)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .frame(width: 560)
        .background(.background)
        .onKeyPress(.rightArrow) {
            guard page < pages.count - 1 else { return .ignored }
            withAnimation(.easeOut(duration: 0.18)) { page += 1 }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard page > 0 else { return .ignored }
            withAnimation(.easeOut(duration: 0.18)) { page -= 1 }
            return .handled
        }
    }
}

enum Art { case regions, links, agents }

/// Drawn in the map's own language (rings, discs, curved arrows) so the tour
/// shows exactly what the user will see.
private struct Illustration: View {
    let art: Art
    @Environment(\.colorScheme) private var scheme

    private var teal: Color { Color(hex: scheme == .dark ? "#4FC1B3" : "#2E9C8F") }
    private var violet: Color { Color(hex: scheme == .dark ? "#9A8CF0" : "#6E5FD6") }
    private var coral: Color { Color(hex: scheme == .dark ? "#F07E6E" : "#D85B4A") }
    private let orange = Palette.accent
    private var blue: Color { Color(hex: scheme == .dark ? "#7FB2FF" : "#2F6FD6") }

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            switch art {
            case .regions:
                region(&ctx, CGPoint(x: c.x - 70, y: c.y), 88, teal, [(-28, -22, 26), (24, -30, 18), (20, 14, 24), (-30, 30, 16), (-2, 52, 11), (50, -2, 10)])
                region(&ctx, CGPoint(x: c.x + 72, y: c.y - 36), 46, violet, [(-12, 4, 18), (18, -10, 12), (12, 22, 9)])
                region(&ctx, CGPoint(x: c.x + 82, y: c.y + 50), 36, coral, [(-8, 4, 15), (16, -8, 9)])
            case .links:
                let sel = CGPoint(x: c.x, y: c.y + 10)
                region(&ctx, CGPoint(x: c.x - 175, y: c.y - 10), 46, coral, [(-10, 6, 16), (16, -12, 11)])
                region(&ctx, CGPoint(x: c.x + 175, y: c.y - 20), 48, violet, [(-10, 8, 17), (18, -10, 12), (8, 24, 8)])
                disc(&ctx, sel, 22, teal)
                ring(&ctx, sel, 30, orange, 3)
                arrow(&ctx, from: CGPoint(x: sel.x + 38, y: sel.y - 6), to: CGPoint(x: c.x + 124, y: c.y - 22), bend: 0.18, orange)
                arrow(&ctx, from: CGPoint(x: c.x - 126, y: c.y - 14), to: CGPoint(x: sel.x - 38, y: sel.y - 2), bend: 0.18, blue)
                badge(&ctx, CGPoint(x: c.x - 82, y: c.y + 2), "3", blue)
            case .agents:
                region(&ctx, CGPoint(x: c.x + 100, y: c.y), 80, teal, [(-24, -20, 24), (22, -26, 17), (18, 16, 22), (-28, 28, 15), (44, 4, 10)])
                let term = CGRect(x: c.x - 230, y: c.y - 50, width: 160, height: 100)
                ctx.fill(Path(roundedRect: term, cornerRadius: 10), with: .color(Color.primary.opacity(0.07)))
                ctx.stroke(Path(roundedRect: term, cornerRadius: 10), with: .color(Color.primary.opacity(0.15)), lineWidth: 1)
                let lines: [(String, Color)] = [("› kim çağırıyor?", .primary), ("mapo_callers …", orange), ("3 yerden", .secondary)]
                for (i, l) in lines.enumerated() {
                    ctx.draw(Text(l.0).font(.system(size: 12, design: .monospaced)).foregroundStyle(l.1),
                             at: CGPoint(x: term.minX + 14, y: term.minY + 24 + CGFloat(i) * 24), anchor: .leading)
                }
                arrow(&ctx, from: CGPoint(x: term.maxX + 10, y: c.y + 4), to: CGPoint(x: c.x + 14, y: c.y - 6), bend: 0.2, orange)
            }
        }
        .accessibilityHidden(true)
    }

    private func region(_ ctx: inout GraphicsContext, _ at: CGPoint, _ r: CGFloat, _ color: Color, _ files: [(CGFloat, CGFloat, CGFloat)]) {
        let rect = CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r)
        ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.14)))
        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 0.75, dy: 0.75)), with: .color(color.opacity(0.55)), lineWidth: 1.5)
        for f in files { disc(&ctx, CGPoint(x: at.x + f.0, y: at.y + f.1), f.2, color) }
    }

    private func disc(_ ctx: inout GraphicsContext, _ at: CGPoint, _ r: CGFloat, _ color: Color) {
        ctx.fill(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
    }

    private func ring(_ ctx: inout GraphicsContext, _ at: CGPoint, _ r: CGFloat, _ color: Color, _ w: CGFloat) {
        ctx.stroke(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r)), with: .color(color), lineWidth: w)
    }

    private func arrow(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, bend: CGFloat, _ color: Color) {
        let mid = CGPoint(x: (a.x + b.x) / 2 - (b.y - a.y) * bend, y: (a.y + b.y) / 2 + (b.x - a.x) * bend)
        var p = Path()
        p.move(to: a)
        p.addQuadCurve(to: b, control: mid)
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        let ang = atan2(b.y - mid.y, b.x - mid.x), L: CGFloat = 10
        var head = Path()
        head.move(to: b)
        head.addLine(to: CGPoint(x: b.x - L * cos(ang - 0.45), y: b.y - L * sin(ang - 0.45)))
        head.addLine(to: CGPoint(x: b.x - L * cos(ang + 0.45), y: b.y - L * sin(ang + 0.45)))
        head.closeSubpath()
        ctx.fill(head, with: .color(color))
    }

    private func badge(_ ctx: inout GraphicsContext, _ at: CGPoint, _ text: String, _ color: Color) {
        let rect = CGRect(x: at.x - 10, y: at.y - 9, width: 20, height: 18)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 9), with: .color(color))
        ctx.draw(Text(text).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.black.opacity(0.85)), at: at)
    }
}
