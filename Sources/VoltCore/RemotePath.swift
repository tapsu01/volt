import Foundation

/// Thao tác chuỗi thuần trên đường dẫn REMOTE (SFTP).
///
/// Không bao giờ dùng `URL(fileURLWithPath:)` cho path remote: Foundation sẽ `stat()` path đó trên
/// máy Mac để đoán có phải thư mục không. Với path dạng `/home/<tên>` macOS kích hoạt autofs
/// (`auto_home`), mỗi lần mất ~100ms và chặn main thread khi chạy trong lúc render.
public enum RemotePath {
    /// Thành phần cuối của path. `"/"` trả về `"/"`; path rỗng trả về `""`.
    public static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Thư mục cha. Gốc hoặc path một cấp trả về `"/"`.
    public static func parent(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    /// Ghép `child` dưới `base`. Giữ nguyên hành vi `joinRemote` cũ của `AppModel`.
    public static func join(_ base: String, _ child: String) -> String {
        if base == "/" { return "/" + child }
        return "/" + base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + child
    }

    /// Phần mở rộng (không có dấu chấm), rỗng nếu không có.
    public static func fileExtension(_ path: String) -> String {
        (path as NSString).pathExtension
    }
}
