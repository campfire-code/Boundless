import CoreGraphics
import XCTest
@testable import BoundlessCore

final class WireTests: XCTestCase {
    private let samples: [Message] = [
        .hello(version: 1, name: "Mac mini 客厅", channel: .control),
        .hello(version: 3, name: "MacBook", channel: .video),
        .hello(version: 8, name: "Windows 书房", channel: .control, platform: .windows),
        .ping,
        .layout(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: -98, width: 1920, height: 1080)]),
        .enter(x: 3.5, y: 490.25),
        .leave,
        .edgePush(x: -4, y: 120.5),
        .mouseMove(dx: -3.5, dy: 12.25),
        .mouseButton(button: 2, down: true, clickCount: 2),
        .scroll(ScrollEvent(deltaAxis1: -1, deltaAxis2: 2, pointDeltaAxis1: -10, pointDeltaAxis2: 20,
                            fixedDeltaAxis1: -1.5, fixedDeltaAxis2: 2.5, isContinuous: true, scrollPhase: 2, momentumPhase: 1)),
        .key(code: 55, down: false, autorepeat: true),
        .systemKey(data1: 0x000A_0A00),
        .clipboard([ClipboardItem(type: "public.utf8-plain-text", data: Data("你好".utf8)),
                    ClipboardItem(type: "public.png", data: Data([0, 1, 2, 255]))]),
        .releaseAll,
        .windowListRequest,
        .windowList([RemoteWindow(id: 42, app: "终端", title: "kl — zsh — 80×24", frame: CGRect(x: 10, y: 38, width: 585, height: 368)),
                     RemoteWindow(id: 7, app: "Safari", title: "", frame: CGRect(x: -1200, y: 0, width: 1200, height: 800))]),
        .virtualDisplay(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)),
        .virtualReady(frame: .zero),
        .virtualWindows(capture: CGRect(x: 0, y: 32, width: 1216, height: 808),
                        windows: [CGRect(x: 10, y: 38, width: 1200, height: 800), CGRect(x: 0, y: 0, width: 200, height: 300)]),
        .moveTo(x: -1820.5, y: 300),
        .moveWindowToVirtual(window: 42),
        .recallWindows,
        .videoFormat(window: 0, codec: .hevc, nalLengthSize: 4, parameterSets: [Data([0x40, 1]), Data([0x42]), Data([0x44, 1, 2])]),
        .videoFrame(window: 0, keyframe: true, captureTime: 1_792_000_000.125, data: Data([0, 0, 0, 2, 0x26, 0x01])),
        .requestKeyframe(window: 0),
        .clockProbe(serverTime: 1_792_000_000.5),
        .clockReply(serverTime: 1_792_000_000.5, clientTime: 1_792_000_000.25),
    ]

    func testEveryMessageRoundTrips() throws {
        for m in samples {
            XCTAssertEqual(try Message(decoding: m.encoded()), m)
        }
    }

    func testDecoderHandlesSplitAndConcatenatedFrames() throws {
        let stream = samples.map(Frame.encode).reduce(Data(), +)
        var decoder = FrameDecoder()
        var out: [Message] = []
        var i = stream.startIndex
        while i < stream.endIndex {
            let end = min(i + 7, stream.endIndex)
            out += try decoder.append(stream.subdata(in: i..<end))
            i = end
        }
        XCTAssertEqual(out, samples)
    }

    func testOldHelloWithoutChannelStillDecodes() throws {
        // v2 的 hello 没有通道字段，要能解出来才能提示「版本不一致」
        var w = ByteWriter()
        w.u8(1); w.u16(2); w.string("旧版")
        XCTAssertEqual(try Message(decoding: w.data), .hello(version: 2, name: "旧版", channel: .control))
    }

    func testV7HelloWithoutPlatformDecodesAsMac() throws {
        var w = ByteWriter()
        w.u8(1); w.u16(7); w.string("M"); w.u8(Channel.video.rawValue)
        XCTAssertEqual(try Message(decoding: w.data), .hello(version: 7, name: "M", channel: .video, platform: .mac))
    }

    func testHelloBytesMatchRustImplementation() {
        // 与 windows/core/tests/message_tests.rs 里的 golden_bytes_match_swift_layout 相同
        XCTAssertEqual(Message.hello(version: 8, name: "PC", channel: .video, platform: .windows).encoded(),
                       Data([1, 8, 0, 2, 0, 0, 0, UInt8(ascii: "P"), UInt8(ascii: "C"), 1, 1]))
    }

    func testOversizedFrameIsRejected() {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0xFF, 0xFF, 0xFF, 0x7F])))
    }

    func testCorruptPayloadIsRejected() {
        XCTAssertThrowsError(try Message(decoding: Data([200])))
        XCTAssertThrowsError(try Message(decoding: Data([4, 9, 0, 0])))
        XCTAssertThrowsError(try Message(decoding: Frame.encode(.ping) + Data([1])))
    }
}

