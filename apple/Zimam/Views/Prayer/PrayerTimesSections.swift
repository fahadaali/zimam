import SwiftUI
import ZimamKit

// The sections of «أوقات الصلاة» (`PrayerTimesView`) under the clock and today's times.

/// «الموقع»: the place the times are computed for, and the ways to change it.
struct PrayerLocationSection: View {
    @Environment(LocationProvider.self) private var location

    let onPickPlace: () -> Void

    var body: some View {
        Section {
            if location.coordinate != nil {
                LabeledContent("المكان") {
                    Text(location.placeName ?? (location.isManual ? "مكان على الخريطة" : "موقعي الحالي"))
                        .foregroundStyle(ZimamColor.ink)
                }
                .frame(minHeight: ZimamSpacing.space11)
            }
            LocationRequestRows()
            Button("اختيار من الخريطة", systemImage: "map", action: onPickPlace)
                .frame(minHeight: ZimamSpacing.space11)
        } header: {
            Text("الموقع")
        } footer: {
            Text(location.isManual
                 ? "تُحسب الأوقات للمكان الذي اخترته على الخريطة، ولا يغيّرها تنقّلك. اختر «استعمال موقعي الحالي» لتعود إلى موقعك."
                 : "تُحسب الأوقات لموقعك على مستوى المدينة. اختر مكاناً من الخريطة إن أردت مدينة أخرى.")
        }
    }
}

/// «الحساب»: the calculation method and the Asr time, saved through the bindings.
struct PrayerCalculationSection: View {
    @Environment(SessionStore.self) private var session

    @Binding var method: PrayerMethod
    @Binding var madhab: AsrMadhab
    let saveFailed: Bool

    var body: some View {
        Section {
            Picker("طريقة الحساب", selection: $method) {
                ForEach(PrayerMethod.allCases, id: \.self) { method in
                    Text(method.arabicName).tag(method)
                }
            }
            Picker("وقت العصر", selection: $madhab) {
                ForEach(AsrMadhab.allCases, id: \.self) { madhab in
                    Text(madhab.arabicName).tag(madhab)
                }
            }
        } header: {
            Text("الحساب")
        } footer: {
            if saveFailed {
                Text("تعذّر حفظ الإعدادات. تحقّق من الاتصال وحاول مرة أخرى.")
                    .foregroundStyle(ZimamColor.priorityHigh)
            } else {
                Text("الجمهور: العصر حين يصير ظل الشيء مثله. الحنفي: حين يصير مثليه.")
            }
        }
        .disabled(session.user == nil)
    }
}

/// «التنبيهات» while alerts are off: the way to turn them on.
struct PrayerAlertsStatusSection: View {
    @Environment(NotificationScheduler.self) private var notifications

    var body: some View {
        if !notifications.isEnabled {
            Section {
                if notifications.canAskForAlerts {
                    Button("تفعيل التنبيهات", systemImage: "bell", action: requestAlerts)
                        .frame(minHeight: ZimamSpacing.space11)
                } else {
                    Text("التنبيهات متوقفة. فعّلها لزمام من إعدادات النظام.")
                        .foregroundStyle(ZimamColor.inkMuted)
                }
            } header: {
                Text("التنبيهات")
            }
        }
    }

    private func requestAlerts() {
        Task { await notifications.requestFullAuthorization() }
    }
}

/// «تنبيه العصر»: one prayer's adhan and iqama alerts, and the wait before the iqama.
struct PrayerAlertSection: View {
    @Environment(SessionStore.self) private var session

    let prayer: Prayer
    @Binding var alert: PrayerAlert

    var body: some View {
        Section {
            Toggle("الأذان", isOn: $alert.adhan)
                .frame(minHeight: ZimamSpacing.space11)
            Toggle("الإقامة", isOn: $alert.iqama)
                .frame(minHeight: ZimamSpacing.space11)
            if alert.iqama {
                Stepper(value: $alert.iqamaMinutes, in: PrayerAlert.iqamaRange, step: 5) {
                    Text("بعد الأذان بـ\(ArabicCount.minutes(alert.iqamaMinutes, locale: ZimamLocale.current))")
                }
                .frame(minHeight: ZimamSpacing.space11)
            }
        } header: {
            Text("تنبيه \(prayer.arabicName)")
        }
        .disabled(session.user == nil)
    }
}

extension ArabicCount {
    /// «٥ دقائق»، «١٠ دقائق»، «١٥ دقيقة»: the iqama wait (`PrayerAlert.iqamaRange`, 5...60), after «بـ».
    /// One and two are left out: after «بـ» they would read «بدقيقة» and «بدقيقتين».
    static func minutes(_ count: Int, locale: Locale) -> String {
        let number = count.formatted(.number.locale(locale).grouping(.never))
        switch count % 100 {
        case 3...10: return "\(number) دقائق"
        default: return "\(number) دقيقة"
        }
    }
}

/// Prayer times in Claude and ChatGPT: shares the city-level place with the server when on. The
/// switch is the account's (a location in its settings), so every device and the web agree, and
/// the place follows the device in use.
struct PrayerShareSection: View {
    @Environment(SessionStore.self) private var session
    @Environment(LocationProvider.self) private var location
    /// What the switch was just set to, until the account says so (or the save failed).
    @State private var pending: Bool?

    init() {}

    private var isSharing: Bool { pending ?? session.sharesPlace }

    private var isOn: Binding<Bool> {
        Binding(get: { isSharing }, set: { share($0) })
    }

    /// Turning it on needs this device's place.
    private var canTurnOn: Bool { location.coordinate != nil }

    var body: some View {
        Section {
            Toggle("أوقات الصلاة في كلود وChatGPT", isOn: isOn)
                .frame(minHeight: ZimamSpacing.space11)
                .disabled(session.user == nil || (!isSharing && !canTurnOn))
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        if isSharing {
            return "تُحسب الأوقات على جهازك، ويُحفظ في خادم زمام موقع تقريبي على مستوى المدينة لتظهر الأوقات في جدولك عند كلود وChatGPT. يسري الاختيار على حسابك في كل أجهزتك."
        }
        if !canTurnOn {
            return "تُحسب الأوقات على جهازك، ولا يُرسل موقعك إلى أي خادم. حدّد موقعك أولاً لتفعيله."
        }
        return "تُحسب الأوقات على جهازك، ولا يُرسل موقعك إلى أي خادم."
    }

    private func share(_ on: Bool) {
        pending = on
        Task {
            await session.sharePlace(latitude: location.coordinate?.latitude,
                                     longitude: location.coordinate?.longitude, share: on)
            pending = nil
        }
    }
}
