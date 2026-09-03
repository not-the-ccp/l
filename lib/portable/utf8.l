pub fn continuation(value: u8) -> bool {
    return (value & 0xc0) == 0x80;
}

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

pub fn decode_at(src: const []u8, pos: u64) -> u32 {
    var w = width_at(src, pos);
    if (w == 0) {
        trap;
    }
    var b0 = src[pos] as u32;
    if (w == 1) {
        return b0;
    }
    if (pos + w > len(src)) {
        return 0xfffd;
    }
    if (w == 2) {
        if (!continuation(src[pos + 1])) { return 0xfffd; }
        return ((b0 & 0x1f) << 6) | ((src[pos + 1] as u32) & 0x3f);
    }
    if (w == 3) {
        if (!continuation(src[pos + 1]) || !continuation(src[pos + 2])) { return 0xfffd; }
        return ((b0 & 0x0f) << 12) | (((src[pos + 1] as u32) & 0x3f) << 6) | ((src[pos + 2] as u32) & 0x3f);
    }
    if (!continuation(src[pos + 1]) || !continuation(src[pos + 2]) || !continuation(src[pos + 3])) { return 0xfffd; }
    return ((b0 & 0x07) << 18) | (((src[pos + 1] as u32) & 0x3f) << 12) | (((src[pos + 2] as u32) & 0x3f) << 6) | ((src[pos + 3] as u32) & 0x3f);
}

pub fn valid_width(src: const []u8, pos: u64) -> u64 {
    var w = width_at(src, pos);
    if (w <= 1) { return w; }
    if (pos + w > len(src)) { return 1; }
    var i: u64 = 1;
    while (i < w) {
        if (!continuation(src[pos + i])) { return 1; }
        i += 1;
    }
    return w;
}

pub fn utf16_len(src: const []u8) -> u64 {
    var units: u64 = 0;
    var pos: u64 = 0;
    while (pos < len(src)) {
        var cp = decode_at(src, pos);
        var w = valid_width(src, pos);
        if (cp > 0xffff) { units += 2; } else { units += 1; }
        pos += w;
    }
    return units;
}

pub fn byte_to_utf16(src: const []u8, byte_offset: u64) -> u64 {
    if (byte_offset > len(src)) { trap; }
    var units: u64 = 0;
    var pos: u64 = 0;
    while (pos < byte_offset) {
        var cp = decode_at(src, pos);
        var w = valid_width(src, pos);
        if (pos + w > byte_offset) { break; }
        if (cp > 0xffff) { units += 2; } else { units += 1; }
        pos += w;
    }
    return units;
}

pub fn utf16_to_byte(src: const []u8, units_target: u64) -> u64 {
    var units: u64 = 0;
    var pos: u64 = 0;
    while (pos < len(src) && units < units_target) {
        var cp = decode_at(src, pos);
        var w = valid_width(src, pos);
        var add: u64 = 1;
        if (cp > 0xffff) { add = 2; }
        if (units + add > units_target) { break; }
        units += add;
        pos += w;
    }
    return pos;
}

pub fn append_codepoint(out: []u8, cp: u32) {
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
    if (cp <= 0x10ffff) {
        push(out, (0xf0 | (cp >> 18)) as u8);
        push(out, (0x80 | ((cp >> 12) & 0x3f)) as u8);
        push(out, (0x80 | ((cp >> 6) & 0x3f)) as u8);
        push(out, (0x80 | (cp & 0x3f)) as u8);
        return;
    }
    append_codepoint(out, 0xfffd);
}
