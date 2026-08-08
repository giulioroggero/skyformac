import Foundation

/// Pure-Swift mirror of `ASI_CONTROL_CAPS`, describing one adjustable camera control
/// (gain, exposure, cooler power, etc.) as reported dynamically by `ASIGetControlCaps`.
struct ZWOControlCaps: Identifiable, Hashable, Sendable {
    var id: Int32 { Int32(controlType.rawValue) }

    let name: String
    let controlDescription: String
    let maxValue: Int
    let minValue: Int
    let defaultValue: Int
    let isAutoSupported: Bool
    let isWritable: Bool
    let controlType: ASI_CONTROL_TYPE

    init(_ caps: ASI_CONTROL_CAPS) {
        name = CTuple.string(fromCCharTuple: caps.Name)
        controlDescription = CTuple.string(fromCCharTuple: caps.Description)
        maxValue = caps.MaxValue
        minValue = caps.MinValue
        defaultValue = caps.DefaultValue
        isAutoSupported = caps.IsAutoSupported.rawValue == ASI_TRUE.rawValue
        isWritable = caps.IsWritable.rawValue == ASI_TRUE.rawValue
        controlType = caps.ControlType
    }

    static func == (lhs: ZWOControlCaps, rhs: ZWOControlCaps) -> Bool {
        lhs.controlType.rawValue == rhs.controlType.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(controlType.rawValue)
    }
}

/// Live value for a control: the current value plus whether it's in auto mode.
struct ZWOControlValue: Sendable {
    var value: Int
    var isAuto: Bool
}
