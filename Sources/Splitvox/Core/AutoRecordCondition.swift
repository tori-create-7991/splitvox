import Foundation

/// Conditions that must all hold before a recording starts on its own.
///
/// A set rather than a single choice, because the right rule depends on how
/// someone works and the signals are independent. Checking more of them makes
/// the trigger stricter: every enabled condition has to be true.
///
/// Enabling none disables the trigger entirely rather than matching everything.
/// A condition set that fires unconditionally would record all day.
struct AutoRecordConditions: OptionSet, Codable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    /// A configured application is producing sound.
    static let playback = AutoRecordConditions(rawValue: 1 << 0)
    /// Default input is something other than the built-in microphone.
    static let externalInput = AutoRecordConditions(rawValue: 1 << 1)
    /// That external input is real hardware, not a virtual device.
    static let physicalInput = AutoRecordConditions(rawValue: 1 << 2)
    /// Some application is holding a microphone open — the signal Notion uses.
    static let microphoneInUse = AutoRecordConditions(rawValue: 1 << 3)

    /// Playback plus a headset: fires before anyone speaks, and does not record
    /// silence.
    static let `default`: AutoRecordConditions = [.playback, .externalInput]

    static let all: [AutoRecordConditions] = [
        .playback, .externalInput, .physicalInput, .microphoneInUse
    ]

    var label: String {
        switch self {
        case .playback: return "対象アプリが音を出している"
        case .externalInput: return "ヘッドセットが有効"
        case .physicalInput: return "ヘッドセットが実機である"
        case .microphoneInUse: return "マイクが使用中"
        default: return ""
        }
    }

    var detail: String {
        switch self {
        case .playback:
            return "外すと、無音のまま録り続けます（1時間あたり約1GB）。"
        case .externalInput:
            return "既定の入力が内蔵マイク以外。仮想デバイスも含みます。"
        case .physicalInput:
            return "有線・Bluetooth・USB のみ。Krisp などの仮想デバイスを除外します。"
        case .microphoneInUse:
            return "会議アプリがマイクを掴んだとき。Notion AI と同じ判定方法です。"
        default:
            return ""
        }
    }
}
