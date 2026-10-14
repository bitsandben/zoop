import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// A small sheet to hand-correct a night's bed (onset) and wake (end) instants. Seeds both pickers with
/// the current values, including each calendar date. Hands the chosen unix-second (bed, wake) back via
/// `onSave`. Pure presentation + a single async save — persistence lives in the repo.
struct SleepTimeEditor: View {
    let onSave: (Int, Int) async -> Void
    /// Optional destructive delete. Non-nil for an existing main-sleep / nap edit (the editor then
    /// shows a "Delete this sleep" button gated behind a confirmation); nil for the "Add a nap" sheet,
    /// which has nothing to delete yet.
    let onDelete: (() async -> Void)?
    private let title: LocalizedStringKey
    private let blurb: LocalizedStringKey
    private let bedLabel: LocalizedStringKey
    private let wakeLabel: LocalizedStringKey
    private let deleteLabel: LocalizedStringKey
    /// The night's RECORDED coverage (detected onset ... current wake, unix seconds) for the
    /// guards: a time-only bed roll past the wake auto-decrements the date, and a corrected window
    /// fully outside this range gets an explicit confirm instead of silent acceptance. nil for the
    /// "Add a nap" sheet, whose window deliberately sits outside the night (only the future-bed
    /// guard applies there).
    private let coverage: ClosedRange<Int>?
    /// True when deleting THIS session writes a re-detection tombstone (a DETECTED night). false for a
    /// userEdited/nap row, which is never re-detected, so the delete-confirm copy drops the suppression
    /// promise for it, matching the undo banner.
    private let suppressesReDetection: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var bed: Date
    @State private var wake: Date
    @State private var saving = false
    @State private var confirmingDelete = false
    /// The bed value BEFORE the in-flight picker change, so the auto-correct can tell a
    /// time-only roll (same calendar day: rescue it) from a deliberate date change (respect it).
    @State private var previousBed: Date
    /// True while the "no recorded data there" confirm is up; Save proceeds only on consent.
    @State private var confirmingDisjoint = false

    /// `title`/`blurb`/`bedLabel`/`wakeLabel` default to the edit-an-existing-night wording; the
    /// "Add a nap" caller overrides them. The save logic is identical either way — adding a nap
    /// is just an edit whose "existing" window is a seed. `onDelete` is the optional destructive
    /// action; `deleteLabel` lets the nap editor say "Delete this nap".
    init(bedTs: Int, wakeTs: Int,
         title: LocalizedStringKey = "Edit sleep times",
         blurb: LocalizedStringKey = "Stages are recalculated from your data.",
         bedLabel: LocalizedStringKey = "Asleep",
         wakeLabel: LocalizedStringKey = "Woke",
         deleteLabel: LocalizedStringKey = "Delete this sleep",
         coverage: ClosedRange<Int>? = nil,
         suppressesReDetection: Bool = true,
         onSave: @escaping (Int, Int) async -> Void,
         onDelete: (() async -> Void)? = nil) {
        self.onSave = onSave
        self.onDelete = onDelete
        self.title = title; self.blurb = blurb
        self.bedLabel = bedLabel; self.wakeLabel = wakeLabel
        self.deleteLabel = deleteLabel
        self.coverage = coverage
        self.suppressesReDetection = suppressesReDetection
        // A bed can never be seeded in the future: the "Add a nap" anchor is wake+1h, which is
        // ahead of the clock right after a morning sync; clamp so the picker opens inside its bound.
        let seedBed = min(bedTs, Int(Date().timeIntervalSince1970))
        _bed = State(initialValue: Date(timeIntervalSince1970: TimeInterval(seedBed)))
        _previousBed = State(initialValue: Date(timeIntervalSince1970: TimeInterval(seedBed)))
        _wake = State(initialValue: Date(timeIntervalSince1970: TimeInterval(wakeTs)))
    }

    /// The current edit window after the same future/inverted/duration guards used by persistence.
    private var validatedWindow: (start: Int, end: Int)? {
        SleepEditGuard.clampedEditWindow(
            start: Int(bed.timeIntervalSince1970),
            end: Int(wake.timeIntervalSince1970),
            now: Int(Date().timeIntervalSince1970))
    }

    /// The single save funnel: both the direct Save and the disjoint confirm land here.
    private func commit(start: Int, end: Int) {
        saving = true
        Task {
            await onSave(start, end)
            dismiss()
        }
    }

