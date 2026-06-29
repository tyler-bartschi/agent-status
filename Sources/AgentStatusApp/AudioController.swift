import AppKit
import AgentStatusCore

@MainActor
final class AudioController {
    private let preferences: AppPreferences
    private var activeSounds: [NSSound] = []
    private weak var previewSound: NSSound?

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    func play(for transition: SessionTransition) {
        let soundName: String

        switch transition.status {
        case .waiting where preferences.waitingSoundEnabled:
            soundName = preferences.waitingSoundName
        case .finished where preferences.finishedSoundEnabled:
            soundName = preferences.finishedSoundName
        default:
            return
        }

        playSound(named: soundName, isPreview: false)
    }

    func preview(_ status: SessionStatus) {
        let soundName: String
        switch status {
        case .waiting:
            soundName = preferences.waitingSoundName
        case .finished:
            soundName = preferences.finishedSoundName
        case .working:
            return
        }
        playSound(named: soundName, isPreview: true)
    }

    private func playSound(named soundName: String, isPreview: Bool) {
        if isPreview, let previewSound {
            previewSound.stop()
            activeSounds.removeAll { $0 === previewSound }
        }

        guard let sound = makeSound(named: soundName) else { return }
        sound.volume = Float(preferences.volume)
        if isPreview {
            previewSound = sound
        }
        activeSounds.append(sound)
        sound.play()
        let duration = max(sound.duration, 0.25)
        Task { @MainActor [weak self, weak sound] in
            try? await Task.sleep(for: .seconds(duration + 0.25))
            guard let sound else { return }
            self?.activeSounds.removeAll { $0 === sound }
            if self?.previewSound === sound {
                self?.previewSound = nil
            }
        }
    }

    private func makeSound(named name: String) -> NSSound? {
        if let sound = NSSound(named: NSSound.Name(name)) {
            return sound.copy() as? NSSound
        }

        let url = URL(fileURLWithPath: "/System/Library/Sounds")
            .appendingPathComponent(name)
            .appendingPathExtension("aiff")
        return NSSound(contentsOf: url, byReference: true)
    }
}
