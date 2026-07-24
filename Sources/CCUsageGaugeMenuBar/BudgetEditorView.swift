import AppCore
import AppKit

@MainActor
final class BudgetEditorView: NSView {
  let budgetField: NSTextField
  private let machineButtons: [(id: String, button: NSButton)]

  var selectedMachineIDs: [String] {
    machineButtons.compactMap { $0.button.state == .on ? $0.id : nil }
  }

  init(budget: String, machines: [MachineDescriptor], selectedMachineIDs: Set<String>) {
    budgetField = NSTextField(string: budget)
    machineButtons = machines.map { machine in
      let button = NSButton(
        checkboxWithTitle: machine.displayName == machine.id
          ? machine.displayName
          : "\(machine.displayName) (\(machine.id))",
        target: nil,
        action: nil
      )
      button.state = selectedMachineIDs.contains(machine.id) ? .on : .off
      button.setAccessibilityLabel("Include \(machine.displayName) in budget")
      return (machine.id, button)
    }
    super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 250))
    buildLayout()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func buildLayout() {
    let budgetLabel = NSTextField(labelWithString: "Budget (USD)")
    let machinesLabel = NSTextField(labelWithString: "Machines to include")
    budgetField.setAccessibilityLabel("Budget in USD")

    let machineStack = NSStackView(views: machineButtons.map(\.button))
    machineStack.orientation = .vertical
    machineStack.alignment = .leading
    machineStack.spacing = 6
    machineStack.translatesAutoresizingMaskIntoConstraints = false

    let documentView = NSView()
    documentView.translatesAutoresizingMaskIntoConstraints = false
    documentView.addSubview(machineStack)

    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.borderType = .bezelBorder
    scrollView.documentView = documentView
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    let contentStack = NSStackView(views: [budgetLabel, budgetField, machinesLabel, scrollView])
    contentStack.orientation = .vertical
    contentStack.alignment = .leading
    contentStack.spacing = 8
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contentStack)

    NSLayoutConstraint.activate([
      contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      contentStack.topAnchor.constraint(equalTo: topAnchor),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
      budgetField.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      scrollView.heightAnchor.constraint(equalToConstant: 170),
      documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
      machineStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 8),
      machineStack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -8),
      machineStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 8),
      machineStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -8)
    ])
  }
}
