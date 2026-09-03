pub fn continuation(value: u8) -> bool {
    return (value & 0xc0) == 0x80;
}

// Return the nominal byte width implied by the leading byte. This is a lexical
// helper only; use valid_width() when walking arbitrary bytes.
pub fn width_at(src: const []u8, pos: u64) -> u64 {
    if (pos >= len(src)) {
        return 0;
    }
    var b = src[pos];
    if (b < 0x80) {
        return 1;
    }
    if ((b & 0xe0) == 0xc0) {
        return 2;
    }
    if ((b & 0xf0) == 0xe0) {
        return 3;
    }
    if ((b & 0xf8) == 0xf0) {
        return 4;
    }
    return 1;
}

// Return the width of one valid UTF-8 scalar starting at pos. Invalid or
// truncated input deliberately consumes one byte so callers can preserve and
// navigate arbitrary byte strings without getting stuck or swallowing bytes.
pub fn valid_scalar_width(
    b0: u8,
    b1: u8,
    b2: u8,
    b3: u8,
    available: u64
) -> u64 {
    if (available == 0) { return 0; }
    if (b0 < 0x80) { return 1; }

    if (b0 >= 0xc2 && b0 <= 0xdf) {
        if (available >= 2 && continuation(b1)) { return 2; }
        return 1;
    }
    if (b0 == 0xe0) {
        if (available >= 3 && b1 >= 0xa0 && b1 <= 0xbf && continuation(b2)) { return 3; }
        return 1;
    }
    if ((b0 >= 0xe1 && b0 <= 0xec) || (b0 >= 0xee && b0 <= 0xef)) {
        if (available >= 3 && continuation(b1) && continuation(b2)) { return 3; }
        return 1;
    }
    if (b0 == 0xed) {
        if (available >= 3 && b1 >= 0x80 && b1 <= 0x9f && continuation(b2)) { return 3; }
        return 1;
    }
    if (b0 == 0xf0) {
        if (available >= 4 && b1 >= 0x90 && b1 <= 0xbf && continuation(b2) && continuation(b3)) { return 4; }
        return 1;
    }
    if (b0 >= 0xf1 && b0 <= 0xf3) {
        if (available >= 4 && continuation(b1) && continuation(b2) && continuation(b3)) { return 4; }
        return 1;
    }
    if (b0 == 0xf4) {
        if (available >= 4 && b1 >= 0x80 && b1 <= 0x8f && continuation(b2) && continuation(b3)) { return 4; }
        return 1;
    }
    return 1;
}

// Validate one scalar from a contiguous byte slice. The scalar-level
// primitive above is also usable by ropes, streams and piece tables
// that can cheaply fetch a four-byte lookahead without allocating.
pub fn valid_width(src: const []u8, pos: u64) -> u64 {
    if (pos >= len(src)) { return 0; }
    var available = len(src) - pos;
    if (available > 4) { available = 4; }
    var b1: u8 = 0;
    var b2: u8 = 0;
    var b3: u8 = 0;
    if (available > 1) { b1 = src[pos + 1]; }
    if (available > 2) { b2 = src[pos + 2]; }
    if (available > 3) { b3 = src[pos + 3]; }
    return valid_scalar_width(src[pos], b1, b2, b3, available);
}

pub fn valid(src: const []u8) -> bool {
    var pos: u64 = 0;
    while (pos < len(src)) {
        var width = valid_width(src, pos);
        if (width == 1 && src[pos] >= 0x80) {
            return false;
        }
        pos += width;
    }
    return true;
}

pub fn decode_at(src: const []u8, pos: u64) -> u32 {
    if (pos >= len(src)) {
        trap;
    }

    var b0 = src[pos];
    if (b0 < 0x80) {
        return b0 as u32;
    }

    var width = valid_width(src, pos);
    if (width == 1) {
        return 0xfffd;
    }

    var x0 = b0 as u32;
    if (width == 2) {
        return ((x0 & 0x1f) << 6) | ((src[pos + 1] as u32) & 0x3f);
    }
    if (width == 3) {
        return ((x0 & 0x0f) << 12) | (((src[pos + 1] as u32) & 0x3f) << 6) | ((src[pos + 2] as u32) & 0x3f);
    }
    return ((x0 & 0x07) << 18) | (((src[pos + 1] as u32) & 0x3f) << 12) | (((src[pos + 2] as u32) & 0x3f) << 6) | ((src[pos + 3] as u32) & 0x3f);
}

pub fn next_boundary(src: const []u8, pos: u64) -> u64 {
    if (pos > len(src)) {
        trap;
    }
    if (pos == len(src)) {
        return pos;
    }
    return pos + valid_width(src, pos);
}

pub fn previous_boundary(src: const []u8, pos: u64) -> u64 {
    if (pos > len(src)) {
        trap;
    }
    if (pos == 0) {
        return 0;
    }

    var candidate = pos - 1;
    var steps: u64 = 0;
    while (candidate > 0 && continuation(src[candidate]) && steps < 3) {
        candidate -= 1;
        steps += 1;
    }
    if (next_boundary(src, candidate) == pos) {
        return candidate;
    }
    return pos - 1;
}

pub fn utf16_len(src: const []u8) -> u64 {
    var units: u64 = 0;
    var pos: u64 = 0;
    while (pos < len(src)) {
        var cp = decode_at(src, pos);
        var width = valid_width(src, pos);
        if (cp > 0xffff) {
            units += 2;
        } else {
            units += 1;
        }
        pos += width;
    }
    return units;
}

pub fn byte_to_utf16(src: const []u8, byte_offset: u64) -> u64 {
    if (byte_offset > len(src)) {
        trap;
    }
    var units: u64 = 0;
    var pos: u64 = 0;
    while (pos < byte_offset) {
        var cp = decode_at(src, pos);
        var width = valid_width(src, pos);
        if (pos + width > byte_offset) {
            break;
        }
        if (cp > 0xffff) {
            units += 2;
        } else {
            units += 1;
        }
        pos += width;
    }
    return units;
}

pub fn utf16_to_byte(src: const []u8, units_target: u64) -> u64 {
    var units: u64 = 0;
    var pos: u64 = 0;
    while (pos < len(src) && units < units_target) {
        var cp = decode_at(src, pos);
        var width = valid_width(src, pos);
        var add: u64 = 1;
        if (cp > 0xffff) {
            add = 2;
        }
        if (units + add > units_target) {
            break;
        }
        units += add;
        pos += width;
    }
    return pos;
}

pub fn append_codepoint(out: []u8, cp: u32) {
    if (cp >= 0xd800 && cp <= 0xdfff) {
        append_codepoint(out, 0xfffd);
        return;
    }
    if (cp > 0x10ffff) {
        append_codepoint(out, 0xfffd);
        return;
    }
    if (cp <= 0x7f) {
        push(out, cp as u8);
        return;
    }
    if (cp <= 0x7ff) {
        push(out, (0xc0 | (cp >> 6)) as u8);
        push(out, (0x80 | (cp & 0x3f)) as u8);
        return;
    }
    if (cp <= 0xffff) {
        push(out, (0xe0 | (cp >> 12)) as u8);
        push(out, (0x80 | ((cp >> 6) & 0x3f)) as u8);
        push(out, (0x80 | (cp & 0x3f)) as u8);
        return;
    }
    push(out, (0xf0 | (cp >> 18)) as u8);
    push(out, (0x80 | ((cp >> 12) & 0x3f)) as u8);
    push(out, (0x80 | ((cp >> 6) & 0x3f)) as u8);
    push(out, (0x80 | (cp & 0x3f)) as u8);
}
