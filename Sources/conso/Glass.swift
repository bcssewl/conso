import SwiftUI
import AppKit

/// Behind-window blur (the frosted "Liquid Glass" backdrop) for translucent themes.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Makes the hosting NSWindow non-opaque so the behind-window blur shows through.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Standard conso card surface: a glass material (or a solid fill on opaque
    /// themes), a hairline border, and a subtle top edge highlight.
    func consoCard(_ t: Tokens, corner: CGFloat? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner ?? t.corner, style: .continuous)
        return self
            .background(t.glass ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(t.card), in: shape)
            .overlay(shape.strokeBorder(t.cardBorder, lineWidth: 1))
            .overlay(alignment: .top) {
                if t.glass {
                    shape.stroke(Color.white.opacity(0.06), lineWidth: 1).mask(
                        LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)
                    )
                }
            }
    }
}
