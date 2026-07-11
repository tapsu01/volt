import Foundation

/// Trả về đích an toàn cho `name` (một path component do server SFTP cung cấp) dưới `base`,
/// hoặc `nil` nếu `name` không an toàn để ghi cục bộ.
///
/// Đây là chốt chặn cuối cùng chống path traversal tại các sink ghi file: một server độc hại
/// có thể trả về tên entry chứa `/` hoặc `..` để đẩy file ghi ra ngoài thư mục đích.
///
/// Quy tắc: `name` phải là **một** path component hợp lệ — không rỗng, không phải `.`/`..`,
/// không chứa dấu phân tách `/` hay ký tự điều khiển (NUL/control/DEL). Sau khi dựng đích,
/// kiểm tra containment theo **path components** (không so prefix chuỗi, để `/tmp/base2` không
/// bị coi là nằm trong `/tmp/base`).
public func safeLocalDestination(base: URL, name: String) -> URL? {
    guard !name.isEmpty, name != ".", name != ".." else { return nil }
    guard !name.contains("/") else { return nil }
    guard !name.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7f })
    else { return nil }

    let candidate = base.appendingPathComponent(name).standardizedFileURL
    let baseComponents = base.standardizedFileURL.pathComponents
    let candidateComponents = candidate.pathComponents
    // Containment theo path COMPONENTS: đích hợp lệ = base + đúng 1 component.
    guard candidateComponents.count == baseComponents.count + 1,
          Array(candidateComponents.prefix(baseComponents.count)) == baseComponents
    else { return nil }
    return candidate
}
