import AppKit

@MainActor
final class PanelViewController: NSViewController {
    enum Role {
        case left
        case main
        case right
    }

    private let role: Role
    private weak var contentContainer: NSView?
    private var contentWidthConstraint: NSLayoutConstraint?
    private weak var titleLabel: NSTextField?
    private weak var messageLabel: NSTextField?
    private weak var separator: NSView?
    private weak var mainLabel: NSTextField?

    init(role: Role) {
        self.role = role
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let rootView = NSView()
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = backgroundColor.cgColor
        rootView.setAccessibilityRole(.group)
        rootView.setAccessibilityLabel(accessibilityLabel)
        view = rootView

        switch role {
        case .left:
            installSidePanel(title: "TASKS", message: "No tasks yet.")
        case .main:
            installMainPlaceholder()
        case .right:
            installSidePanel(title: "SIDE PANEL", message: "Nothing here yet.")
        }
    }

    func setContentVisible(_ visible: Bool) {
        contentContainer?.isHidden = !visible
    }

    func setContentWidth(_ width: CGFloat) {
        contentWidthConstraint?.constant = width
    }

    func applyTheme() {
        view.layer?.backgroundColor = backgroundColor.cgColor
        titleLabel?.font = AppTheme.font(ofSize: AppTheme.typography.label, weight: 600)
        titleLabel?.textColor = AppTheme.tertiaryText
        messageLabel?.font = AppTheme.font(ofSize: AppTheme.typography.body)
        messageLabel?.textColor = AppTheme.tertiaryText
        separator?.layer?.backgroundColor = AppTheme.subtleBorder.cgColor
        mainLabel?.font = AppTheme.font(ofSize: AppTheme.typography.body, weight: 500)
        mainLabel?.textColor = AppTheme.tertiaryText
    }

    private var backgroundColor: NSColor {
        role == .main ? AppTheme.background : AppTheme.chromeBackground
    }

    private var accessibilityLabel: String {
        switch role {
        case .left: "Task panel"
        case .main: "Main content"
        case .right: "Right panel"
        }
    }

    private func installSidePanel(title: String, message: String) {
        let contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.label, weight: 600)
        titleLabel.textColor = AppTheme.tertiaryText
        titleLabel.usesSingleLineMode = true

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = AppTheme.subtleBorder.cgColor

        let messageLabel = NSTextField(labelWithString: message)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = AppTheme.font(ofSize: AppTheme.typography.body)
        messageLabel.textColor = AppTheme.tertiaryText

        view.addSubview(contentContainer)
        contentContainer.addSubview(titleLabel)
        contentContainer.addSubview(separator)
        contentContainer.addSubview(messageLabel)

        let initialWidth =
            role == .left ? AppTheme.leftPanelWidth : AppTheme.rightPanelWidth
        let contentWidthConstraint =
            contentContainer.widthAnchor.constraint(equalToConstant: initialWidth)
        let contentEdgeConstraint =
            role == .right
            ? contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            : contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor)

        self.contentContainer = contentContainer
        self.contentWidthConstraint = contentWidthConstraint
        self.titleLabel = titleLabel
        self.messageLabel = messageLabel
        self.separator = separator

        NSLayoutConstraint.activate([
            contentEdgeConstraint,
            contentWidthConstraint,
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            titleLabel.heightAnchor.constraint(equalToConstant: 42),

            separator.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            separator.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 41),
            separator.heightAnchor.constraint(equalToConstant: 1),

            messageLabel.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 14),
            messageLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 18),
        ])
    }

    private func installMainPlaceholder() {
        let label = NSTextField(labelWithString: "Main content")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = AppTheme.font(ofSize: AppTheme.typography.body, weight: 500)
        label.textColor = AppTheme.tertiaryText
        view.addSubview(label)
        mainLabel = label

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