final class GeometryTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testEdgesOfSingleDisplay() {
        let d = Desktop(displays: [laptop])
        XCTAssertTrue(d.isAtEdge(CGPoint(x: 1511, y: 400), .right))
        XCTAssertTrue(d.isAtEdge(CGPoint(x: 1511.6, y: 400), .right))
        XCTAssertFalse(d.isAtEdge(CGPoint(x: 1500, y: 400), .right))
        XCTAssertTrue(d.isAtEdge(CGPoint(x: 0, y: 400), .left))
        XCTAssertEqual(d.clamp(CGPoint(x: -20, y: 5000)), CGPoint(x: 0, y: 981))
    }

    func testInnerEdgeBetweenTwoDisplaysIsNotAnExit() {
        let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        let d = Desktop(displays: [laptop, external])
        XCTAssertFalse(d.isAtEdge(CGPoint(x: 1511, y: 400), .right), "右边还有外接屏，不算桌面外沿")
        XCTAssertTrue(d.isAtEdge(CGPoint(x: 4071, y: 400), .right))
        XCTAssertEqual(d.bounds, CGRect(x: 0, y: -200, width: 4072, height: 1440))
        XCTAssertEqual(d.main, laptop)
    }

    func testPointBeyondOnlyWhenPushingOutOfDesktop() {
        let d = Desktop(displays: [laptop])
        XCTAssertEqual(d.pointBeyond(CGPoint(x: 1511, y: 400), dx: 0.3, dy: 0), CGPoint(x: 1512, y: 400), "小位移也要推到边外")
        XCTAssertEqual(d.pointBeyond(CGPoint(x: 0, y: 400), dx: -5, dy: 0), CGPoint(x: -5, y: 400))
        XCTAssertNil(d.pointBeyond(CGPoint(x: 1511, y: 400), dx: -3, dy: 0), "往回走不算")
        XCTAssertNil(d.pointBeyond(CGPoint(x: 800, y: 400), dx: 30, dy: 0), "不在边上不算")
    }
}

final class ArrangementTests: XCTestCase {
    private let monitor = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testDefaultPlacementIsRightOfMainDisplayCentered() {
        let a = Arrangement.defaultPlacement(clientDisplays: [laptop], server: Desktop(displays: [monitor]))
        XCTAssertEqual(a.placedBounds, CGRect(x: 2560, y: 229, width: 1512, height: 982))
        XCTAssertEqual(a.side(relativeTo: Desktop(displays: [monitor])), .right)
    }

    func testDroppedBlockSnapsToNearestSideKeepingOffset() {
        let server = Desktop(displays: [monitor])
        // 拖到左边、略有空隙、位置偏下
        let dropped = Arrangement(clientDisplays: [laptop], origin: CGPoint(x: -1600, y: 700))
        let snapped = dropped.snapped(to: server)
        XCTAssertEqual(snapped.origin, CGPoint(x: -1512, y: 700))
        XCTAssertEqual(snapped.side(relativeTo: server), .left)
        XCTAssertEqual(snapped.sharedEdges(with: server),
                       [Arrangement.Segment(from: CGPoint(x: 0, y: 700), to: CGPoint(x: 0, y: 1440))])
    }

    func testSnapKeepsMinimumOverlapAndNeverOverlapsServer() {
        let server = Desktop(displays: [monitor])
        let farBelow = Arrangement(clientDisplays: [laptop], origin: CGPoint(x: -1500, y: 3000)).snapped(to: server)
        let overlap = farBelow.sharedEdges(with: server).first!
        XCTAssertGreaterThanOrEqual(abs(overlap.to.x - overlap.from.x) + abs(overlap.to.y - overlap.from.y), 40)

        let inside = Arrangement(clientDisplays: [laptop], origin: CGPoint(x: 1000, y: 200)).snapped(to: server)
        XCTAssertFalse(inside.placedDisplays[0].intersects(monitor.insetBy(dx: 1, dy: 1)), "丢在主控端屏幕中间也要推到边外")
    }

    func testCoordinateMappingUsesClientBounds() {
        // 被控端自己有两块屏，外框原点不在 (0,0)
        let client = [laptop, CGRect(x: -1920, y: -100, width: 1920, height: 1080)]
        let a = Arrangement(clientDisplays: client, origin: CGPoint(x: 2560, y: 0))
        XCTAssertEqual(a.toServer(CGPoint(x: -1920, y: -100)), CGPoint(x: 2560, y: 0))
        XCTAssertEqual(a.toClient(a.toServer(CGPoint(x: 700, y: 300))), CGPoint(x: 700, y: 300))
        XCTAssertEqual(a.clientPoint(atServer: CGPoint(x: 2561, y: 50)), CGPoint(x: -1919, y: -50))
        XCTAssertNil(a.clientPoint(atServer: CGPoint(x: 2561, y: 1100)), "落在外接屏下方的空白处")
    }
}

final class KeyCodesTests: XCTestCase {
    func testModifierDownDetection() {
        let leftCmd = KeyCodes.Flag.command | 0x08
        XCTAssertTrue(KeyCodes.isModifierDown(55, flags: leftCmd))
        XCTAssertFalse(KeyCodes.isModifierDown(54, flags: leftCmd), "按左 ⌘ 时右 ⌘ 不算按下")
        XCTAssertFalse(KeyCodes.isModifierDown(55, flags: 0x100))
        XCTAssertTrue(KeyCodes.isModifierDown(56, flags: KeyCodes.Flag.shift), "不报左右位的键盘按通用位判断")
    }

