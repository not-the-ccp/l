import algorithms;
import strconv;
import utf8;

fn require(ok: bool) {
    if (!ok) {
        trap;
    }
}

fn equal_i64(a: i64, b: i64) -> bool {
    return a == b;
}

fn require_u64(value: ?u64, expected: u64) {
    match (value) {
        some(actual) {
            require(actual == expected);
            return;
        }
        none {
            trap;
        }
    }
}

fn require_i64(value: ?i64, expected: i64) {
    match (value) {
        some(actual) {
            require(actual == expected);
            return;
        }
        none {
            trap;
        }
    }
}

fn main() -> i64 {
    var values: const []i64 = [2, 4, 6];
    require(algorithms.contains_by(values, 4, equal_i64));
    require(!algorithms.contains_by(values, 5, equal_i64));
    require(algorithms.equal_by(values, [2, 4, 6], equal_i64));

    require_u64(strconv.parse_u64("18446744073709551615"), 18446744073709551615);
    require_i64(strconv.parse_i64("-9223372036854775808"), -9223372036854775808);

    require(utf8.width_at("abc", 0) == 1);
    require(utf8.decode_at("abc", 1) == 'b' as u32);
    require(utf8.utf16_len("abc") == 3);
    require(utf8.byte_to_utf16("abc", 2) == 2);
    require(utf8.utf16_to_byte("abc", 2) == 2);

    return 0;
}
