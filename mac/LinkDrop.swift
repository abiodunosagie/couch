import AppKit

/// A clear view laid over the menu bar icon that takes dropped web links and sends them to the TV.
final class LinkDropView: NSView {
    var onLink: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.URL, .string])
    }

    required init?(coder: NSCoder) { nil }

    // Clicks go through to the icon underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        link(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = link(from: sender) else { return false }
        onLink?(url)
        return true
    }

    private func link(from info: NSDraggingInfo) -> URL? {
        let board = info.draggingPasteboard
        let url = (board.readObjects(forClasses: [NSURL.self]) as? [URL])?.first
            ?? board.string(forType: .string).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}
