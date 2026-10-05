import AppKit

/// Window-owned feedback survives retiring a download-only popup, without taking focus.
@MainActor final class DownloadActivityView: NSView {
    enum State: Equatable { case preparing, downloading, saved(URL), failed }
    private(set) var state: State = .preparing
    let filename = NSTextField(labelWithString: "Starting download…")
    let status = NSTextField(labelWithString: "Connecting…")
    let progressBar = NSProgressIndicator()
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private var timer: Timer?
    private weak var panel: DownloadActivityPanel?

    init() {
        super.init(frame: .zero)
        filename.font = .systemFont(ofSize: 12, weight: .semibold)
        filename.lineBreakMode = .byTruncatingMiddle
        filename.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let dismiss = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss download notification")!,
                               target: self, action: #selector(dismissActivity))
        dismiss.isBordered = false
        dismiss.controlSize = .small
        dismiss.toolTip = "Dismiss notification (download continues)"
        dismiss.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let heading = NSStackView(views: [filename, dismiss])
        heading.distribution = .fill; heading.spacing = 8
        progressBar.style = .bar; progressBar.isIndeterminate = true
        progressBar.controlSize = .small
        progressBar.startAnimation(nil)
        revealButton.target = self; revealButton.action = #selector(reveal)
        revealButton.controlSize = .small; revealButton.isHidden = true
        let stack = NSStackView(views: [heading, status, progressBar, revealButton])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        setAccessibilityLabel("Download")
    }
    required init?(coder: NSCoder) { fatalError("init()") }

    func show(in window: NSWindow?) {
        guard let content = window?.contentView else { return }
        let panel = content.subviews.compactMap { $0 as? DownloadActivityPanel }.first ?? DownloadActivityPanel(in: content)
        self.panel = panel
        panel.append(self)
    }

    func start(filename: String, progress: Progress?) {
        self.filename.stringValue = filename
        self.filename.toolTip = filename
        state = .downloading
        status.stringValue = "Downloading…"
        guard let progress else { return }
        updateProgress(progress)
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateProgress(progress) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func updateProgress(_ progress: Progress) {
        guard state == .downloading else { return }
        let received = ByteCountFormatter.string(fromByteCount: progress.completedUnitCount, countStyle: .file)
        if progress.totalUnitCount > 0 {
            progressBar.isIndeterminate = false
            progressBar.maxValue = 1
            progressBar.doubleValue = progress.fractionCompleted
            let total = ByteCountFormatter.string(fromByteCount: progress.totalUnitCount, countStyle: .file)
            status.stringValue = "Downloading · \(received) of \(total)"
        } else {
            status.stringValue = progress.completedUnitCount > 0 ? "Downloading · \(received)" : "Downloading…"
        }
        progressBar.setAccessibilityValue(status.stringValue)
    }

    func finish(_ result: Result<URL, Error>) {
        timer?.invalidate(); timer = nil
        progressBar.stopAnimation(nil); progressBar.isHidden = true
        switch result {
        case .success(let url):
            state = .saved(url)
            filename.stringValue = url.lastPathComponent
            status.stringValue = "Download complete"
            revealButton.isHidden = false
        case .failure(let error):
            state = .failed
            status.stringValue = "Download failed · \(error.localizedDescription)"
            status.toolTip = error.localizedDescription
            status.textColor = .systemRed
        }
        panel?.trimCompleted()
    }

    @objc func dismissActivity() {
        timer?.invalidate(); timer = nil
        panel?.remove(self)
    }
    @objc private func reveal() {
        if case .saved(let url) = state { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

@MainActor private final class DownloadActivityPanel: NSVisualEffectView {
    private let rows = NSStackView()
    init(in content: NSView) {
        super.init(frame: .zero)
        material = .popover; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 12
        layer?.borderWidth = 0.5; layer?.borderColor = NSColor.separatorColor.cgColor
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 16
        translatesAutoresizingMaskIntoConstraints = false
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows); content.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            topAnchor.constraint(equalTo: content.topAnchor, constant: 70),
            widthAnchor.constraint(equalToConstant: 320),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(in:)") }
    func append(_ row: DownloadActivityView) {
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        trimCompleted()
    }
    func remove(_ row: DownloadActivityView) {
        rows.removeArrangedSubview(row); row.removeFromSuperview()
        if rows.arrangedSubviews.isEmpty { removeFromSuperview() }
    }
    func trimCompleted() {
        let completed = rows.arrangedSubviews.compactMap { $0 as? DownloadActivityView }.filter {
            switch $0.state { case .saved, .failed: return true; default: return false }
        }
        for row in completed.dropLast(3) { remove(row) }
    }
}
