import SwiftUI
import StrandDesign

/// Native logbook (journal) logging for the merged behaviour catalog plus a custom-question field,
/// hosted at the top of Insights and in the iOS Logbook sheet. Answers write under
/// `Repository.journalDeviceId` ("noop-journal"), NEVER the imported source, so a CSV re-import can't
/// clobber them and clearing is safe (imported rows are never touched). Tri-state: tapping the selected
/// answer again clears it. Day attribution follows the importer's wake-day convention, answers
/// describe the night and day leading into the selected morning, so logged days line up with imported
/// history.
///
/// v2 (#322): items sit under collapsible groups (Nutrition / Supplements / …); an item can be a
/// numeric value (with a unit) instead of a toggle; and custom items can be renamed / regrouped /
/// converted / reordered in edit mode. The stored KEY (`canonical`) never changes on a rename, so all
/// history, logged and imported, stays joined under the original question.
///
/// v3 (Zoop logbook): one day at a time behind a chevron day stepper, groups rendered as titled
/// squircle sections, and each behaviour answered with a pair of square X / ✓ buttons. A numeric item
/// reveals its "How much?" amount row only once ✓ is chosen; X stores an explicit zero.
struct JournalLogCard: View {
    @EnvironmentObject var repo: Repository
    /// The journal catalog is single-user state owned here (UserDefaults-backed), so hosting the card
    /// needs no app-level injection.
    @StateObject private var catalog = JournalCatalogStore()

    /// Distinct imported question strings (from the host's load), adopted into the catalog so
    /// logged answers and imported history group under the same behaviour.
    let importedQuestions: [String]
    /// question → answeredYes for the selected day, native rows only (drives the X / ✓ state).
    let answers: [String: Bool]
    /// question → numeric value for the selected day, native rows only (drives the amount rows).
    let numericAnswers: [String: Double]
    @Binding var dayOffset: Int            // -1 = tomorrow, 0 = today, 1 = yesterday
    let onChanged: () -> Void              // parent re-runs load() after a write

    init(importedQuestions: [String], answers: [String: Bool],
         numericAnswers: [String: Double] = [:], dayOffset: Binding<Int>,
         onChanged: @escaping () -> Void) {
        self.importedQuestions = importedQuestions
        self.answers = answers
        self.numericAnswers = numericAnswers
        self._dayOffset = dayOffset
        self.onChanged = onChanged
    }

    @State private var customDraft = ""
    @State private var customIsNumeric = false
    @State private var customGroup: JournalGroup = .other
    /// Edit mode: swaps the answer controls for rename/group/convert/remove and reveals hidden items.
    @State private var editing = false
    /// Collapsed groups (persisted per group).
    @AppStorage("journal.collapsedGroups") private var collapsedGroupsRaw = ""
    /// The item being renamed (drives the rename sheet).
    @State private var renaming: JournalCatalogItem?
    @State private var renameDraft = ""
    /// Numeric items whose ✓ was tapped but carry no stored value yet: the amount row is open, nothing
    /// is written until the user sets an amount (so ✓ never invents a value). Reset on a day change.
    @State private var pendingNumericYes: Set<String> = []

    /// Side of the square X / ✓ answer buttons.
    private static let decisionSize: CGFloat = ZoopMetrics.compactControlSize
    /// Continuous corner radius of the X / ✓ squares (a squircle, not a pill).
    private static let decisionRadius: CGFloat = 10
    /// Corner radius of the grouped section containers and the day stepper.
    private static let sectionRadius: CGFloat = 18

    private var selectedDate: Date {
        Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date()
    }

    private var dayKey: String { Repository.localDayKey(selectedDate) }

    /// The resolved, grouped catalog for the current imported set. Hidden items included only while
    /// editing (so they can be restored in place).
    private var resolved: [JournalCatalogItem] {
        catalog.resolvedItems(imported: importedQuestions, includeHidden: editing)
    }

