import SwiftUI
import ZimamKit

// MARK: The clock

/// The next prayer and the time left, or for half an hour after an adhan the time since it.
/// The system counts the seconds (`Text(_:style: .timer)`); the state is recomputed every half
/// minute, so it moves on at the adhan and half an hour after it.
struct PrayerClockCard: View {
    let schedule: PrayerSchedule

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let state = PrayerClock(schedule: schedule).state(at: context.date) {
                content(state)
            }
        }
    }

    private func content(_ state: PrayerClock.State) -> some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            switch state {
            case .since(let prayer, _):
                Text("مضى على أذان \(prayer.arabicName)")
                    .font(ZimamType.callout)
            case .until(let prayer, _):
                Text("المتبقي على \(prayer.arabicName)")
                    .font(ZimamType.callout)
            }
            Text(state.time, style: .timer)
                .font(ZimamType.display)
                .monospacedDigit()
            Text("\(state.prayer.arabicName)، \(formatter.time(state.time))")
                .font(ZimamType.callout)
        }
        .foregroundStyle(ZimamColor.sand)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZimamSpacing.space4)
        .background(ZimamColor.sandSoft, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Today's times

/// Today's five prayer times and sunrise, in the sand colour reserved for prayer times, under the
/// dual date. The next prayer is marked.
struct PrayerTimesList: View {
    let schedule: PrayerSchedule

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let times = schedule.times(on: now)
            let next = schedule.next(after: now)
            VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
                Text(formatter.dual(now))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
                ForEach(Prayer.allCases, id: \.self) { prayer in
                    if let time = times[prayer] {
                        PrayerTimeRow(name: prayer.arabicName, systemImage: "moon.stars", time: formatter.time(time),
                                      isNext: next?.prayer == prayer && next?.time == time)
                    }
                    if prayer == .fajr, let sunrise = schedule.sunrise(on: now) {
                        PrayerTimeRow(name: "الشروق", systemImage: "sunrise", time: formatter.time(sunrise), isNext: false)
                    }
                }
            }
            .padding(.vertical, ZimamSpacing.space1)
        }
    }
}

struct PrayerTimeRow: View {
    let name: String
    let systemImage: String
    let time: String
    let isNext: Bool

    var body: some View {
        HStack(spacing: ZimamSpacing.space2) {
            Label(name, systemImage: systemImage)
            Spacer(minLength: ZimamSpacing.space2)
            if isNext {
                Text("القادمة")
                    .font(ZimamType.caption)
            }
            Text(time)
        }
        .font(isNext ? ZimamType.headline : ZimamType.callout)
        .foregroundStyle(ZimamColor.sand)
        .padding(.horizontal, ZimamSpacing.space3)
        .frame(minHeight: ZimamSpacing.space11)
        .background(ZimamColor.sandSoft, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
        .overlay {
            if isNext {
                RoundedRectangle(cornerRadius: ZimamRadius.radiusMd)
                    .stroke(ZimamColor.sand, lineWidth: ZimamLayout.focusRingWidth)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
