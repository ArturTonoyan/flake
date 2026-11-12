import AppKit

/// Modal sign editor for a snowman. Uses a keyable panel so an LSUIElement /
/// `.accessory` app can still accept typing and paste (⌘V) into the field.
final class SnowmanSignPrompt {
    enum Result {
        case save(String)
        case clear
        case cancel
    }

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private var panel: KeyPanel?
    private var field: NSTextField?
    private var continuation: ((Result) -> Void)?
    private var windowDelegate: PromptWindowDelegate?
    private var fieldDelegate: PromptFieldDelegate?

    var isPresented: Bool { panel != nil }

    func present(initialText: String, maxCharacters: Int, completion: @escaping (Result) -> Void) {
        if isPresented {
            completion(.cancel)
            return
        }

        continuation = completion

        NSApp.activate(ignoringOtherApps: true)

        let width: CGFloat = 340
        let height: CGFloat = 156
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Табличка снеговика"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let windowDelegate = PromptWindowDelegate { [weak self] in
            self?.finish(.cancel)
        }
        self.windowDelegate = windowDelegate
        panel.delegate = windowDelegate

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let hint = NSTextField(wrappingLabelWithString:
            "Напиши или вставь текст (⌘V). Потом кинь снеговика за край — друг увидит надпись."
        )
        hint.frame = NSRect(x: 16, y: 88, width: width - 32, height: 44)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)

        let field = NSTextField(frame: NSRect(x: 16, y: 52, width: width - 32, height: 24))
        field.stringValue = initialText
        field.placeholderString = "Например: Привет!"
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.maximumNumberOfLines = 1
        field.font = .systemFont(ofSize: 13)
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
        }
        let fieldDelegate = PromptFieldDelegate(maxCharacters: maxCharacters)
        self.fieldDelegate = fieldDelegate
        field.delegate = fieldDelegate
        content.addSubview(field)

        let clear = NSButton(
            title: "Убрать табличку",
            target: self,
            action: #selector(clearTapped)
        )
        clear.bezelStyle = .rounded
        clear.frame = NSRect(x: 16, y: 14, width: 130, height: 28)
        content.addSubview(clear)

        let cancel = NSButton(
            title: "Отмена",
            target: self,
            action: #selector(cancelTapped)
        )
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: width - 176, y: 14, width: 72, height: 28)
        cancel.keyEquivalent = "\u{1b}"
        content.addSubview(cancel)

        let save = NSButton(
            title: "Готово",
            target: self,
            action: #selector(saveTapped)
        )
        save.bezelStyle = .rounded
        save.frame = NSRect(x: width - 96, y: 14, width: 80, height: 28)
        save.keyEquivalent = "\r"
        content.addSubview(save)

        panel.contentView = content
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)

        self.panel = panel
        self.field = field

        // Second pass after AppKit finishes key-window setup (accessory apps).
        DispatchQueue.main.async { [weak self, weak panel, weak field] in
            guard let self, let panel, let field, self.panel === panel else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    @objc private func saveTapped() {
        finish(.save(field?.stringValue ?? ""))
    }

    @objc private func clearTapped() {
        finish(.clear)
    }

    @objc private func cancelTapped() {
        finish(.cancel)
    }

    private func finish(_ result: Result) {
        guard continuation != nil else { return }
        let done = continuation
        continuation = nil
        field?.delegate = nil
        field = nil
        fieldDelegate = nil
        if let panel {
            panel.delegate = nil
            panel.orderOut(nil)
            self.panel = nil
        }
        windowDelegate = nil
        done?(result)
    }
}

private final class PromptWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

private final class PromptFieldDelegate: NSObject, NSTextFieldDelegate {
    private let maxCharacters: Int
    init(maxCharacters: Int) { self.maxCharacters = maxCharacters }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field.stringValue.count > maxCharacters {
            field.stringValue = String(field.stringValue.prefix(maxCharacters))
            field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
        }
    }
}