    func testFlagsForHeldKeysAndHotkey() {
        let flags = KeyCodes.flags(forHeld: [55, 58, 59, 0])
        XCTAssertTrue(KeyCodes.isSwitchHotkey(KeyCodes.rightArrow, flags: flags, toward: .right))
        XCTAssertFalse(KeyCodes.isSwitchHotkey(KeyCodes.leftArrow, flags: flags, toward: .right))
        XCTAssertFalse(KeyCodes.isSwitchHotkey(KeyCodes.rightArrow, flags: KeyCodes.flags(forHeld: [55, 58]), toward: .right))
    }
}

final class PairingTests: XCTestCase {
    func testCodeFormatAndNormalization() {
        let code = Pairing.generateCode()
        XCTAssertEqual(code.count, 14)
        XCTAssertEqual(Pairing.normalize(code), code)
        XCTAssertEqual(Pairing.normalize(" \(code.lowercased().replacingOccurrences(of: "-", with: " ")) "), code)
        XCTAssertNil(Pairing.normalize("ABCD-EFGH-IJKL"), "I、L 不在字母表里")
        XCTAssertNil(Pairing.normalize("ABCD-EFGH"))
    }

    func testKeyDerivationIsStableAndDistinct() {
        let a = Pairing.presharedKey(for: "ABCD-EFGH-JKMN")
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(a, Pairing.presharedKey(for: "abcdefghjkmn"))
        XCTAssertNotEqual(a, Pairing.presharedKey(for: "ABCD-EFGH-JKMP"))
    }
}

