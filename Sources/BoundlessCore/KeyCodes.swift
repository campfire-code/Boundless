/// macOS 虚拟键码与修饰键标志位
public enum KeyCodes {
    public static let capsLock: UInt16 = 57
    public static let tab: UInt16 = 48
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126

    public enum Flag {
        public static let capsLock: UInt64 = 0x10000
        public static let shift: UInt64 = 0x20000
        public static let control: UInt64 = 0x40000
        public static let option: UInt64 = 0x80000
        public static let command: UInt64 = 0x100000
        public static let fn: UInt64 = 0x800000
        public static let nonCoalesced: UInt64 = 0x100
    }

    /// 修饰键码 → (通用标志位, 区分左右的设备标志位)
    private static let modifiers: [UInt16: (general: UInt64, device: UInt64)] = [
        55: (Flag.command, 0x08), 54: (Flag.command, 0x10),
        56: (Flag.shift, 0x02), 60: (Flag.shift, 0x04),
        58: (Flag.option, 0x20), 61: (Flag.option, 0x40),
        59: (Flag.control, 0x01), 62: (Flag.control, 0x2000),
        63: (Flag.fn, 0),
    ]

    /// 通用标志位 → 左右两侧设备标志位之和
    private static let deviceBits: [UInt64: UInt64] = [
        Flag.command: 0x18, Flag.shift: 0x06, Flag.option: 0x60, Flag.control: 0x2001,
    ]

    public static func isModifier(_ code: UInt16) -> Bool {
        modifiers[code] != nil
    }

    /// flagsChanged 事件里某个修饰键此刻是否处于按下状态
    public static func isModifierDown(_ code: UInt16, flags: UInt64) -> Bool {
        guard let m = modifiers[code], flags & m.general != 0 else { return false }
        // 键盘上报了左右区分位时按设备位判断；部分第三方键盘不报，只能按通用位判断
        if let both = deviceBits[m.general], flags & both != 0 {
            return flags & m.device != 0
        }
        return true
    }

    /// 由当前按住的修饰键推算事件 flags
    public static func flags(forHeld codes: Set<UInt16>) -> UInt64 {
        codes.reduce(Flag.nonCoalesced) { acc, code in
            guard let m = modifiers[code] else { return acc }
            return acc | m.general | m.device
        }
    }

    public static func arrow(toward edge: Edge) -> UInt16 {
        switch edge {
        case .left: return leftArrow
        case .right: return rightArrow
        case .top: return upArrow
        case .bottom: return downArrow
        }
    }

    /// 切换快捷键：⌃⌥⌘ + 朝向 edge 的方向键
    public static func isSwitchHotkey(_ code: UInt16, flags: UInt64, toward edge: Edge) -> Bool {
        let required = Flag.control | Flag.option | Flag.command
        return code == arrow(toward: edge) && flags & required == required
    }

    /// ⌘Tab 切换应用：虚拟屏上的窗口在前台时也留在本机
    public static func isAppSwitcher(_ code: UInt16, flags: UInt64) -> Bool {
        code == tab && flags & Flag.command != 0
    }
}