    /// Which endpoint the iOS wheel is editing.
    private enum Endpoint { case bed, wake }
    @State private var editing: Endpoint = .bed

    /// Save, shared by both layouts: the disjoint check, then the single commit funnel.
    private func attemptSave() {
        guard let window = validatedWindow else { return }
        if let coverage, SleepEditGuard.isDisjoint(
            newStart: window.start, newEnd: window.end,
            coverageStart: coverage.lowerBound, coverageEnd: coverage.upperBound) {
            confirmingDisjoint = true
        } else {
            commit(start: window.start, end: window.end)
        }
    }

    var body: some View {
        #if os(iOS)
        guarded(iosContent)
        #else
        guarded(legacyContent)
        #endif
    }

    #if os(iOS)
    /// Zoop iOS layout: two large endpoint tiles (as on Home), one wheel for the selected endpoint, the
    /// resulting duration, and a full-width save. Sized to its content instead of a mostly empty sheet.
    private var iosContent: some View {
        let canSave = validatedWindow != nil
        return VStack(alignment: .leading, spacing: ZoopMetrics.space4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: ZoopMetrics.space1) {
                    Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    Text(blurb)
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: ZoopMetrics.space3)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(StrandPalette.surfaceInset))
                }
                .buttonStyle(.plain)
                .disabled(saving)
                .accessibilityLabel(Text("Cancel"))
            }
            HStack(spacing: ZoopMetrics.space3) {
                endpointTile(.bed, label: bedLabel, icon: "moon.zzz.fill", date: bed)
                endpointTile(.wake, label: wakeLabel, icon: "sun.max.fill", date: wake)
            }
            Group {
                if editing == .bed {
                    DatePicker("", selection: $bed, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                } else {
                    DatePicker("", selection: $wake, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                }
            }
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .frame(height: 170)
            .clipped()
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(StrandPalette.surfaceInset))

            HStack {
                Text("Duration").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(verbatim: durationLabel)
                    .font(StrandFont.number(17))
                    .foregroundStyle(canSave ? StrandPalette.textPrimary : StrandPalette.statusWarning)
            }

            Button(action: attemptSave) {
                Text(saving ? "Saving…" : "Save")
                    .font(StrandFont.ui(17, weight: .semibold))
                    .foregroundStyle(StrandPalette.primaryButtonText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(SquircleShape().fill(StrandPalette.primaryButtonFill))
            }
            .buttonStyle(.plain)
            .disabled(saving || !canSave)
            .opacity(canSave ? 1 : 0.5)

            if onDelete != nil {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label(deleteLabel, systemImage: "trash")
                        .font(StrandFont.ui(16, weight: .semibold))
                        .foregroundStyle(StrandPalette.statusCritical)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(SquircleShape().fill(StrandPalette.statusCritical.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(saving)
            }
        }
        .padding(.horizontal, ZoopMetrics.screenPadding)
        .padding(.top, ZoopMetrics.space6)
        .padding(.bottom, ZoopMetrics.space4)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(onDelete == nil ? 560 : 620), .large])
        .presentationDragIndicator(.visible)
        .opaqueSheetBackground()
    }

    private func endpointTile(_ which: Endpoint, label: LocalizedStringKey, icon: String, date: Date) -> some View {
        let selected = editing == which
        return Button { withAnimation(.snappy) { editing = which } } label: {
            VStack(alignment: .leading, spacing: ZoopMetrics.space1) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                    Text(label).font(StrandFont.subhead)
                }
                .foregroundStyle(StrandPalette.textSecondary)
                Text(date, format: .dateTime.hour().minute())
                    .font(StrandFont.display(30))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ZoopMetrics.space3)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(selected ? StrandPalette.restColor.opacity(0.18) : StrandPalette.surfaceInset))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? StrandPalette.restColor : StrandPalette.hairline, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "7 h 28 min" for the current window, or a short warning when the window is invalid.
    private var durationLabel: String {
        guard let w = validatedWindow else { return String(localized: "Check the times") }
        let m = (w.end - w.start) / 60
        return String(localized: "\(m / 60) h \(m % 60) min")
    }
    #endif

    private var legacyContent: some View {
        let canSave = validatedWindow != nil

        return VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
            Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(blurb)
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ZoopCard(padding: ZoopMetrics.cardPadding, tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: 10) {
                    // Bed is bounded to the PAST: a sleep can't start in the future, and an
                    // unbounded picker let a cross-midnight time roll land the bed on the coming
                    // evening, creating a future-dated night the tab couldn't render.
                    DatePicker(bedLabel, selection: $bed, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                        .font(StrandFont.body)
                        .tint(StrandPalette.restColor)
                    Divider().overlay(StrandPalette.hairline)
                    // The wake date and time are both editable so corrections preserve the exact
                    // endpoint selected by the user.
                    DatePicker(wakeLabel, selection: $wake, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                        .font(StrandFont.body)
                        .tint(StrandPalette.restColor)
                }
            }

            // Destructive delete for an existing night/nap. Confirmation-gated so a tap can't clear
            // a night by accident; nil for the "Add a nap" sheet (nothing to delete). Sits below the
            // pickers, visually separated from the primary Save action.
            if onDelete != nil {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label(deleteLabel, systemImage: "trash")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.statusCritical)
                }
                .buttonStyle(.plain)
                .disabled(saving)
                .accessibilityLabel(deleteLabel)
            }

            HStack(spacing: ZoopMetrics.gap) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.noopGhost)
                    .disabled(saving)
                Spacer()
                Button(saving ? "Saving…" : "Save") {
                    // guard 2: a corrected window that no longer touches the night's recorded
                    // coverage has no data to stage from. Silently accepting it fabricated an
                    // all-awake phantom night; ask first.
                    guard let window = validatedWindow else { return }
                    if let coverage, SleepEditGuard.isDisjoint(
                        newStart: window.start, newEnd: window.end,
                        coverageStart: coverage.lowerBound, coverageEnd: coverage.upperBound) {
                        confirmingDisjoint = true
                    } else {
                        commit(start: window.start, end: window.end)
                    }
                }
                .buttonStyle(.noopPrimary)
                .disabled(saving || !canSave)
                .opacity(canSave ? 1 : 0.55)
            }
        }
        .padding(ZoopMetrics.screenPadding)
        .frame(minWidth: 360)
        .background(ZoopChromeSurface())
    }

    /// The bed auto-correct and the two confirms, shared by both layouts.
    private func guarded<V: View>(_ content: V) -> some View {
        content
        // guard 1: a time-only roll that lands the bed in the future, or at/after the night's
        // wake, almost always means the PREVIOUS evening (23:00 "yesterday", not tonight). Snap the
        // date back a day so the picker visibly shows the night the user meant. Pure rule + tests:
        // SleepEditGuard.autoCorrectedBed.
        .onChangeCompat(of: bed) { newBed in
            let corrected = SleepEditGuard.autoCorrectedBed(
                previousBed: previousBed, candidateBed: newBed,
                originalWake: coverage.map { Date(timeIntervalSince1970: TimeInterval($0.upperBound)) },
                now: Date())
            previousBed = corrected
            if corrected != newBed { bed = corrected }
        }
        // guard 2's consent step. On-brand role-tagged .alert, same shape as the delete confirm.
        .alert("Move this sleep?", isPresented: $confirmingDisjoint) {
            Button("Cancel", role: .cancel) { }
            Button("Move anyway") {
                guard let window = SleepEditGuard.clampedEditWindow(
                    start: Int(bed.timeIntervalSince1970),
                    end: Int(wake.timeIntervalSince1970),
                    now: Int(Date().timeIntervalSince1970)) else { return }
                commit(start: window.start, end: window.end)
            }
        } message: {
            Text("This moves the night to a time with no recorded data. Stages can't be derived there, so it may show as empty until data covers it.")
        }
        // On-brand destructive confirm — the same role-tagged .alert DevicesView uses for "Remove this
        // device?", not a bare default.
        .alert("Delete this sleep session?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                saving = true
                Task {
                    await onDelete?()
                    dismiss()
                }
            }
        } message: {
            // A detected night is tombstoned so it won't re-detect; a userEdited/nap row writes no
            // tombstone, so its copy drops that (false) promise. Mirrors the undo banner.
            Text(suppressesReDetection
                 ? "Removes this recorded sleep and recomputes the day without it. Zoop won't re-detect sleep in this window. You can undo for a few seconds after."
                 : "Removes this sleep and recomputes the day without it. You can undo for a few seconds after.")
        }
    }
}
