import Foundation
// GolemCueTones: each cue is a valid, short, quiet WAV that starts and ends silent.
func check(_ ok: Bool, _ what: String) { precondition(ok, what); print("PASS \(what)") }
for cue in GolemCueTones.Cue.allCases {
    let wav = GolemCueTones.wav(cue)
    let header = String(decoding: wav.prefix(4), as: UTF8.self) + String(decoding: wav[8 ..< 12], as: UTF8.self)
    let samples = (wav.count - 44) / 2
    let values: [Int16] = (0 ..< samples).map { i in wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 44 + i * 2, as: Int16.self) } }
    let peak = values.map { abs(Int($0)) }.max() ?? 0
    check(header == "RIFFWAVE" && abs(samples - Int(GolemCueTones.duration(cue) * 44_100)) <= 2, "\(cue): a WAV of its stated length (\(samples) samples)")
    check(peak > 3000 && peak < Int(Double(Int16.max) * 0.4), "\(cue): audible but soft (peak \(peak))")
    check(abs(Int(values.first ?? 99)) < 200 && abs(Int(values.last ?? 99)) < 200, "\(cue): fades in and out (no click)")
    check(GolemCueTones.duration(cue) <= 0.25, "\(cue): short (\(GolemCueTones.duration(cue)) s)")
}
let rising = GolemCueTones.notes(.listening), falling = GolemCueTones.notes(.thinking)
check(rising.first!.0 < rising.last!.0 && falling.first!.0 > falling.last!.0, "your turn rises, thinking falls")
