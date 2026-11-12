import AppKit
import SwiftUI

/// AeroSpace's password prompt for `sudo -A` (see `AskpassServer`): the focused screen dims, one
/// compact card holds a lock and the password field, and a pill above it says who wants to run
/// what. No buttons: Enter submits, Esc cancels, a click on the dimmed screen refocuses the field.
///
/// sudo checks the password itself and, when it is wrong, simply asks again. So after Enter the
/// card says "Checking…" for a moment: the same sudo asking again means the password was wrong
/// (red, shake, retry in place); silence means it was right and the card fades out.
@MainActor
final class AskpassPanel {
    static let shared = AskpassPanel()
    /// A request nobody types into is cancelled
    static let timeoutSeconds: Double = 60
    /// How long a submitted password waits for sudo to ask again (= wrong) before closing
    static let settleSeconds: Double = 1.5

    private var window: AskpassWindow?
    private let model = AskpassModel()
    private var current: (request: AskpassRequest, reply: CheckedContinuation<String?, Never>)?
    private var waiting: [(AskpassRequest, CheckedContinuation<String?, Never>)] = []
    private var timeout: DispatchWorkItem?
    private var settle: DispatchWorkItem?
    /// The sudo whose password was just submitted, while waiting to see whether it asks again
    private var checkingSudo: pid_t?
    private var previousApp: pid_t?

    private init() {}

    /// The typed password, or nil when cancelled, timed out, or no panel can be shown (tests)
    func ask(_ request: AskpassRequest) async -> String? {
        guard Headless.permits(.onScreenPanel) else { return nil }
        return await withCheckedContinuation { continuation in
            if checkingSudo == request.sudoPid {
                // The same sudo asking again right after a submit: that password was wrong
                settle?.cancel()
                settle = nil
                checkingSudo = nil
                present(request, continuation, wrongPassword: true)
            } else {
                waiting.append((request, continuation))
                if current == nil, checkingSudo == nil { showNext() }
            }
        }
    }

    private func showNext() {
        guard !waiting.isEmpty else { close(); return }
        let (request, continuation) = waiting.removeFirst()
        present(request, continuation, wrongPassword: false)
    }

    private func present(_ request: AskpassRequest, _ reply: CheckedContinuation<String?, Never>, wrongPassword: Bool) {
        current = (request, reply)
        model.request = request
        model.password = ""
        model.state = .input
        if wrongPassword { model.flashWrong() }
        if previousApp == nil { previousApp = SystemServices.frontmostAppPid() }
        let window = self.window ?? makeWindow()
        self.window = window
        let screen = DisplayRefresh.nsScreen(for: focus.workspace.workspaceMonitor) ?? NSScreen.main
        if let screen { window.setFrame(screen.frame, display: true) }
        if !window.isVisible {
            window.alphaValue = 0
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; window.animator().alphaValue = 1 }
        } else {
            window.makeKey()
        }
        model.focusTick += 1
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.cancel() }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeoutSeconds, execute: work)
    }

    fileprivate func submit() {
        guard let current, !model.password.isEmpty, model.state == .input else { return }
        let password = model.password
        model.password = ""
        model.state = .checking
        timeout?.cancel()
        self.current = nil
        checkingSudo = current.request.sudoPid
        current.reply.resume(returning: password)
        let work = DispatchWorkItem { [weak self] in
            // sudo did not ask again: accepted
            self?.checkingSudo = nil
            self?.showNext()
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleSeconds, execute: work)
    }

    fileprivate func cancel() {
        timeout?.cancel()
        model.password = ""
        guard let current else { return }
        self.current = nil
        current.reply.resume(returning: nil)
        showNext()
    }

    private func close() {
        timeout?.cancel()
        settle?.cancel()
        model.password = ""
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; window.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated {
                guard self.current == nil else { return } // a new request arrived meanwhile
                window.orderOut(nil)
                self.model.request = nil
                if let pid = self.previousApp { SystemServices.activateApp(pid: pid) }
                self.previousApp = nil
            }
        }
    }

    private func makeWindow() -> AskpassWindow {
        let window = AskpassWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .modalPanel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.onCancel = { [weak self] in self?.cancel() }
        let host = NSHostingView(rootView: AskpassView(
            model: model,
            submit: { [weak self] in self?.submit() },
            cancel: { [weak self] in self?.cancel() },
        ))
        window.contentView = host
        return window
    }
}

/// Borderless, yet takes the keyboard
final class AskpassWindow: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_: Any?) { onCancel?() }
}

@MainActor
final class AskpassModel: ObservableObject {
    enum State { case input, checking, wrong }
    @Published var request: AskpassRequest?
    @Published var password = ""
    @Published var state: State = .input
    @Published var shake: CGFloat = 0
    /// Bumped whenever the field should take focus again
    @Published var focusTick = 0

    func flashWrong() {
        state = .wrong
        Task { @MainActor in
            for x: CGFloat in [-8, 8, 0] {
                withAnimation(.easeOut(duration: 0.05)) { shake = x }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            if state == .wrong { state = .input }
        }
    }
}

struct AskpassView: View {
    @ObservedObject var model: AskpassModel
    let submit: () -> Void
    let cancel: () -> Void
    @FocusState private var fieldFocused: Bool

    private var bar: StatusBarConfig { config.statusBar }
    private var background: Color { Color(nsColor: NSColor(hex: bar.background) ?? .black) }
    private var foreground: Color { Color(nsColor: NSColor(hex: bar.foreground) ?? .white) }
    private var accent: Color { Color(nsColor: NSColor(hex: bar.focusedBackground) ?? .systemBlue) }
    private let errorColor = Color(red: 0.95, green: 0.55, blue: 0.66)
    private var isWrong: Bool { model.state == .wrong }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { fieldFocused = true }
            VStack(spacing: 10) {
                pill
                card
            }
            .offset(x: model.shake)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: model.focusTick) { _ in fieldFocused = true }
    }

    /// What is being authorized: who asks, as whom, and the exact command
    private var pill: some View {
        Text(label)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .frame(maxWidth: 560)
            .background(RoundedRectangle(cornerRadius: 10).fill(background))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var card: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isWrong ? errorColor : accent)
                .frame(width: 26)
            ZStack(alignment: .leading) {
                if model.password.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 20, design: .monospaced))
                        .foregroundStyle(isWrong ? errorColor : foreground.opacity(0.36))
                        .allowsHitTesting(false)
                }
                SecureField("", text: $model.password)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, design: .monospaced))
                    .foregroundStyle(foreground)
                    .focused($fieldFocused)
                    .disabled(model.state != .input)
                    .onSubmit(submit)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 312, height: 74)
        .background(RoundedRectangle(cornerRadius: 10).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isWrong ? errorColor : foreground.opacity(0.18), lineWidth: 2))
        .onExitCommand(perform: cancel)
    }

    private var placeholder: String {
        switch model.state {
            case .input: "Enter password"
            case .checking: "Checking…"
            case .wrong: "Wrong"
        }
    }

    private var label: String {
        guard let r = model.request else { return "Authentication is needed" }
        return "\(askpassRequesterLabel(r.requesters)) · as \(r.runAs): \(askpassDisplayCommand(r.command))"
    }
}

/// argv as a shell line, quoting what needs it
func askpassDisplayCommand(_ argv: [String]) -> String {
    argv.map { arg in
        arg.isEmpty || arg.contains(where: { " \"'$`\\".contains($0) }) ? "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'" : arg
    }.joined(separator: " ")
}