final class ServerSwitchTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let client = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let hotkeyFlags = KeyCodes.Flag.control | KeyCodes.Flag.option | KeyCodes.Flag.command

    /// 被控端放在右侧，顶部对齐
    private func makeSwitch(connected: Bool = true, originY: CGFloat = 0) -> ServerSwitch {
        let s = ServerSwitch(desktop: Desktop(displays: [screen]),
                             arrangement: Arrangement(clientDisplays: [client], origin: CGPoint(x: 1512, y: originY)))
        if connected { _ = s.setConnected(true) }
        return s
    }

    private func pushRight(_ s: ServerSwitch, y: Double = 491) -> Decision {
        s.handle(.mouseMove(location: CGPoint(x: 1511, y: y), dx: 4, dy: 0))
    }

    func testPushingIntoClientScreenEntersRemoteAtMatchingPoint() {
        let s = makeSwitch()
        XCTAssertTrue(s.handle(.mouseMove(location: CGPoint(x: 1400, y: 491), dx: 4, dy: 0)).passLocally)
        let d = pushRight(s)
        XCTAssertEqual(s.mode, .remote)
        XCTAssertFalse(d.passLocally)
        XCTAssertEqual(d.effect, .enterRemote)
        XCTAssertEqual(d.messages, [.enter(x: 3, y: 491)], "按真实位置对齐，不按比例拉伸")
    }

    func testOnlyTheOverlappingSegmentCrosses() {
        // 被控端往下错开 600，只有 y ≥ 600 的那段边能过去
        let s = makeSwitch(originY: 600)
        XCTAssertTrue(pushRight(s, y: 300).passLocally)
        XCTAssertEqual(s.mode, .local)
        XCTAssertEqual(pushRight(s, y: 800).messages, [.enter(x: 3, y: 200)])
    }

    func testOtherEdgesDoNotCross() {
        let s = makeSwitch()
        XCTAssertTrue(s.handle(.mouseMove(location: CGPoint(x: 0, y: 400), dx: -5, dy: 0)).passLocally)
        XCTAssertEqual(s.mode, .local)
    }

    func testNoSwitchWhenDisconnectedDraggingOrLayoutUnknown() {
        let off = makeSwitch(connected: false)
        XCTAssertTrue(pushRight(off).passLocally)

        let dragging = makeSwitch()
        _ = dragging.handle(.mouseButton(button: 0, down: true, clickCount: 1))
        XCTAssertTrue(pushRight(dragging).passLocally)

        let unknown = ServerSwitch(desktop: Desktop(displays: [screen]))
        _ = unknown.setConnected(true)
        XCTAssertTrue(pushRight(unknown).passLocally)
        XCTAssertEqual(unknown.mode, .local)
    }

    func testRemoteModeForwardsAndSwallowsEverything() {
        let s = makeSwitch()
        _ = pushRight(s)
        XCTAssertEqual(s.handle(.mouseMove(location: CGPoint(x: 1511, y: 491), dx: -2, dy: 3)),
                       Decision(passLocally: false, messages: [.mouseMove(dx: -2, dy: 3)]))
        XCTAssertEqual(s.handle(.mouseButton(button: 0, down: true, clickCount: 2)).messages,
                       [.mouseButton(button: 0, down: true, clickCount: 2)])
        XCTAssertEqual(s.handle(.key(code: 0, down: true, autorepeat: false, flags: 0)).messages,
                       [.key(code: 0, down: true, autorepeat: false)])
        XCTAssertFalse(s.handle(.scroll(ScrollEvent(deltaAxis1: 1))).passLocally)
        XCTAssertFalse(s.handle(.systemKey(data1: 0x000A_0A00)).passLocally)
    }

    func testKeyHeldBeforeSwitchIsReleasedLocally() {
        let s = makeSwitch()
        XCTAssertTrue(s.handle(.key(code: 56, down: true, autorepeat: false, flags: KeyCodes.Flag.shift)).passLocally)
        _ = pushRight(s)
        XCTAssertTrue(s.handle(.key(code: 56, down: false, autorepeat: false, flags: 0)).passLocally,
                      "本机按下的 Shift 必须在本机松开，否则本机卡键")
    }

    func testAutorepeatFollowsTheSideWhereKeyWentDown() {
        let s = makeSwitch()
        _ = s.handle(.key(code: 2, down: true, autorepeat: false, flags: 0))
        _ = pushRight(s)
        XCTAssertTrue(s.handle(.key(code: 2, down: true, autorepeat: true, flags: 0)).passLocally)
        XCTAssertTrue(s.handle(.key(code: 2, down: false, autorepeat: false, flags: 0)).passLocally)
    }

    func testHotkeysFollowArrangementSideAndRouteModifierReleases() {
        let s = makeSwitch()
        for code: UInt16 in [59, 58, 55] { _ = s.handle(.key(code: code, down: true, autorepeat: false, flags: hotkeyFlags)) }
        XCTAssertTrue(s.handle(.key(code: KeyCodes.leftArrow, down: true, autorepeat: false, flags: hotkeyFlags)).passLocally,
                      "被控端在右侧，⌃⌥⌘← 不切换")
        let go = s.handle(.key(code: KeyCodes.rightArrow, down: true, autorepeat: false, flags: hotkeyFlags))
        XCTAssertEqual(go.effect, .enterRemote)
        XCTAssertFalse(s.handle(.key(code: KeyCodes.rightArrow, down: true, autorepeat: true, flags: hotkeyFlags)).passLocally)
        XCTAssertEqual(s.handle(.key(code: KeyCodes.rightArrow, down: false, autorepeat: false, flags: hotkeyFlags)), .swallow)
        for code: UInt16 in [59, 58, 55] { XCTAssertTrue(s.handle(.key(code: code, down: false, autorepeat: false, flags: 0)).passLocally) }

        for code: UInt16 in [59, 58, 55] { _ = s.handle(.key(code: code, down: true, autorepeat: false, flags: hotkeyFlags)) }
        _ = s.handle(.key(code: KeyCodes.leftArrow, down: false, autorepeat: false, flags: hotkeyFlags))
        let back = s.handle(.key(code: KeyCodes.leftArrow, down: true, autorepeat: false, flags: hotkeyFlags))
        XCTAssertEqual(s.mode, .local)
        XCTAssertEqual(back.effect, .returnLocal(warpTo: nil))
        XCTAssertEqual(back.messages.last, .leave, "快捷键切回要通知被控端")
        for code: UInt16 in [59, 58, 55] {
            let d = s.handle(.key(code: code, down: false, autorepeat: false, flags: 0))
            XCTAssertEqual(d.messages, [.key(code: code, down: false, autorepeat: false)])
        }
    }

    func testHotkeyEntersAtNearestClientPoint() {
        let s = makeSwitch(originY: 600)
        _ = s.handle(.mouseMove(location: CGPoint(x: 700, y: 100), dx: 1, dy: 0))
        let go = s.handle(.key(code: KeyCodes.rightArrow, down: true, autorepeat: false, flags: hotkeyFlags))
        XCTAssertEqual(go.messages, [.enter(x: 0, y: 0)])
    }

    func testClientPushBackIntoServerScreenReturnsControl() {
        let s = makeSwitch(originY: 600)
        _ = pushRight(s, y: 800)
        // 从被控端左边缘 y=300（对应主控端 y=900）推出来
        let d = s.clientPushed(at: CGPoint(x: -3, y: 300))
        XCTAssertEqual(s.mode, .local)
        XCTAssertEqual(d.effect, .returnLocal(warpTo: CGPoint(x: 1509, y: 900)))
        XCTAssertEqual(d.messages, [.leave])
    }

    func testClientPushOutsideOverlapIsIgnored() {
        let s = makeSwitch(originY: 600)
        _ = pushRight(s, y: 800)
        // 被控端左边缘 y=800 对应主控端 y=1400，超出主控端屏幕，不能回去
        XCTAssertEqual(s.clientPushed(at: CGPoint(x: -3, y: 800)), .pass)
        XCTAssertEqual(s.mode, .remote)
    }

    func testDisconnectWhileRemoteReturnsControl() {
        let s = makeSwitch()
        _ = pushRight(s)
        _ = s.handle(.key(code: 0, down: true, autorepeat: false, flags: 0))
        let d = s.setConnected(false)
        XCTAssertEqual(s.mode, .local)
        XCTAssertEqual(d.effect, .returnLocal(warpTo: nil))
        XCTAssertTrue(s.handle(.key(code: 0, down: false, autorepeat: false, flags: 0)).passLocally)
    }

    func testRemoteButtonsReleasedWhenHotkeyReturns() {
        let s = makeSwitch()
        _ = pushRight(s)
        _ = s.handle(.mouseButton(button: 1, down: true, clickCount: 1))
        let back = s.handle(.key(code: KeyCodes.leftArrow, down: true, autorepeat: false, flags: hotkeyFlags))
        XCTAssertEqual(back.messages, [.mouseButton(button: 1, down: false, clickCount: 1), .leave])
    }
}

