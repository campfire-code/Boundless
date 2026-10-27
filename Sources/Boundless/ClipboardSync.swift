import AppKit
import BoundlessCore

/// 切换机器时同步剪贴板：文本、富文本、HTML、图片。不同步文件，不同步密码管理器标记为隐藏的内容
final class ClipboardSync {
    private static let types: [NSPasteboard.PasteboardType] = [.string, .rtf, .html, .png, .tiff]
    private static let skipMarkers: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
    ]
    private static let maxBytes = 32 << 20

    private let pasteboard = NSPasteboard.general
    private var syncedChangeCount: Int

    /// syncInitialContents：首次切换时是否同步启动前就已存在的剪贴板内容
    init(syncInitialContents: Bool) {
        syncedChangeCount = syncInitialContents ? -1 : NSPasteboard.general.changeCount
    }

    /// 自上次同步后本机剪贴板有变化才返回内容
    func snapshotIfChanged() -> [ClipboardItem]? {
        guard pasteboard.changeCount != syncedChangeCount else { return nil }
        syncedChangeCount = pasteboard.changeCount
        guard let item = pasteboard.pasteboardItems?.first,
              !ClipboardSync.skipMarkers.contains(where: item.types.contains) else { return nil }

        var items: [ClipboardItem] = []
        var total = 0
        for type in ClipboardSync.types where item.types.contains(type) {
            // 有 PNG 就不再带体积大得多的 TIFF
            if type == .tiff, items.contains(where: { $0.type == NSPasteboard.PasteboardType.png.rawValue }) { continue }
            guard let data = item.data(forType: type) else { continue }
            total += data.count
            items.append(ClipboardItem(type: type.rawValue, data: data))
        }
        guard !items.isEmpty, total <= ClipboardSync.maxBytes else { return nil }
        return items
    }

    func apply(_ items: [ClipboardItem]) {
        guard !items.isEmpty else { return }
        let item = NSPasteboardItem()
        for i in items { item.setData(i.data, forType: .init(i.type)) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        syncedChangeCount = pasteboard.changeCount
    }
}
