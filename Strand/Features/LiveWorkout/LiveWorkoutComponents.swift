import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Live workout building blocks
//
// The large primary field, the grid tile, the split list and the location note. Each takes a resolved
// `LiveFieldReading` (or the readings) and only lays it out.

/// The one large number at the top of the screen.
struct LiveWorkoutPrimary: View {
    let field: LiveWorkoutField
    let reading: LiveFieldReading

    var body: some View {
        VStack(spacing: ZoopSpacing.xs) {
            Text(field.title)
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textSecondary)
            if let value = reading.value {
                HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.xs) {
                    Text(verbatim: value)
                        .font(ZoopType.display)
                        .monospacedDigit()
                        .foregroundStyle(reading.tint ?? StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if let unit = reading.unit {
                        Text(verbatim: unit).font(ZoopType.headline).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            } else if let reason = reading.reason {
                Text(reason).font(ZoopType.metric).foregroundStyle(StrandPalette.textTertiary)
            }
            if let caption = reading.caption {
                Text(caption).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ZoopSpacing.m)
        .accessibilityElement(children: .combine)
    }
}

/// One grid cell: label, value with unit (or the reason there is none), optional caption.
struct LiveWorkoutTile: View {
    let field: LiveWorkoutField
    let reading: LiveFieldReading

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Label {
                Text(field.title).lineLimit(1).minimumScaleFactor(0.8)
            } icon: {
                Image(systemName: field.systemImage).accessibilityHidden(true)
            }
            .font(ZoopType.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            if let value = reading.value {
                HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.xs) {
                    Text(verbatim: value)
                        .font(ZoopType.metric)
                        .monospacedDigit()
                        .foregroundStyle(reading.tint ?? StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let unit = reading.unit {
                        Text(verbatim: unit).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            } else if let reason = reading.reason {
                Text(reason)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            if let caption = reading.caption {
                Text(caption).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .zoopTileSurface()
        .accessibilityElement(children: .combine)
    }
}

/// Completed splits, newest first, then the split in progress, each with a bar against the slowest one.
struct LiveWorkoutSplitList: View {
    let readings: LiveWorkoutReadings

    var body: some View {
        let splits = readings.splits
        ContentCard(LocalizedStringKey(LiveWorkoutStrings.fieldSplits)) {
            if let current = readings.currentSplit, current.meters > 0 || !splits.isEmpty {
                row(title: readings.splitTitle(splits.count + 1), detail: LiveWorkoutStrings.splitInProgress,
                    value: ZoopNumber.decimal(current.meters / readings.unitMeters, digits: 2)
                        + " " + UnitFormatter.distanceUnit(readings.distanceSystem),
                    fraction: nil)
            }
            if splits.isEmpty {
                Text(readings.distanceSystem == .imperial ? LiveWorkoutStrings.firstSplitMile : LiveWorkoutStrings.firstSplitKm)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                let slowest = splits.map(\.seconds).max() ?? 1
                ForEach(splits.reversed()) { split in
                    row(title: readings.splitTitle(split.index), detail: nil,
                        value: readings.paceText(split.seconds), fraction: split.seconds / max(slowest, 1))
                }
            }
        }
    }

    private func row(title: String, detail: String?, value: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
                if let detail {
                    Text(detail).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: ZoopSpacing.s)
                Text(verbatim: value).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
            }
            if let fraction {
                GeometryReader { geo in
                    Capsule().fill(StrandPalette.surfaceInset)
                        .overlay(alignment: .leading) {
                            Capsule().fill(StrandPalette.effortColor)
                                .frame(width: geo.size.width * CGFloat(min(max(fraction, 0.05), 1)))
                        }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Why a GPS sport shows no distance: permission off, not decided yet, or no GPS hardware.
struct LiveWorkoutGPSNote: View {
    let state: LiveGPSState

    var body: some View {
        switch state {
        case .denied:
            ContentCard(LocalizedStringKey(LiveWorkoutStrings.gpsDeniedTitle)) {
                Text(LiveWorkoutStrings.gpsDeniedMessage)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                #if os(iOS)
                ZoopButton(LocalizedStringKey(LiveWorkoutStrings.openSettings), systemImage: "location", kind: .secondary) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                #endif
            }
        case .unavailable:
            note(LiveWorkoutStrings.gpsUnavailable)
        case .askPending:
            note(LiveWorkoutStrings.gpsAsk)
        case .off, .waiting, .live:
            EmptyView()
        }
    }

    private func note(_ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "location.slash") }
            .font(ZoopType.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Transient line after a completed split: "Kilometre 3 · 5:12 /km".
struct LiveWorkoutSplitBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "flag.checkered")
            .font(ZoopType.headline)
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, ZoopSpacing.l)
            .padding(.vertical, ZoopSpacing.m)
            .background(Capsule().fill(StrandPalette.surfaceOverlay))
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Speed / cadence / power from a connected fitness sensor. Owns its own `LiveState` observation so a
/// sensor packet redraws only this row; renders nothing for an HR-only workout.
struct LiveWorkoutSensorRow: View {
    @EnvironmentObject private var live: LiveState
    let distanceSystem: UnitSystem

    var body: some View {
        if live.hasSensorMetrics {
            let speed = UnitFormatter.speedFromKilometersPerHour(live.sensorSpeedKmh, system: distanceSystem)
            let cadence = LiveState.formatCadence(live.sensorCadence)
            let power = LiveState.formatPowerWatts(live.sensorPowerWatts)
            TileGrid {
                if let speed { tile("zoop.workout.live.sensor.speed", "speedometer", speed) }
                if let cadence { tile("zoop.workout.live.sensor.cadence", "metronome", "\(cadence)/min") }
                if let power { tile("zoop.workout.live.sensor.power", "bolt", "\(power) W") }
            }
        }
    }

    private func tile(_ title: LocalizedStringKey, _ icon: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Label(title, systemImage: icon).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(verbatim: value).font(ZoopType.metric).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoopTileSurface()
    }
}
