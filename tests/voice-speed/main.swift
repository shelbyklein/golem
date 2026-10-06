import Foundation

let suite = "GolemVoiceSpeedTest-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
precondition(ElevenLabsSpeechSettings.speed(in: defaults) == 1.0)
for value in [0.7, 0.85, 1.0, 1.2] {
    defaults.set(value, forKey: ElevenLabsSpeechSettings.speedKey)
    let reopened = UserDefaults(suiteName: suite)!
    let data = try ElevenLabsSpeechSettings.payload(text: "Offline payload test", speed: ElevenLabsSpeechSettings.speed(in: reopened))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    precondition(json["text"] as? String == "Offline payload test")
    precondition(json["model_id"] as? String == "eleven_flash_v2_5")
    precondition((json["voice_settings"] as! [String: Double])["speed"] == value)
}
for (value, expected) in [(-1.0, 0.7), (4.0, 1.2), (Double.nan, 1.0), (Double.infinity, 1.0)] {
    let json = try JSONSerialization.jsonObject(with: ElevenLabsSpeechSettings.payload(text: "Clamp", speed: value)) as! [String: Any]
    precondition((json["voice_settings"] as! [String: Double])["speed"] == expected)
}
print("PASS: default, persistence, speed range, payload nesting/model/text, invalid values; no network calls")
