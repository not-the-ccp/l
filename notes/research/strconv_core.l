enum ParseI64 {
    ok(i64);
    invalid;
    overflow;
}

fn is_digit(c: u8) -> bool { return c >= '0' && c <= '9'; }

fn parse_i64(s: []u8) -> ParseI64 {
    if (len(s) == 0) { return ParseI64.invalid(); }
    var negative: bool = false;
    var i: u64 = 0;
    if (s[0] == '-') {
        negative = true;
        i = 1;
        if (i == len(s)) { return ParseI64.invalid(); }
    }
    var magnitude: u64 = 0;
    while (i < len(s)) {
        if (!is_digit(s[i])) { return ParseI64.invalid(); }
        var d: u64 = (s[i] - '0') as u64;
        if (magnitude > 922337203685477580 || (magnitude == 922337203685477580 && d > 8)) {
            return ParseI64.overflow();
        }
        magnitude = magnitude * 10 + d;
        i += 1;
    }
    if (negative) {
        if (magnitude == 9223372036854775808) {
            var min: i64 = -9223372036854775807;
            min -= 1;
            return ParseI64.ok(min);
        }
        return ParseI64.ok(-(magnitude as i64));
    }
    if (magnitude > 9223372036854775807) { return ParseI64.overflow(); }
    return ParseI64.ok(magnitude as i64);
}

fn format_u64(value: u64) -> []u8 {
    if (value == 0) { return "0"; }
    var reversed: []u8 = [];
    var n: u64 = value;
    while (n > 0) {
        push(reversed, ('0' as u64 + n % 10) as u8);
        n /= 10;
    }
    var out: []u8 = [];
    var i: u64 = len(reversed);
    while (i > 0) {
        i -= 1;
        push(out, reversed[i]);
    }
    return out;
}

fn test() -> i64 {
    match (parse_i64("-12345")) {
        ParseI64.ok(v) { if (v != -12345) { return -1; } }
        ParseI64.invalid { return -2; }
        ParseI64.overflow { return -3; }
    }
    var s: []u8 = format_u64(18446744073709551615);
    return len(s) as i64;
}
