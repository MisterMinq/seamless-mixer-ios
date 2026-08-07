import Foundation

/// Direct port of `playlist_mixer.py`'s `camelot_code` / `camelot_compatible` /
/// `camelot_distance` — same lookup tables, same math, per Rule 4 ("don't
/// relitigate validated logic"). If this needs to change, change the Python
/// source first and port the change here, not the other way around.
///
/// Low risk relative to the rest of the Analysis module: no FFT, no signal
/// processing — pure lookup-table and modular-arithmetic logic, the same
/// kind of code already covered by `test_playlist_mixer.py` on the Python
/// side. Still worth a quick sanity check once this compiles, but this is
/// not where to expect surprises.
public enum CamelotKey {

    static let camelotMajor: [String: Int] = [
        "B": 1, "F#": 2, "Gb": 2, "Db": 3, "C#": 3, "Ab": 4, "G#": 4, "Eb": 5, "D#": 5,
        "Bb": 6, "A#": 6, "F": 7, "C": 8, "G": 9, "D": 10, "A": 11, "E": 12,
    ]

    static let pitchClasses = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// - Parameters:
    ///   - pitchClassIndex: 0 = C, 1 = C#, ... 11 = B.
    ///   - isMinor: true for a minor key.
    /// - Returns: e.g. "8A" or "5B".
    public static func code(pitchClassIndex: Int, isMinor: Bool) -> String {
        if isMinor {
            // minor root + 3 semitones = relative major, same as the Python comment.
            let majorIndex = ((pitchClassIndex + 3) % 12 + 12) % 12
            let name = pitchClasses[majorIndex]
            let num = camelotMajor[name] ?? 8
            return "\(num)A"
        } else {
            let name = pitchClasses[((pitchClassIndex % 12) + 12) % 12]
            let num = camelotMajor[name] ?? 8
            return "\(num)B"
        }
    }

    /// True if two Camelot codes are a "safe" harmonic move apart.
    public static func compatible(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let (na, la) = parse(a), let (nb, lb) = parse(b) else { return false }
        if la == lb && (abs(na - nb) == 1 || abs(na - nb) == 11) { return true } // adjacent, wraps 12->1
        if na == nb && la != lb { return true } // relative major/minor switch
        return false
    }

    /// 0 = identical, 1 = safe move, 2+ = increasingly risky.
    public static func distance(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        if compatible(a, b) { return 1 }
        guard let (na, la) = parse(a), let (nb, lb) = parse(b) else { return 99 }
        let ringDist = min(abs(na - nb), 12 - abs(na - nb))
        return ringDist + (la == lb ? 0 : 1)
    }

    private static func parse(_ code: String) -> (Int, Character)? {
        guard let letter = code.last, let num = Int(code.dropLast()) else { return nil }
        return (num, letter)
    }
}
