import arrays;
import bytes;

fn require(ok: bool) {
    if (!ok) {
        trap;
    }
}

fn require_bytes(actual: const []u8, expected: const []u8) {
    require(bytes.equal(actual, expected));
}

fn require_none(value: ?u64) {
    match (value) {
        none {
            return;
        }
        some(_) {
            trap;
        }
    }
}

fn require_some(value: ?u64, expected: u64) {
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
    var parts = bytes.split_byte(":a::b:", ':');
    require(len(parts) == 5);
    require_bytes(parts[0], "");
    require_bytes(parts[1], "a");
    require_bytes(parts[2], "");
    require_bytes(parts[3], "b");
    require_bytes(parts[4], "");
    require_bytes(bytes.join(parts, ":"), ":a::b:");

    var empty = bytes.split_byte("", ':');
    require(len(empty) == 1);
    require_bytes(empty[0], "");
    require_bytes(bytes.join(empty, ":"), "");

    var literals = ["usr", "local", "bin"];
    require_bytes(bytes.join(literals, "/"), "usr/local/bin");
    var no_parts: []const []u8 = [];
    require_bytes(bytes.join(no_parts, "/"), "");

    require_some(bytes.rfind_byte("a/b/c", '/', 5), 3);
    require_some(bytes.rfind_byte("a/b/c", '/', 3), 1);
    require_none(bytes.rfind_byte("abc", '/', 3));
    require_none(bytes.find("abc", "", 4));
    require_some(bytes.find("abc", "", 3), 3);

    var copy = arrays.clone("abc");
    copy[0] = 'z';
    require_bytes(copy, "zbc");

    return 0;
}
