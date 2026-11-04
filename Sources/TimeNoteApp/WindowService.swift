import AppKit
import SwiftUI

@MainActor
final class WindowService {
    private let windows = NSHashTable<NSWindow>.weakObjects()

    func attach(window: NSWindow?) {
        guard let window else { return }
        windows.add(window)
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        let level: NSWindow.Level = enabled ? .floating : .normal
        for window in windows.allObjects {
            window.level = level
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        ResolverView(onResolve: onResolve)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

private final class ResolverView: NSView {
    private let onResolve: (NSWindow?) -> Void
    private weak var lastResolvedWindow: NSWindow?

    init(onResolve: @escaping (NSWindow?) -> Void) {
        self.onResolve = onResolve
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard lastResolvedWindow !== window else { return }
        lastResolvedWindow = window
        onResolve(window)
    }
}
