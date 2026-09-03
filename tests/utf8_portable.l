import bytes;
import utf8;

fn require(ok: bool) {
    if (!ok) {
        trap;
    }
}

fn main() -> i64 {
    var ascii: []u8 = "hello";
    require(utf8.valid(ascii));
    require(utf8.valid_width(ascii, 0) == 1);
    require(utf8.decode_at(ascii, 1) == 'e' as u32);

    var two: []u8 = [0xc3, 0xa9];
    var three: []u8 = [0xe2, 0x82, 0xac];
    var four: []u8 = [0xf0, 0x9f, 0x98, 0x80];
    require(utf8.valid(two));
    require(utf8.valid(three));
    require(utf8.valid(four));
    require(utf8.valid_width(two, 0) == 2);
    require(utf8.valid_width(three, 0) == 3);
    require(utf8.valid_width(four, 0) == 4);
    require(utf8.decode_at(two, 0) == 0x00e9);
    require(utf8.decode_at(three, 0) == 0x20ac);
    require(utf8.decode_at(four, 0) == 0x1f600);

    // Overlong encodings, UTF-16 surrogate scalars, codepoints above U+10FFFF,
    // lone continuation bytes, and truncated sequences are all malformed.
    var overlong: []u8 = [0xc0, 0x80];
    var surrogate: []u8 = [0xed, 0xa0, 0x80];
    var above_max: []u8 = [0xf4, 0x90, 0x80, 0x80];
    var continuation: []u8 = [0x80];
    var truncated: []u8 = [0xe2, 0x82];
    require(!utf8.valid(overlong));
    require(!utf8.valid(surrogate));
    require(!utf8.valid(above_max));
    require(!utf8.valid(continuation));
    require(!utf8.valid(truncated));
    require(utf8.valid_width(overlong, 0) == 1);
    require(utf8.valid_width(surrogate, 0) == 1);
    require(utf8.valid_width(above_max, 0) == 1);
    require(utf8.valid_width(truncated, 0) == 1);
    require(utf8.decode_at(overlong, 0) == 0xfffd);
    require(utf8.decode_at(surrogate, 0) == 0xfffd);

    var mixed: []u8 = ['a', 0xf0, 0x9f, 0x98, 0x80, 'b'];
    require(utf8.next_boundary(mixed, 0) == 1);
    require(utf8.next_boundary(mixed, 1) == 5);
    require(utf8.next_boundary(mixed, 5) == 6);
    require(utf8.next_boundary(mixed, 6) == 6);
    require(utf8.previous_boundary(mixed, 6) == 5);
    require(utf8.previous_boundary(mixed, 5) == 1);
    require(utf8.previous_boundary(mixed, 1) == 0);
    require(utf8.previous_boundary(mixed, 0) == 0);

    // Malformed bytes remain individually reachable instead of being swallowed
    // as a fake multibyte scalar.
    require(utf8.next_boundary(overlong, 0) == 1);
    require(utf8.next_boundary(overlong, 1) == 2);
    require(utf8.previous_boundary(overlong, 2) == 1);
    require(utf8.previous_boundary(overlong, 1) == 0);

    require(utf8.utf16_len(four) == 2);
    require(utf8.byte_to_utf16(mixed, 5) == 3);
    require(utf8.utf16_to_byte(mixed, 3) == 5);
    require(utf8.utf16_len(overlong) == 2);

    var encoded: []u8 = [];
    utf8.append_codepoint(encoded, 0x1f600);
    require(bytes.equal(encoded, four));

    var replacement: []u8 = [];
    utf8.append_codepoint(replacement, 0xd800);
    require(bytes.equal(replacement, [0xef, 0xbf, 0xbd]));
    var replacement2: []u8 = [];
    utf8.append_codepoint(replacement2, 0x110000);
    require(bytes.equal(replacement2, [0xef, 0xbf, 0xbd]));

    return 0;
}
