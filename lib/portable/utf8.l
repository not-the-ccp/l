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
pub fn valid_width(src: const []u8, pos: u64) -> u64 {
    if (pos >= len(src)) {
        return 0;
    }

    var b0 = src[pos];
    if (b0 < 0x80) {
        return 1;
    }

    if (b0 >= 0xc2 && b0 <= 0xdf) {
        if (pos + 2 <= len(src) && continuation(src[pos + 1])) {
            return 2;
        }
        return 1;
    }

    if (b0 == 0xe0) {
        if (pos + 3 <= len(src)) {
            var b1 = src[pos + 1];
            if (b1 >= 0xa0 && b1 <= 0xbf && continuation(src[pos + 2])) {
                return 3;
            }
        }
        return 1;
    }

    if ((b0 >= 0xe1 && b0 <= 0xec) || (b0 >= 0xee && b0 <= 0xef)) {
        if (pos + 3 <= len(src) && continuation(src[pos + 1]) && continuation(src[pos + 2])) {
            return 3;
        }
        return 1;
    }

    if (b0 == 0xed) {
        if (pos + 3 <= len(src)) {
            var b1 = src[pos + 1];
            if (b1 >= 0x80 && b1 <= 0x9f && continuation(src[pos + 2])) {
                return 3;
            }
        }
        return 1;
    }

    if (b0 == 0xf0) {
        if (pos + 4 <= len(src)) {
            var b1 = src[pos + 1];
            if (b1 >= 0x90 && b1 <= 0xbf && continuation(src[pos + 2]) && continuation(src[pos + 3])) {
                return 4;
            }
        }
        return 1;
    }

    if (b0 >= 0xf1 && b0 <= 0xf3) {
        if (pos + 4 <= len(src) && continuation(src[pos + 1]) && continuation(src[pos + 2]) && continuation(src[pos + 3])) {
            return 4;
        }
        return 1;
    }

    if (b0 == 0xf4) {
        if (pos + 4 <= len(src)) {
            var b1 = src[pos + 1];
            if (b1 >= 0x80 && b1 <= 0x8f && continuation(src[pos + 2]) && continuation(src[pos + 3])) {
                return 4;
            }
        }
        return 1;
    }

    return 1;
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
