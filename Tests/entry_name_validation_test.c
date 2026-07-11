#include "VoltSSH.h"

#include <stdio.h>
#include <string.h>

// Dùng byte array tường minh thay cho string literal có \x / \0:
// trong C, \x ăn hết chữ số hex kế tiếp ("a\x01b" -> 'a' + MỘT byte 0x1b, sai ý), và \0 phụ thuộc chuỗi.

int main(void) {
    // --- Phải bị từ chối (return 0) ---

    // Con trỏ NULL.
    if (volt_is_safe_entry_name(NULL, 1) != 0) return 1;

    // Độ dài 0.
    if (volt_is_safe_entry_name("", 0) != 0) return 2;

    // Embedded NUL giữa chuỗi.
    const unsigned char nul_name[] = {'a', 0x00, 'b'};
    if (volt_is_safe_entry_name((const char *)nul_name, sizeof(nul_name)) != 0) return 3;

    // Control byte 0x01.
    const unsigned char control_name[] = {'a', 0x01, 'b'};
    if (volt_is_safe_entry_name((const char *)control_name, sizeof(control_name)) != 0) return 4;

    // DEL 0x7f.
    const unsigned char del_name[] = {'a', 0x7f, 'b'};
    if (volt_is_safe_entry_name((const char *)del_name, sizeof(del_name)) != 0) return 5;

    // Chứa dấu phân tách '/'.
    if (volt_is_safe_entry_name("a/b", 3) != 0) return 6;
    if (volt_is_safe_entry_name("../etc", 6) != 0) return 7;

    // --- Buffer KHÔNG kết thúc NUL: validator chỉ được đọc trong [0, len) ---
    // "abc" theo sau bởi rác không NUL; truyền len=3 phải hợp lệ và không đọc quá.
    const unsigned char unterminated[] = {'a', 'b', 'c', '/', 'x'};
    if (volt_is_safe_entry_name((const char *)unterminated, 3) != 1) return 8;
    // Nếu tính cả byte thứ 4 ('/') thì phải reject -> xác nhận validator tôn trọng len.
    if (volt_is_safe_entry_name((const char *)unterminated, 4) != 0) return 9;

    // --- Phải hợp lệ (return 1) ---

    if (volt_is_safe_entry_name("file.txt", 8) != 1) return 10;

    // UTF-8 multibyte hợp lệ: "tài.txt" = t, à(0xC3 0xA0), i, ., t, x, t
    const unsigned char utf8_name[] = {'t', 0xC3, 0xA0, 'i', '.', 't', 'x', 't'};
    if (volt_is_safe_entry_name((const char *)utf8_name, sizeof(utf8_name)) != 1) return 11;

    // "." và ".." là byte-safe nên validator coi HỢP LỆ; việc lọc chúng là của vòng readdir
    // (silent-skip sau khi NUL-terminate), không phải của validator này.
    if (volt_is_safe_entry_name(".", 1) != 1) return 12;
    if (volt_is_safe_entry_name("..", 2) != 1) return 13;

    // Tên chứa dấu chấm nhưng hợp lệ.
    if (volt_is_safe_entry_name("..hidden", 8) != 1) return 14;
    if (volt_is_safe_entry_name("archive.tar.gz", 14) != 1) return 15;

    puts("Entry name validation security test passed.");
    return 0;
}
