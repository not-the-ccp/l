import arrays;

pub fn clone(src: const []u8) -> []u8 {
    return arrays.clone(src);
}

pub fn equal(a: const []u8, b: const []u8) -> bool {
    if (len(a) != len(b)) {
        return false;
    }
    for (var i: u64 = 0; i < len(a); i += 1) {
        if (a[i] != b[i]) {
            return false;
        }
    }
    return true;
}

pub fn append(dst: []u8, src: const []u8) {
    for (value in src) {
        push(dst, value);
    }
}

pub fn slice(src: const []u8, start: u64, end: u64) -> []u8 {
    if (start > end || end > len(src)) {
        trap;
    }
    var out: []u8 = [];
    for (var i = start; i < end; i += 1) {
        push(out, src[i]);
    }
    return out;
}

pub fn starts_with(src: const []u8, prefix: const []u8) -> bool {
    if (len(prefix) > len(src)) {
        return false;
    }
    for (var i: u64 = 0; i < len(prefix); i += 1) {
        if (src[i] != prefix[i]) {
            return false;
        }
    }
    return true;
}

pub fn find_byte(src: const []u8, value: u8, start: u64) -> ?u64 {
    var i = start;
    while (i < len(src)) {
        if (src[i] == value) {
            return some(i);
        }
        i += 1;
    }
    return none;
}

pub fn rfind_byte(src: const []u8, value: u8, end: u64) -> ?u64 {
    if (end > len(src)) {
        trap;
    }
    var i = end;
    while (i > 0) {
        i -= 1;
        if (src[i] == value) {
            return some(i);
        }
    }
    return none;
}

pub fn split_byte(src: const []u8, separator: u8) -> []const []u8 {
    var parts: []const []u8 = [];
    var start: u64 = 0;
    for (var i: u64 = 0; i < len(src); i += 1) {
        if (src[i] == separator) {
            push(parts, slice(src, start, i));
            start = i + 1;
        }
    }
    push(parts, slice(src, start, len(src)));
    return parts;
}

pub fn join(parts: const []const []u8, separator: const []u8) -> []u8 {
    var out: []u8 = [];
    for (var i: u64 = 0; i < len(parts); i += 1) {
        if (i != 0) {
            append(out, separator);
        }
        append(out, parts[i]);
    }
    return out;
}

pub fn is_ascii_space(value: u8) -> bool {
    return value == ' ' || value == '\t' || value == '\r' || value == '\n';
}

pub fn trim_ascii(src: const []u8) -> []u8 {
    var start: u64 = 0;
    var end = len(src);
    while (start < end && is_ascii_space(src[start])) {
        start += 1;
    }
    while (end > start && is_ascii_space(src[end - 1])) {
        end -= 1;
    }
    return slice(src, start, end);
}

pub fn replace_range(dst: []u8, start: u64, end: u64, replacement: const []u8) {
    splice(dst, start, end, replacement);
}

pub fn line_start(src: const []u8, offset: u64) -> u64 {
    if (offset > len(src)) {
        trap;
    }
    var p = offset;
    while (p > 0 && src[p - 1] != '\n') {
        p -= 1;
    }
    return p;
}

pub fn line_end(src: const []u8, offset: u64) -> u64 {
    if (offset > len(src)) {
        trap;
    }
    var p = offset;
    while (p < len(src) && src[p] != '\n') {
        p += 1;
    }
    return p;
}

pub fn find(src: const []u8, needle: const []u8, start: u64) -> ?u64 {
    if (start > len(src)) { return none; }
    if (len(needle) == 0) { return some(start); }
    if (len(needle) > len(src) || start > len(src) - len(needle)) { return none; }
    var i = start;
    while (i + len(needle) <= len(src)) {
        var same = true;
        for (var j: u64 = 0; j < len(needle); j += 1) {
            if (src[i + j] != needle[j]) { same = false; break; }
        }
        if (same) { return some(i); }
        i += 1;
    }
    return none;
}

pub fn ends_with(src: const []u8, suffix: const []u8) -> bool {
    if (len(suffix) > len(src)) { return false; }
    var start = len(src) - len(suffix);
    for (var i: u64 = 0; i < len(suffix); i += 1) {
        if (src[start + i] != suffix[i]) { return false; }
    }
    return true;
}