final class ClientCursorTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    private func makeCursor() -> ClientCursor {
        let c = ClientCursor(desktop: Desktop(displays: [screen]))
        _ = c.handle(.enter(x: 3, y: 719.5))
        return c
    }

    func testEnterWarpsToGivenPointClamped() {
        let c = ClientCursor(desktop: Desktop(displays: [screen]))
        XCTAssertEqual(c.handle(.enter(x: -10, y: 500)).actions, [.warp(CGPoint(x: 0, y: 500))])
        XCTAssertTrue(c.isActive)
    }

    func testMovesAreClampedInsideScreen() {
        let c = makeCursor()
        let (actions, replies) = c.handle(.mouseMove(dx: 100, dy: 10))
        XCTAssertEqual(replies, [])
        XCTAssertEqual(actions, [.move(to: CGPoint(x: 103, y: 729.5), dx: 100, dy: 10, dragButton: nil)])
    }

    func testPushingOutReportsRawPointButStaysActive() {
        let c = makeCursor()
        let (actions, replies) = c.handle(.mouseMove(dx: -10, dy: 0))
        XCTAssertEqual(replies, [.edgePush(x: -7, y: 719.5)])
        XCTAssertEqual(actions, [.move(to: CGPoint(x: 0, y: 719.5), dx: -10, dy: 0, dragButton: nil)])
        XCTAssertTrue(c.isActive, "由主控端决定是否收回")
        _ = c.handle(.leave)
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(c.handle(.mouseMove(dx: 5, dy: 0)).actions, [], "收回后忽略移动")
    }

    func testNoPushReportWhileDragging() {
        let c = makeCursor()
        _ = c.handle(.mouseButton(button: 0, down: true, clickCount: 1))
        let (actions, replies) = c.handle(.mouseMove(dx: -10, dy: 0))
        XCTAssertEqual(replies, [])
        XCTAssertEqual(actions, [.move(to: CGPoint(x: 0, y: 719.5), dx: -10, dy: 0, dragButton: 0)])
    }

    func testModifierFlagsFollowHeldKeys() {
        let c = makeCursor()
        let cmd = KeyCodes.flags(forHeld: [55])
        XCTAssertEqual(c.handle(.key(code: 55, down: true, autorepeat: false)).actions,
                       [.key(code: 55, down: true, autorepeat: false, flags: cmd)])
        XCTAssertEqual(c.handle(.key(code: 8, down: true, autorepeat: false)).actions,
                       [.key(code: 8, down: true, autorepeat: false, flags: cmd)])
        XCTAssertEqual(c.handle(.key(code: 55, down: false, autorepeat: false)).actions,
                       [.key(code: 55, down: false, autorepeat: false, flags: KeyCodes.Flag.nonCoalesced)])
    }

    func testReleaseAllLetsGoOfEverything() {
        let c = makeCursor()
        _ = c.handle(.key(code: 55, down: true, autorepeat: false))
        _ = c.handle(.key(code: 8, down: true, autorepeat: false))
        _ = c.handle(.mouseButton(button: 0, down: true, clickCount: 1))
        let actions = c.releaseAll()
        XCTAssertEqual(actions.count, 3)
        XCTAssertEqual(actions.last, .key(code: 55, down: false, autorepeat: false, flags: KeyCodes.Flag.nonCoalesced),
                       "修饰键最后松开")
        XCTAssertEqual(c.releaseAll(), [])
        XCTAssertFalse(c.isActive)
    }

    func testLaggingSystemCursorDoesNotPullPositionBack() {
        // 系统处理注入事件有延迟：读回的光标位置总是落后两步。快速移动时不能被拉回旧位置
        let c = makeCursor()
        var posted: [CGPoint] = [c.position, c.position]
        for _ in 0..<20 {
            c.syncPosition(posted[posted.count - 2])
            if case let .move(to, _, _, _)? = c.handle(.mouseMove(dx: 5, dy: 0)).actions.first { posted.append(to) }
        }
        XCTAssertEqual(c.position.x, 103, accuracy: 0.001, "移动 20 次 × 5 点，应到 x=103")
    }

    func testRealLocalMouseMovementIsStillFollowed() {
        // 被控端自己的鼠标确实动了（位置不在最近注入过的点附近），要以系统位置为准
        let c = makeCursor()
        _ = c.handle(.mouseMove(dx: 5, dy: 0))
        c.syncPosition(CGPoint(x: 900, y: 300))
        XCTAssertEqual(c.handle(.mouseMove(dx: 1, dy: 0)).actions, [.move(to: CGPoint(x: 901, y: 300), dx: 1, dy: 0, dragButton: nil)])
    }

    func testCapsLockBecomesFullPress() {
        let c = makeCursor()
        let actions = c.handle(.key(code: KeyCodes.capsLock, down: false, autorepeat: false)).actions
        XCTAssertEqual(actions.map { action -> Bool? in
            if case let .key(_, down, _, _) = action { return down }
            return nil
        }, [true, false])
        XCTAssertEqual(c.releaseAll(), [], "大写锁定不计入按住的键")
    }
}

