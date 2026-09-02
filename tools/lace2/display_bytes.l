import bytes;

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

fn continuation(value: u8) -> bool {
    return (value & 0xc0) == 0x80;
}

fn strict_utf8_width(src: []u8, pos: u64) -> u64 {
    if (pos >= len(src)) { return 0; }
    var b0 = src[pos];
    if (b0 < 0x80) { return 1; }

    if (b0 >= 0xc2 && b0 <= 0xdf) {
        if (pos + 2 > len(src)) { return 0; }
        if (!continuation(src[pos + 1])) { return 0; }
        return 2;
    }

    if (b0 == 0xe0) {
        if (pos + 3 > len(src)) { return 0; }
        var b1 = src[pos + 1];
        if (b1 < 0xa0 || b1 > 0xbf || !continuation(src[pos + 2])) { return 0; }
        return 3;
    }

    if ((b0 >= 0xe1 && b0 <= 0xec) || (b0 >= 0xee && b0 <= 0xef)) {
        if (pos + 3 > len(src)) { return 0; }
        if (!continuation(src[pos + 1]) || !continuation(src[pos + 2])) { return 0; }
        return 3;
    }

    if (b0 == 0xed) {
        if (pos + 3 > len(src)) { return 0; }
        var b1 = src[pos + 1];
        if (b1 < 0x80 || b1 > 0x9f || !continuation(src[pos + 2])) { return 0; }
        return 3;
    }

    if (b0 == 0xf0) {
        if (pos + 4 > len(src)) { return 0; }
        var b1 = src[pos + 1];
        if (b1 < 0x90 || b1 > 0xbf) { return 0; }
        if (!continuation(src[pos + 2]) || !continuation(src[pos + 3])) { return 0; }
        return 4;
    }

    if (b0 >= 0xf1 && b0 <= 0xf3) {
        if (pos + 4 > len(src)) { return 0; }
        if (!continuation(src[pos + 1]) || !continuation(src[pos + 2]) || !continuation(src[pos + 3])) { return 0; }
        return 4;
    }

    if (b0 == 0xf4) {
        if (pos + 4 > len(src)) { return 0; }
        var b1 = src[pos + 1];
        if (b1 < 0x80 || b1 > 0x8f) { return 0; }
        if (!continuation(src[pos + 2]) || !continuation(src[pos + 3])) { return 0; }
        return 4;
    }

    return 0;
}

fn decode_valid(src: []u8, pos: u64, width: u64) -> u32 {
    var b0 = src[pos] as u32;
    if (width == 1) { return b0; }
    if (width == 2) {
        return ((b0 & 0x1f) << 6) | ((src[pos + 1] as u32) & 0x3f);
    }
    if (width == 3) {
        return ((b0 & 0x0f) << 12) |
            (((src[pos + 1] as u32) & 0x3f) << 6) |
            ((src[pos + 2] as u32) & 0x3f);
    }
    return ((b0 & 0x07) << 18) |
        (((src[pos + 1] as u32) & 0x3f) << 12) |
        (((src[pos + 2] as u32) & 0x3f) << 6) |
        ((src[pos + 3] as u32) & 0x3f);
}

fn unicode_control(cp: u32) -> bool {
    if (cp >= 0x80 && cp <= 0x9f) { return true; }
    if (cp == 0x200e || cp == 0x200f) { return true; }
    if (cp >= 0x202a && cp <= 0x202e) { return true; }
    if (cp >= 0x2066 && cp <= 0x2069) { return true; }
    if (cp == 0xfeff) { return true; }
    return false;
}

pub fn next_unit(src: []u8, pos: u64) -> Unit {
    if (pos >= len(src)) { trap; }
    var b = src[pos];

    if (b == '\n') {
        return Unit { start: pos, end: pos + 1, kind: UnitKind.line_break, codepoint: 10 };
    }
    if (b == '\t') {
        return Unit { start: pos, end: pos + 1, kind: UnitKind.tab, codepoint: 9 };
    }
    if (b < 0x20 || b == 0x7f) {
        return Unit { start: pos, end: pos + 1, kind: UnitKind.control, codepoint: b as u32 };
    }

    var width = strict_utf8_width(src, pos);
    if (width == 0) {
        return Unit { start: pos, end: pos + 1, kind: UnitKind.invalid_byte, codepoint: b as u32 };
    }

    var cp = decode_valid(src, pos, width);
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
        var digit = ((value >> (shift as u32)) & 0x0f) as u8;
        if (digit != 0 || started || shift == 0) {
            push(out, hex_digit(digit));
            started = true;
        }
        shift -= 4;
    }
}

pub fn representation(src: []u8, unit: Unit) -> []u8 {
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

pub fn render_debug(src: []u8) -> []u8 {
    var out: []u8 = [];
    var pos: u64 = 0;
    while (pos < len(src)) {
        var unit = next_unit(src, pos);
        var repr = representation(src, unit);
        bytes.append(out, repr);
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

pub fn parse_byte_hex(value: []u8) -> ?u8 {
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
