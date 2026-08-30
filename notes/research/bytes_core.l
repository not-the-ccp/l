fn bytes_equal(a: []u8, b: []u8) -> bool {
    if (len(a) != len(b)) { return false; }
    for (var i: u64 = 0; i < len(a); i += 1) {
        if (a[i] != b[i]) { return false; }
    }
    return true;
}

fn starts_with(a: []u8, prefix: []u8) -> bool {
    if (len(prefix) > len(a)) { return false; }
    for (var i: u64 = 0; i < len(prefix); i += 1) {
        if (a[i] != prefix[i]) { return false; }
    }
    return true;
}

fn find_byte(a: []u8, needle: u8) -> ?u64 {
    for (var i: u64 = 0; i < len(a); i += 1) {
        if (a[i] == needle) { return some(i); }
    }
    return none;
}

fn slice_copy(a: []u8, start: u64, end: u64) -> []u8 {
    var out: []u8 = [];
    var i: u64 = start;
    while (i < end) {
        push(out, a[i]);
        i += 1;
    }
    return out;
}

fn concat(a: []u8, b: []u8) -> []u8 {
    var out: []u8 = copy(a);
    for (var i: u64 = 0; i < len(b); i += 1) { push(out, b[i]); }
    return out;
}

fn split_byte(a: []u8, sep: u8) -> [][]u8 {
    var out: [][]u8 = [];
    var start: u64 = 0;
    var i: u64 = 0;
    while (i < len(a)) {
        if (a[i] == sep) {
            push(out, slice_copy(a, start, i));
            start = i + 1;
        }
        i += 1;
    }
    push(out, slice_copy(a, start, len(a)));
    return out;
}

fn test() -> i64 {
    var parts: [][]u8 = split_byte("a,bc,d", ',');
    if (!bytes_equal(parts[0], "a")) { return -1; }
    if (!bytes_equal(parts[1], "bc")) { return -2; }
    if (!starts_with(concat(parts[1], parts[2]), "bcd")) { return -3; }
    var f: ?u64 = find_byte("abc", 'b');
    if (f is some(i)) { return i as i64; }
    return -4;
}