final class StreamGeometryTests: XCTestCase {
    func testPixelSizeIsEvenRetinaAndCapped() {
        XCTAssertEqual(StreamGeometry.pixelSize(points: CGSize(width: 585.5, height: 368), scale: 2).width, 1170)
        XCTAssertEqual(StreamGeometry.pixelSize(points: CGSize(width: 585.5, height: 368), scale: 2).height, 736)
        let big = StreamGeometry.pixelSize(points: CGSize(width: 3000, height: 1500), scale: 2)
        XCTAssertEqual(big.width, 4096)
        XCTAssertEqual(big.height, 2048)
    }

    func testCaptureRectIsTightWhenStillAndFullWhileMoving() {
        let screen = CGSize(width: 1920, height: 1080)
        let term = CGRect(x: 360, y: 140, width: 1201, height: 801)
        let tight = StreamGeometry.captureRect(windows: [term], screen: screen, moving: false, current: nil)
        XCTAssertEqual(tight, CGRect(x: 352, y: 132, width: 1218, height: 818))
        XCTAssertEqual(StreamGeometry.captureRect(windows: [term], screen: screen, moving: true, current: tight),
                       CGRect(origin: .zero, size: screen))
        // 窗口在原区域里略缩小不换；挪出去或缩得很小才换
        XCTAssertEqual(StreamGeometry.captureRect(windows: [CGRect(x: 380, y: 150, width: 1100, height: 760)], screen: screen,
                                                  moving: false, current: tight), tight)
        XCTAssertNotEqual(StreamGeometry.captureRect(windows: [term.offsetBy(dx: 100, dy: 0)], screen: screen, moving: false, current: tight), tight)
        XCTAssertNotEqual(StreamGeometry.captureRect(windows: [CGRect(x: 400, y: 200, width: 300, height: 200)], screen: screen,
                                                     moving: false, current: tight), tight)
        // 贴边的窗口收在屏幕内；没有窗口时维持原样
        XCTAssertEqual(StreamGeometry.captureRect(windows: [CGRect(x: -20, y: 900, width: 500, height: 300)], screen: screen,
                                                  moving: false, current: nil), CGRect(x: 0, y: 892, width: 488, height: 188))
        XCTAssertEqual(StreamGeometry.captureRect(windows: [], screen: screen, moving: false, current: tight), tight)
    }

    func testCaptureScaleIsNativeUnlessOverBudget() {
        XCTAssertEqual(StreamGeometry.captureScale(points: CGSize(width: 1218, height: 818), native: 2, maxPixels: 2880 * 1620), 2)
        XCTAssertEqual(StreamGeometry.captureScale(points: CGSize(width: 1920, height: 1080), native: 2, maxPixels: 2880 * 1620), 1.5, accuracy: 0.001)
    }

    func testBitrateIsBounded() {
        XCTAssertEqual(StreamGeometry.bitrate(width: 100, height: 100), 4_000_000)
        XCTAssertEqual(StreamGeometry.bitrate(width: 2880, height: 1800), 20_736_000)
        XCTAssertEqual(StreamGeometry.bitrate(width: 8000, height: 8000), 40_000_000)
        XCTAssertEqual(StreamGeometry.bitrate(width: 2880, height: 1620, wired: true), 55_987_200)
        XCTAssertEqual(StreamGeometry.bitrate(width: 8000, height: 8000, wired: true), 80_000_000)
    }
}

/// 主控端一块 1920×1080 的屏幕，被控端 MacBook 放在右侧顶对齐；虚拟屏就是主控端这块屏幕搬到被控端左边
final class VirtualScreenTests: XCTestCase {
    private let mini = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let book = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private var arrangement: Arrangement { Arrangement(clientDisplays: [book], origin: CGPoint(x: 1920, y: 0)) }

    /// 虚拟屏上 x < 1000 的地方有窗口
    private func makeSwitch() -> ServerSwitch {
        let s = ServerSwitch(desktop: Desktop(displays: [mini]), arrangement: arrangement)
        _ = s.setConnected(true)
        s.virtualScreen = arrangement.virtualScreen(for: Desktop(displays: [mini]))
        s.virtualHitTest = { $0.x < 1000 }
        return s
    }

