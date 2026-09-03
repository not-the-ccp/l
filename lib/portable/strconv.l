const U64_MAX: u64 = 18446744073709551615;

pub fn digit_value(value: u8) -> ?u8 {
    if (value >= '0' && value <= '9') {
        return some(value - '0');
    }
    return none;
}

fn literal_digit_value(value: u8, base: u64) -> ?u8 {
    var digit: u8 = 255;
    if (value >= '0' && value <= '9') {
        digit = value - '0';
    } else if (value >= 'a' && value <= 'f') {
        digit = 10 + value - 'a';
    } else if (value >= 'A' && value <= 'F') {
        digit = 10 + value - 'A';
    } else {
        return none;
    }
    if ((digit as u64) >= base) { return none; }
    return some(digit);
}

// Parse an L integer-literal spelling as an unsigned mathematical magnitude.
// The caller decides whether the magnitude fits its contextual fixed-width type.
// Decimal, hexadecimal, binary, and underscores between digits are accepted;
// magnitudes above u64 are rejected.
pub fn parse_u64_literal(src: const []u8) -> ?u64 {
    if (len(src) == 0) { return none; }

    var base: u64 = 10;
    var i: u64 = 0;
    if (len(src) >= 2 && src[0] == '0') {
        if (src[1] == 'x' || src[1] == 'X') {
            base = 16;
            i = 2;
        } else if (src[1] == 'b' || src[1] == 'B') {
            base = 2;
            i = 2;
        }
    }
    if (i >= len(src)) { return none; }

    var value: u64 = 0;
    var saw_digit = false;
    var previous_digit = false;
    while (i < len(src)) {
        var ch = src[i];
        if (ch == '_') {
            if (!previous_digit || i + 1 >= len(src)) { return none; }
            match (literal_digit_value(src[i + 1], base)) {
                none { return none; }
                some(_) { }
            }
            previous_digit = false;
            i += 1;
            continue;
        }
        match (literal_digit_value(ch, base)) {
            none { return none; }
            some(digit) {
                var d = digit as u64;
                if (value > (U64_MAX - d) / base) { return none; }
                value = value * base + d;
                saw_digit = true;
                previous_digit = true;
            }
        }
        i += 1;
    }
    if (!saw_digit || !previous_digit) { return none; }
    return some(value);
}

pub fn parse_u64(src: const []u8) -> ?u64 {
    if (len(src) == 0) {
        return none;
    }
    var value: u64 = 0;
    for (ch in src) {
        var digit_opt = digit_value(ch);
        match (digit_opt) {
            none {
                return none;
            }
            some(digit) {
                var d = digit as u64;
                if (value > (U64_MAX - d) / 10) {
                    return none;
                }
                value = value * 10 + d;
            }
        }
    }
    return some(value);
}

pub fn append_u64(out: []u8, value: u64) {
    if (value == 0) {
        push(out, '0');
        return;
    }
    var reversed: []u8 = [];
    var n = value;
    while (n > 0) {
        push(reversed, ('0' as u64 + n % 10) as u8);
        n = n / 10;
    }
    var i = len(reversed);
    while (i > 0) {
        i -= 1;
        push(out, reversed[i]);
    }
}

pub fn format_u64(value: u64) -> []u8 {
    var out: []u8 = [];
    append_u64(out, value);
    return out;
}

const I64_MAX_U: u64 = 9223372036854775807;
const I64_MIN_MAG: u64 = 9223372036854775808;

pub fn parse_i64(src: const []u8) -> ?i64 {
    if (len(src) == 0) { return none; }
    var negative = false;
    var start: u64 = 0;
    if (src[0] == '-') {
        negative = true;
        start = 1;
        if (len(src) == 1) { return none; }
    }
    var magnitude: u64 = 0;
    var i = start;
    while (i < len(src)) {
        var digit_opt = digit_value(src[i]);
        match (digit_opt) {
            none { return none; }
            some(digit) {
                var d = digit as u64;
                var limit = I64_MAX_U;
                if (negative) { limit = I64_MIN_MAG; }
                if (magnitude > (limit - d) / 10) { return none; }
                magnitude = magnitude * 10 + d;
            }
        }
        i += 1;
    }
    if (negative) {
        var wrapped = (0 as u64) - magnitude;
        return some(wrapped as i64);
    }
    return some(magnitude as i64);
}

pub fn append_i64(out: []u8, value: i64) {
    if (value < 0) {
        push(out, '-');
        var mag = ((0 as u64) - (value as u64));
        append_u64(out, mag);
        return;
    }
    append_u64(out, value as u64);
}

pub fn format_i64(value: i64) -> []u8 {
    var out: []u8 = [];
    append_i64(out, value);
    return out;
}
