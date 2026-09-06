import bytes;
import utf8;

// Classification for presenting arbitrary bytes to a human without letting the
// byte stream become terminal/control protocol. Valid printable UTF-8 is passed
// through; everything unsafe remains representable and reversible by position.
pub enum UnitKind {
    text,
    tab,
    line_break,
    control,
    invalid_byte,
    unicode_control,
}

pub struct Unit {
    pub start: u64,
    pub end: u64,
    pub kind: UnitKind,
    pub codepoint: u32,
}

fn unicode_control(cp: u32) -> bool {
    if (cp >= 0x80 && cp <= 0x9f) { return true; }
    if (cp == 0x200e || cp == 0x200f) { return true; }
    if (cp >= 0x202a && cp <= 0x202e) { return true; }
    if (cp >= 0x2066 && cp <= 0x2069) { return true; }
    if (cp == 0xfeff) { return true; }
    return false;
}

pub fn next_unit(src: const []u8, pos: u64) -> Unit {
    if (pos >= len(src)) { trap; }
    var value = src[pos];

    if (value == '\n') {
        return Unit { start: pos, end: pos + 1, kind: UnitKind.line_break, codepoint: 10 };
    }
    if (value == '\t') {
        return Unit { start: pos, end: pos + 1, kind: UnitKind.tab, codepoint: 9 };
    }
    if (value < 0x20 || value == 0x7f) {
        return Unit { start: pos, end: pos + 1, kind: UnitKind.control, codepoint: value as u32 };
    }

    var width = utf8.valid_width(src, pos);
    if (width == 1 && value >= 0x80) {
        return Unit { start: pos, end: pos + 1, kind: UnitKind.invalid_byte, codepoint: value as u32 };
    }

    var cp = utf8.decode_at(src, pos);
    if (unicode_control(cp)) {
        return Unit { start: pos, end: pos + width, kind: UnitKind.unicode_control, codepoint: cp };
    }
    return Unit { start: pos, end: pos + width, kind: UnitKind.text, codepoint: cp };
}

fn hex_digit(value: u8) -> u8 {
    if (value < 10) { return '0' + value; }
    return 'A' + (value - 10);
}

fn append_hex_byte(out: []u8, value: u8) {
    push(out, hex_digit(value >> 4));
    push(out, hex_digit(value & 0x0f));
}

fn append_hex_u32(out: []u8, value: u32) {
    var shift: i64 = 28;
    var started = false;
    while (shift >= 0) {
        var digit = ((value >> (shift as u64)) & 0x0f) as u8;
        if (digit != 0 || started || shift == 0) {
            push(out, hex_digit(digit));
            started = true;
        }
        shift -= 4;
    }
}

// Human-safe one-unit representation. `text` is the only case that can copy
// source bytes verbatim, and it has already passed strict UTF-8/control checks.
pub fn representation(src: const []u8, unit: Unit) -> []u8 {
    if (unit.start >= unit.end || unit.end > len(src)) { trap; }

    if (unit.kind is UnitKind.text) {
        return bytes.slice(src, unit.start, unit.end);
    }
    if (unit.kind is UnitKind.tab) { return "<TAB>"; }
    if (unit.kind is UnitKind.line_break) { return "<LF>"; }
    if (unit.kind is UnitKind.control) {
        var out: []u8 = ['^'];
        var value = unit.codepoint as u8;
        if (value == 0x7f) { push(out, '?'); }
        else { push(out, value + 0x40); }
        return out;
    }
    if (unit.kind is UnitKind.invalid_byte) {
        var out: []u8 = ['<'];
        append_hex_byte(out, unit.codepoint as u8);
        push(out, '>');
        return out;
    }

    var out: []u8 = "<U+";
    append_hex_u32(out, unit.codepoint);
    push(out, '>');
    return out;
}

pub fn render_safe(src: const []u8) -> []u8 {
    var out: []u8 = [];
    var pos: u64 = 0;
    while (pos < len(src)) {
        var unit = next_unit(src, pos);
        bytes.append(out, representation(src, unit));
        pos = unit.end;
    }
    return out;
}

fn parse_hex_digit(value: u8) -> ?u8 {
    if (value >= '0' && value <= '9') { return some(value - '0'); }
    if (value >= 'a' && value <= 'f') { return some(10 + value - 'a'); }
    if (value >= 'A' && value <= 'F') { return some(10 + value - 'A'); }
    return none;
}

pub fn parse_byte_hex(value: const []u8) -> ?u8 {
    if (len(value) != 2) { return none; }
    var hi_opt = parse_hex_digit(value[0]);
    var lo_opt = parse_hex_digit(value[1]);
    match (hi_opt) {
        none { return none; }
        some(hi) {
            match (lo_opt) {
                none { return none; }
                some(lo) { return some((hi << 4) | lo); }
            }
        }
    }
}
