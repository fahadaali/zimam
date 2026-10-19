import AVFoundation
import Foundation
import Observation
import Speech

/// «إملاء» in the add screen: Arabic speech (ar-SA) to text with the Speech framework, on the
/// device when it supports it, otherwise through Apple's recognition service. The words appear
/// as they are recognised (`transcript`); listening stops when the user taps again, after two
/// seconds of silence, or after a minute, and `onFinish` gets the final text. No audio is kept.
@MainActor
@Observable
final class SpeechDictation {
    enum Phase: Equatable {
        case idle
        /// Asking for permission or starting the microphone.
        case starting
        case listening
        /// One Arabic sentence; the field keeps whatever was typed.
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    /// Called once with the final text when listening ends with words.
    @ObservationIgnored var onFinish: (@MainActor (String) -> Void)?

    /// Made at the first dictation, not with this object: the add screen's state makes a new
    /// `SpeechDictation` each time its parent redraws, and only the kept one is ever used.
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var silence: Task<Void, Never>?
    @ObservationIgnored private var limit: Task<Void, Never>?
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var stopping = false
    /// Which listening session is current; a cancelled or finished one's late callbacks are ignored.
    @ObservationIgnored private var generation = 0

    var isActive: Bool { phase == .starting || phase == .listening }

    /// Starts listening, or stops if already listening. Ignored while permission is asked.
    func toggle() {
        switch phase {
        case .listening: stop()
        case .starting: break
        case .idle, .failed: Task { await start() }
        }
    }

    func start() async {
        guard !isActive else { return }
        phase = .starting
        transcript = ""
        finished = false
        stopping = false
        generation += 1
        let current = generation
        let speechAllowed = await Self.speechAuthorized()
        // Closed while the permission was asked.
        guard current == generation else { return }
        guard speechAllowed else {
            phase = .failed("الإملاء يحتاج إذن التعرّف على الكلام. فعّله لزمام من الإعدادات، أو اكتب المهمة.")
            return
        }
        let microphoneAllowed = await Self.microphoneAuthorized()
        guard current == generation else { return }
        guard microphoneAllowed else {
            phase = .failed("الإملاء يحتاج إذن الميكروفون. فعّله لزمام من الإعدادات، أو اكتب المهمة.")
            return
        }
        if recognizer == nil { recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ar-SA")) }
        guard let recognizer, recognizer.isAvailable else {
            phase = .failed("الإملاء بالعربية غير متاح الآن على هذا الجهاز. اكتب المهمة.")
            return
        }
        do {
            try begin(with: recognizer)
            phase = .listening
            restartSilenceTimer()
            limit = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            tearDown()
            phase = .failed("تعذّر تشغيل الميكروفون. حاول مرة أخرى، أو اكتب المهمة.")
        }
    }

    /// Stops listening; the recogniser then sends its final text.
    func stop() {
        guard phase == .listening, !stopping else { return }
        stopping = true
        silence?.cancel()
        limit?.cancel()
        request?.endAudio()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        // The final result usually follows at once; finish anyway if it does not.
        let current = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.generation == current else { return }
            self.finish()
        }
    }

    /// Stops without delivering anything, when the screen closes.
    func cancel() {
        generation += 1
        finished = true
        tearDown()
        phase = .idle
    }

    // MARK: Recognition

    private func begin(with recognizer: SFSpeechRecognizer) throws {
        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audio.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // On the device when it can: the audio then never leaves it.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let engine = AVAudioEngine()
        Self.installTap(on: engine.inputNode, feeding: request)
        engine.prepare()
        try engine.start()

        self.request = request
        self.engine = engine
        let current = generation
        recognition = Self.recognize(request, with: recognizer) { [weak self] text, isFinal, failed in
            guard let self, self.generation == current else { return }
            self.received(text: text, isFinal: isFinal, failed: failed)
        }
    }

    private func received(text: String?, isFinal: Bool, failed: Bool) {
        guard !finished else { return }
        if let text, !text.isEmpty {
            transcript = text
            restartSilenceTimer()
        }
        if isFinal || failed {
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        tearDown()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            phase = .failed("لم أسمع شيئاً. اضغط «إملاء» وقل المهمة، أو اكتبها.")
        } else {
            phase = .idle
            onFinish?(text)
        }
    }

    /// Two seconds without new words ends the sentence.
    private func restartSilenceTimer() {
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func tearDown() {
        silence?.cancel()
        limit?.cancel()
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
        engine = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // The audio tap and the recogniser call back on their own queues, so their closures are
    // made outside the main actor and hop back to it.

    nonisolated private static func installTap(on input: AVAudioInputNode, feeding request: SFSpeechAudioBufferRecognitionRequest) {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func recognize(
        _ request: SFSpeechAudioBufferRecognitionRequest, with recognizer: SFSpeechRecognizer,
        handler: @escaping @Sendable @MainActor (String?, Bool, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in handler(text, isFinal, failed) }
        }
    }

    // MARK: Permissions

    nonisolated private static func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    nonisolated private static func microphoneAuthorized() async -> Bool {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        default: return await AVCaptureDevice.requestAccess(for: .audio)
        }
        #endif
    }
}
