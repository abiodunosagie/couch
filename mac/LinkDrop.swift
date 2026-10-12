import AppKit

/// A clear view laid over the menu bar icon that takes dropped web links and sends them to the TV.
/// It sits on top, so it receives the clicks too and passes them on to the icon.
final class LinkDropView: NSView {
    var onLink: ((URL) -> Void)?
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.URL, .string])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

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
        return url?.isWebLink == true ? url : nil
    }
}
