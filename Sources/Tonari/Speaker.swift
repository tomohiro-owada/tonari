import Foundation

/// TTS wrapper that shells out to `/usr/bin/say`.
///
/// We tried `AVSpeechSynthesizer` first, but on this macOS 26 build it silently
/// no-ops when invoked from an `LSUIElement` accessory app — likely an audio
/// routing issue with no AVAudioSession on macOS. `say` is the system-level TTS
/// daemon and works reliably from any process.
final class Speaker {
    private var process: Process?
    private let queue = DispatchQueue(label: "local.ollamabar.tts")

    func speak(_ text: String, voice: String = "Kyoko") {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice]
        let stdinPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        queue.async { [weak self] in
            do {
                try p.run()
                if let data = trimmed.data(using: .utf8) {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try stdinPipe.fileHandleForWriting.close()
            } catch {
                NSLog("Speaker: failed to launch say: %@", "\(error)")
                return
            }
            self?.process = p
            p.waitUntilExit()
        }
    }

    func stop() {
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
    }
}