    func testVirtualScreenSitsWhereTheServerDisplayIs() {
        let vs = arrangement.virtualScreen(for: Desktop(displays: [mini]))
        XCTAssertEqual(vs?.server, mini)
        XCTAssertEqual(vs?.client, CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(vs?.toClient(CGPoint(x: 100, y: 200)), CGPoint(x: -1820, y: 200))
        XCTAssertEqual(vs?.toClient(CGPoint(x: 2500, y: -5)), CGPoint(x: -1, y: 0))
        // 两块主控端屏幕时取与被控端贴边的那块
        let left = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        XCTAssertEqual(arrangement.virtualScreen(for: Desktop(displays: [left, mini]))?.server, mini)
    }

    func testDraggingFromClientIntoVirtualKeepsTheButtonHeld() {
        let s = makeSwitch()
        _ = s.handle(.mouseMove(location: CGPoint(x: 1919, y: 300), dx: 4, dy: 0))
        XCTAssertEqual(s.mode, .remote)
        _ = s.handle(.mouseButton(button: 0, down: true, clickCount: 1))
        let d = s.clientPushed(at: CGPoint(x: -1, y: 300))
        XCTAssertEqual(d, Decision(passLocally: false, messages: [.leave, .moveTo(x: -1, y: 300)],
                                   effect: .returnLocal(warpTo: CGPoint(x: 1919, y: 300))))
        XCTAssertEqual(s.mode, .local)
        // 本机光标接着拖，位置换算到虚拟屏，被控端的键一直按着，松开也转过去
        XCTAssertEqual(s.handle(.mouseMove(location: CGPoint(x: 1500, y: 310), dx: -5, dy: 1)),
                       Decision(passLocally: false, messages: [.moveTo(x: -420, y: 310)]))
        XCTAssertEqual(s.handle(.mouseButton(button: 0, down: false, clickCount: 1)),
                       Decision(passLocally: false, messages: [.mouseButton(button: 0, down: false, clickCount: 1)]))
        // 拖进来的窗口直接可以打字
        XCTAssertEqual(s.handle(.key(code: 0, down: true, autorepeat: false, flags: 0)).messages,
                       [.key(code: 0, down: true, autorepeat: false)])
    }

    func testPlainPushIntoServerStillReleasesAndLeaves() {
        let s = makeSwitch()
        _ = s.handle(.mouseMove(location: CGPoint(x: 1919, y: 300), dx: 4, dy: 0))
        XCTAssertEqual(s.clientPushed(at: CGPoint(x: -1, y: 300)).messages, [.leave])
        XCTAssertTrue(s.handle(.key(code: 0, down: true, autorepeat: false, flags: 0)).passLocally)
    }

    func testClickingAVirtualWindowRoutesMouseAndKeyboardThere() {
        let s = makeSwitch()
        XCTAssertEqual(s.handle(.mouseMove(location: CGPoint(x: 500, y: 500), dx: 1, dy: 0)),
                       Decision(passLocally: false, messages: [.moveTo(x: -1420, y: 500)]))
        XCTAssertEqual(s.handle(.mouseButton(button: 0, down: true, clickCount: 1)),
                       Decision(passLocally: false, messages: [.moveTo(x: -1420, y: 500), .mouseButton(button: 0, down: true, clickCount: 1)],
                                effect: .focusVirtual))
        _ = s.handle(.mouseButton(button: 0, down: false, clickCount: 1))
        XCTAssertEqual(s.handle(.scroll(ScrollEvent(deltaAxis1: 1))).messages, [.moveTo(x: -1420, y: 500), .scroll(ScrollEvent(deltaAxis1: 1))])
        XCTAssertEqual(s.handle(.key(code: 0, down: true, autorepeat: false, flags: 0)).messages, [.key(code: 0, down: true, autorepeat: false)])
        _ = s.handle(.key(code: 0, down: false, autorepeat: false, flags: 0))
        // 移到本机的地方点一下，鼠标键盘都回到本机
        XCTAssertEqual(s.handle(.mouseMove(location: CGPoint(x: 1500, y: 500), dx: 1, dy: 0)), Decision(passLocally: true))
        XCTAssertEqual(s.handle(.mouseButton(button: 0, down: true, clickCount: 1)), Decision(passLocally: true))
        XCTAssertEqual(s.handle(.mouseButton(button: 0, down: false, clickCount: 1)), Decision(passLocally: true))
        XCTAssertTrue(s.handle(.key(code: 0, down: true, autorepeat: false, flags: 0)).passLocally)
    }

    func testModifiersReachBothSidesAndCommandTabStaysLocal() {
        let s = makeSwitch()
        _ = s.handle(.mouseMove(location: CGPoint(x: 500, y: 500), dx: 1, dy: 0))
        _ = s.handle(.mouseButton(button: 0, down: true, clickCount: 1))
        _ = s.handle(.mouseButton(button: 0, down: false, clickCount: 1))
        let cmd = KeyCodes.Flag.command
        XCTAssertEqual(s.handle(.key(code: 55, down: true, autorepeat: false, flags: cmd)),
                       Decision(passLocally: true, messages: [.key(code: 55, down: true, autorepeat: false)]))
        XCTAssertEqual(s.handle(.key(code: KeyCodes.tab, down: true, autorepeat: false, flags: cmd)), Decision(passLocally: true))
        XCTAssertEqual(s.handle(.key(code: KeyCodes.tab, down: false, autorepeat: false, flags: cmd)), Decision(passLocally: true))
        XCTAssertEqual(s.handle(.key(code: 55, down: false, autorepeat: false, flags: 0)),
                       Decision(passLocally: true, messages: [.key(code: 55, down: false, autorepeat: false)]))
    }

    func testDraggingOnVirtualAcrossTheEdgeContinuesOnClient() {
        let s = makeSwitch()
        s.virtualHitTest = { _ in true }
        _ = s.handle(.mouseMove(location: CGPoint(x: 1900, y: 300), dx: 1, dy: 0))
        _ = s.handle(.mouseButton(button: 0, down: true, clickCount: 1))
        let d = s.handle(.mouseMove(location: CGPoint(x: 1919, y: 300), dx: 4, dy: 0))
        XCTAssertEqual(d.messages, [.enter(x: 3, y: 300)])
        XCTAssertEqual(s.mode, .remote)
        XCTAssertEqual(s.handle(.mouseButton(button: 0, down: false, clickCount: 1)).messages,
                       [.mouseButton(button: 0, down: false, clickCount: 1)])
    }

    func testNothingRoutedWithoutVirtualScreenOrAfterDisconnect() {
        let s = makeSwitch()
        s.virtualScreen = nil
        XCTAssertEqual(s.handle(.mouseMove(location: CGPoint(x: 500, y: 500), dx: 1, dy: 0)), Decision(passLocally: true))
        XCTAssertEqual(s.handle(.mouseButton(button: 0, down: true, clickCount: 1)), Decision(passLocally: true))
        let t = makeSwitch()
        _ = t.setConnected(false)
        XCTAssertNil(t.virtualScreen)
        XCTAssertEqual(t.handle(.mouseButton(button: 0, down: true, clickCount: 1)), Decision(passLocally: true))
    }

    func testClientCursorFollowsAbsolutePositionsAndKeepsDragging() {
        let c = ClientCursor(desktop: Desktop(displays: [book]))
        _ = c.handle(.enter(x: 2, y: 300))
        _ = c.handle(.mouseButton(button: 0, down: true, clickCount: 1))
        // 没有虚拟屏时拖着推出去不上报；有了才上报
        XCTAssertEqual(c.handle(.mouseMove(dx: -5, dy: 0)).replies, [])
        c.allowsDragOut = true
        XCTAssertEqual(c.handle(.mouseMove(dx: -5, dy: 0)).replies, [.edgePush(x: -5, y: 300)])
        _ = c.handle(.leave)
        XCTAssertEqual(c.handle(.moveTo(x: -420, y: 310)).actions,
                       [.move(to: CGPoint(x: -420, y: 310), dx: -420, dy: 10, dragButton: 0)])
        // 从虚拟屏拖回来进入时保持拖动
        XCTAssertEqual(c.handle(.enter(x: 0, y: 300)).actions,
                       [.move(to: CGPoint(x: 0, y: 300), dx: 0, dy: 0, dragButton: 0)])
    }
}

final class FrameStatsTests: XCTestCase {
    func testRatesGapsAndLatencyPercentiles() {
        var stats = FrameStats()
        // 1 秒内 10 帧，每帧 125000 字节，其中一次卡了 300ms
        let times = [0.0, 0.05, 0.1, 0.15, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7]
        for (i, t) in times.enumerated() { stats.record(at: t, bytes: 125_000, latency: Double(i + 1) / 1000) }
        stats.drop()
        let s = stats.take(now: 1)
        XCTAssertEqual(s.frames, 10)
        XCTAssertEqual(s.fps, 10, accuracy: 0.001)
        XCTAssertEqual(s.mbps, 10, accuracy: 0.001)
        XCTAssertEqual(s.maxGapMs, 300, accuracy: 0.001)
        XCTAssertEqual(s.latencyAvgMs, 5.5, accuracy: 0.001)
        XCTAssertEqual(s.latencyP95Ms, 10, accuracy: 0.001)
        XCTAssertEqual(s.latencyMaxMs, 10, accuracy: 0.001)
        XCTAssertEqual(s.dropped, 1)
    }

    func testTakeResetsAndGapSpansPeriods() {
        var stats = FrameStats()
        stats.record(at: 0, bytes: 1)
        _ = stats.take(now: 1)
        stats.record(at: 1.2, bytes: 1)
        let s = stats.take(now: 2)
        XCTAssertEqual(s.frames, 1)
        XCTAssertEqual(s.maxGapMs, 1200, accuracy: 0.001, "跨统计段的卡顿也要算进去")
        XCTAssertEqual(s.dropped, 0)
    }
}

final class ClockOffsetTests: XCTestCase {
    func testKeepsEstimateFromShortestRoundTrip() {
        var c = ClockOffset()
        // 被控端时钟慢 0.1 秒：慢的那次往返 40ms 估得不准，快的那次 2ms 准
        c.add(sent: 10, clientTime: 9.93, received: 10.04)
        c.add(sent: 20, clientTime: 19.901, received: 20.002)
        c.add(sent: 30, clientTime: 29.95, received: 30.05)
        XCTAssertEqual(c.offset!, -0.1, accuracy: 0.0001)
        XCTAssertEqual(c.bestRoundTrip, 0.002, accuracy: 0.0001)
    }
}