    /// Items grouped by their group, each group ordered by sortIndex then display.
    private func items(in group: JournalGroup) -> [JournalCatalogItem] {
        resolved.filter { $0.group == group }
            .sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) }
    }

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsRaw.split(separator: ",").map(String.init))
    }

    private func toggleCollapsed(_ group: JournalGroup) {
        var set = collapsedGroups
        if set.contains(group.rawValue) { set.remove(group.rawValue) } else { set.insert(group.rawValue) }
        collapsedGroupsRaw = set.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.space5) {
            header
            if !editing {
                dayStepper
            }
            VStack(alignment: .leading, spacing: ZoopMetrics.space2) {
                if !editing {
                    Text(String(localized: "What happened on \(previousDayLabel)?"))
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(editing
                     ? "Rename, regroup, or remove an item to tidy your list. Renaming keeps the original question behind the scenes, so a WHOOP import still lines up. Custom items are deleted; built-in ones are hidden and can be restored below."
                     : dayOffset == -1
                     ? "Logging ahead for tomorrow: today's activities inform tomorrow's recovery, just as yesterday's are reflected in today's. Tomorrow's answers line up with tomorrow's morning."
                     : "Answers are about the night and day leading into this morning, the same attribution a WHOOP export uses, so logged and imported days line up.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(JournalGroup.displayOrder, id: \.self) { group in
                groupBlock(group)
            }

            addSection
        }
        .sheet(item: $renaming) { item in renameSheet(item) }
        .onChangeCompat(of: dayOffset) { _ in pendingNumericYes = [] }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Text(String(localized: "Logbook").uppercased())
                .font(StrandFont.headline)
                .tracking(1.2)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if editing {
                pillButton("Done", selected: true) { editing = false }
            } else {
                Button { editing = true } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: Self.decisionSize, height: Self.decisionSize)
                        .background(Circle().fill(StrandPalette.surfaceRaised))
                        .overlay(Circle().stroke(StrandPalette.hairline, lineWidth: ZoopMetrics.hairlineWidth))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Edit"))
            }
        }
    }

    // MARK: - Day stepper

    /// One day at a time (#656 range kept): ‹ older · the selected day · newer ›, bounded to Tomorrow
    /// back through 6 days ago. Journal answers feed the correlation engine, so unbounded backfill of
    /// stale days would distort it (matches WHOOP's limited retroactive window).
    private var dayStepper: some View {
        let canGoOlder = dayOffset < Self.oldestOffset
        let canGoNewer = dayOffset > Self.newestOffset
        return HStack(spacing: ZoopMetrics.space2) {
            stepperChevron("chevron.left", enabled: canGoOlder, label: "Previous day") {
                selectDay(dayOffset + 1)
            }
            Spacer(minLength: 0)
            VStack(spacing: ZoopMetrics.spaceHalf) {
                Text(selectedDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .uppercased())
                    .font(StrandFont.headline)
                    .tracking(0.8)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(journalDayLabel(dayOffset))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            stepperChevron("chevron.right", enabled: canGoNewer, label: "Next day") {
                selectDay(dayOffset - 1)
            }
        }
        .padding(ZoopMetrics.space2)
        .background(RoundedRectangle(cornerRadius: Self.sectionRadius, style: .continuous)
            .fill(StrandPalette.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: Self.sectionRadius, style: .continuous)
            .stroke(StrandPalette.hairline, lineWidth: ZoopMetrics.hairlineWidth))
    }

    private func stepperChevron(_ symbol: String, enabled: Bool, label: LocalizedStringKey,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                .frame(width: Self.decisionSize, height: Self.decisionSize)
                .background(RoundedRectangle(cornerRadius: Self.decisionRadius, style: .continuous)
                    .fill(StrandPalette.surfaceInset))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }

    private func selectDay(_ offset: Int) {
        let clamped = min(max(offset, Self.newestOffset), Self.oldestOffset)
        guard clamped != dayOffset else { return }
        dayOffset = clamped
        onChanged()   // reload the selected day's answers
    }

    /// The day the selected morning's answers describe (the day before it), for the headline question.
    private var previousDayLabel: String {
        let prev = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
        return prev.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    // MARK: - Group block

    @ViewBuilder private func groupBlock(_ group: JournalGroup) -> some View {
        let groupItems = items(in: group)
        // Empty groups hidden outside edit mode; in edit mode all six show so items can be moved in.
        if !groupItems.isEmpty || editing {
            let collapsed = collapsedGroups.contains(group.rawValue)
            VStack(alignment: .leading, spacing: ZoopMetrics.space2) {
                Button { toggleCollapsed(group) } label: {
                    HStack(spacing: ZoopMetrics.space2) {
                        Text(group.title.uppercased())
                            .font(StrandFont.overline)
                            .tracking(1.2)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Text("\(groupItems.count)")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Rectangle()
                            .fill(StrandPalette.hairline)
                            .frame(height: ZoopMetrics.hairlineWidth)
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.title), \(groupItems.count) items, \(collapsed ? "collapsed" : "expanded")")

                if !collapsed && !groupItems.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(groupItems.enumerated()), id: \.element.id) { index, item in
                            itemRow(item)
                            if index < groupItems.count - 1 {
                                Rectangle()
                                    .fill(StrandPalette.hairline)
                                    .frame(height: ZoopMetrics.hairlineWidth)
                            }
                        }
                    }
                    .padding(.horizontal, ZoopMetrics.cardPadding)
                    .background(RoundedRectangle(cornerRadius: Self.sectionRadius, style: .continuous)
                        .fill(StrandPalette.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: Self.sectionRadius, style: .continuous)
                        .stroke(StrandPalette.hairline, lineWidth: ZoopMetrics.hairlineWidth))
                }
            }
        }
    }

    // MARK: - Item row

    /// The label a row shows: a user rename verbatim, otherwise the canonical question looked up in
    /// the string catalog so the starter questions translate. The stored key is never touched.
    private func label(for item: JournalCatalogItem) -> String {
        if let renamed = item.displayName { return renamed }
        return String(localized: String.LocalizationValue(item.canonical))
    }

    @ViewBuilder private func itemRow(_ item: JournalCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: ZoopMetrics.space3) {
                Text(verbatim: label(for: item))
                    .font(StrandFont.body)
                    .foregroundStyle(item.hidden ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: ZoopMetrics.space2)
                if editing {
                    editControls(item)
                } else if item.kind.isNumeric {
                    numericDecision(item)
                } else {
                    boolDecision(item)
                }
            }
            .padding(.vertical, ZoopMetrics.space3)

            if !editing, item.kind.isNumeric, numericYesSelected(item) {
                amountRow(item)
                    .padding(.bottom, ZoopMetrics.space3)
            }
        }
    }

    // MARK: - X / ✓ answers

    private func boolDecision(_ item: JournalCatalogItem) -> some View {
        let q = item.canonical
        let answer = answers[q]
        return HStack(spacing: ZoopMetrics.space2) {
            decisionButton(yes: false, selected: answer == false, itemLabel: label(for: item)) {
                writeBool(q, value: false, selected: answer == false)
            }
            decisionButton(yes: true, selected: answer == true, itemLabel: label(for: item)) {
                writeBool(q, value: true, selected: answer == true)
            }
        }
    }

    private func writeBool(_ q: String, value: Bool, selected: Bool) {
        Task {
            // Tri-state: re-tapping the filled answer clears it (natural-key delete, scoped to
            // "noop-journal", imported rows can never be removed this way).
            if selected {
                await repo.clearJournalAnswer(day: dayKey, question: q)
            } else {
                await repo.saveJournalAnswer(day: dayKey, question: q, answeredYes: value)
            }
            onChanged()
        }
    }

    /// ✓ is "on" for a numeric item when a positive amount is stored, or the user just opened the amount
    /// row and has not set a value yet.
    private func numericYesSelected(_ item: JournalCatalogItem) -> Bool {
        if let v = numericAnswers[item.canonical] { return v > 0 }
        return pendingNumericYes.contains(item.canonical)
    }

    private func numericDecision(_ item: JournalCatalogItem) -> some View {
        let q = item.canonical
        let current = numericAnswers[q]
        let noSelected = current == 0
        let yesSelected = numericYesSelected(item)
        return HStack(spacing: ZoopMetrics.space2) {
            decisionButton(yes: false, selected: noSelected, itemLabel: label(for: item)) {
                pendingNumericYes.remove(q)
                if noSelected {
                    clearNumeric(q)
                } else {
                    commitNumeric(q, value: 0)   // an explicit "none" is a stored zero
                }
            }
            decisionButton(yes: true, selected: yesSelected, itemLabel: label(for: item)) {
                if yesSelected {
                    pendingNumericYes.remove(q)
                    if current != nil { clearNumeric(q) }
                } else {
                    // Open the amount row; nothing is written until an amount is chosen. A stored zero
                    // is cleared so X and ✓ can never both read as selected.
                    pendingNumericYes.insert(q)
                    if current != nil { clearNumeric(q) }
                }
            }
        }
    }

    /// One WHOOP-style square answer button. Selected ✓ fills with the accent, selected X with the
    /// primary text colour; unselected is an inset square with a hairline edge.
    private func decisionButton(yes: Bool, selected: Bool, itemLabel: String,
                                action: @escaping () -> Void) -> some View {
        let fill = yes ? StrandPalette.accent : StrandPalette.textPrimary
        let shape = RoundedRectangle(cornerRadius: Self.decisionRadius, style: .continuous)
        return Button(action: action) {
            Image(systemName: yes ? "checkmark" : "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                .frame(width: Self.decisionSize, height: Self.decisionSize)
                .background(shape.fill(selected ? fill : StrandPalette.surfaceInset))
                .overlay(shape.stroke(selected ? fill : StrandPalette.hairlineStrong,
                                      lineWidth: ZoopMetrics.hairlineWidth))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(yes ? "Yes" : "No"))
        .accessibilityValue(Text(verbatim: itemLabel))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Amount row (numeric items, shown once ✓ is chosen)

    private func amountRow(_ item: JournalCatalogItem) -> some View {
        let current = numericAnswers[item.canonical]
        return HStack(spacing: ZoopMetrics.space2) {
            Text("How much?")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: ZoopMetrics.space2)
            stepperButton("minus", q: item.canonical, current: current)
            NumericLogField(
                value: current,
                placeholder: "—",
                onCommit: { v in commitNumeric(item.canonical, value: v) })
            .frame(width: ZoopMetrics.formWideValueColumnWidth)
            if let unit = item.kind.unitLabel, !unit.isEmpty {
                Text(verbatim: unit)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            stepperButton("plus", q: item.canonical, current: current)
        }
        .padding(.horizontal, ZoopMetrics.space3)
        .padding(.vertical, ZoopMetrics.space2)
        .background(RoundedRectangle(cornerRadius: Self.decisionRadius + 2, style: .continuous)
            .fill(StrandPalette.surfaceInset))
    }

    private func stepperButton(_ symbol: String, q: String, current: Double?) -> some View {
        Button {
            let base = current ?? 0
            let next = max(0, symbol == "plus" ? base + 1 : base - 1)
            commitNumeric(q, value: next)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(StrandPalette.surfaceRaised))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "plus" ? "Increase" : "Decrease")
    }

    private func commitNumeric(_ q: String, value: Double) {
        Task {
            await repo.saveJournalNumeric(day: dayKey, question: q, value: value)
            onChanged()
        }
    }

    private func clearNumeric(_ q: String) {
        Task {
            await repo.clearJournalAnswer(day: dayKey, question: q)
            onChanged()
        }
    }

    // MARK: - Edit-mode controls

    private func editControls(_ item: JournalCatalogItem) -> some View {
        HStack(spacing: 10) {
            if item.hidden {
                pillButton("Restore", selected: false) { catalog.restore(item.canonical) }
            } else {
                Menu {
                    Button("Rename…") { startRename(item) }
                    Menu("Group") {
                        ForEach(JournalGroup.displayOrder, id: \.self) { g in
                            Button(g.title) { catalog.setGroup(item.canonical, to: g) }
                        }
                    }
                    if item.kind.isNumeric {
                        Button("Change to Yes/No") { catalog.setKind(item.canonical, to: .bool) }
                    } else {
                        Button("Change to Number") { catalog.setKind(item.canonical, to: .numeric(unitLabel: nil)) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Edit \(label(for: item))")

                removeButton(item)
            }
        }
    }

    /// Edit-mode control: delete a custom question / hide a built-in one. Tinted red to read as removal.
    private func removeButton(_ item: JournalCatalogItem) -> some View {
        Button { catalog.remove(item.canonical) } label: {
            Image(systemName: "minus.circle.fill")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.statusCritical)
        }
        .buttonStyle(.plain)
        .help(item.custom ? "Delete this custom item" : "Hide this item")
        .accessibilityLabel(item.custom ? "Delete \(label(for: item))" : "Hide \(label(for: item))")
    }

    // MARK: - Rename sheet

    private func startRename(_ item: JournalCatalogItem) {
        renameDraft = item.displayName ?? item.canonical
        renaming = item
    }

    private func renameSheet(_ item: JournalCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
            Text("Rename item").font(StrandFont.headline)
            TextField("Display name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
            Text("History stays under the original question so WHOOP imports still line up.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { renaming = nil }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    catalog.rename(item.canonical, to: renameDraft)
                    renaming = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(ZoopMetrics.space4)
        .frame(minWidth: 320)
    }

    // MARK: - Add section

    private var addSection: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.space2) {
            HStack(spacing: ZoopMetrics.space2) {
                Text(String(localized: "Custom item").uppercased())
                    .font(StrandFont.overline)
                    .tracking(1.2)
                    .foregroundStyle(StrandPalette.textSecondary)
                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: ZoopMetrics.hairlineWidth)
            }
            VStack(alignment: .leading, spacing: ZoopMetrics.space2) {
                HStack(spacing: ZoopMetrics.space2) {
                    TextField("Add a custom item…", text: $customDraft)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .padding(.horizontal, ZoopMetrics.space3)
                        .frame(height: Self.decisionSize)
                        .background(RoundedRectangle(cornerRadius: Self.decisionRadius, style: .continuous)
                            .fill(StrandPalette.surfaceInset))
                    pillButton(customIsNumeric ? "Number" : "Yes/No", selected: customIsNumeric) {
                        customIsNumeric.toggle()
                    }
                }
                HStack(spacing: ZoopMetrics.space2) {
                    Picker("Group", selection: $customGroup) {
                        ForEach(JournalGroup.displayOrder, id: \.self) { g in
                            Text(g.title).tag(g)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(StrandPalette.textSecondary)
                    .accessibilityLabel("New item group")
                    Spacer()
                    pillButton("Add", selected: !customDraft.trimmingCharacters(in: .whitespaces).isEmpty) {
                        let t = customDraft.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        catalog.addCustom(t,
                                          kind: customIsNumeric ? .numeric(unitLabel: nil) : .bool,
                                          group: customGroup)
                        customDraft = ""
                    }
                    .disabled(customDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(ZoopMetrics.space3)
            .background(RoundedRectangle(cornerRadius: Self.sectionRadius, style: .continuous)
                .fill(StrandPalette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Self.sectionRadius, style: .continuous)
                .stroke(StrandPalette.hairline, lineWidth: ZoopMetrics.hairlineWidth))
        }
    }

    // MARK: - Controls

    /// The bounded day range (#656): Tomorrow (-1) back through 6 days ago.
    private static let newestOffset = -1
    private static let oldestOffset = 6

    /// Relative caption for a day offset (daysBack; -1 = Tomorrow). "%lld days ago" is a String
    /// Catalog key, so 2–6 stay localized just like the twin "%lld nights ago" (#527/#656).
    private func journalDayLabel(_ offset: Int) -> LocalizedStringKey {
        switch offset {
        case -1: return "Tomorrow"
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(offset) days ago"
        }
    }

    private func pillButton(_ label: LocalizedStringKey, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                .padding(.horizontal, ZoopMetrics.space3)
                .frame(height: 30)
                .background(selected ? StrandPalette.textPrimary : StrandPalette.surfaceInset,
                            in: Capsule())
                .overlay(Capsule().stroke(selected ? StrandPalette.textPrimary : StrandPalette.hairline,
                                          lineWidth: ZoopMetrics.hairlineWidth))
        }
        .buttonStyle(.plain)
    }
}

/// A compact numeric log field: shows the current value or a ghost placeholder, commits a Double on
/// return or when focus leaves the field (the iOS decimal pad has no return key).
private struct NumericLogField: View {
    let value: Double?
    let placeholder: String
    let onCommit: (Double) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(StrandFont.number(15))
            .foregroundStyle(StrandPalette.textPrimary)
            .focused($focused)
            .onAppear { text = value.map(Self.format) ?? "" }
            .onChangeCompat(of: value) { v in text = v.map(Self.format) ?? "" }
            .onChangeCompat(of: focused) { isFocused in if !isFocused { commit() } }
            .onSubmit { commit() }
        #if os(iOS)
            .keyboardType(.decimalPad)
        #endif
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
        guard let v = Double(cleaned), v != value else { return }
        onCommit(v)
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
