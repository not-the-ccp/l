fn swap[T](a: []T, i: u64, j: u64) {
    var temp: T = a[i];
    a[i] = a[j];
    a[j] = temp;
}

fn reverse[T](a: []T) {
    var left: u64 = 0;
    var right: u64 = len(a);
    while (left < right) {
        right -= 1;
        if (left >= right) { break; }
        swap(a, left, right);
        left += 1;
    }
}

fn last[T](a: []T) -> ?T {
    if (len(a) == 0) { return none; }
    return some(a[len(a) - 1]);
}

struct P { x: i64; }

fn test() -> i64 {
    var ints: []i64 = [1, 2, 3, 4];
    reverse(ints);
    var bytes: []u8 = "abc";
    reverse(bytes);
    var ps: []P = [P { x: 5 }, P { x: 7 }];
    reverse(ps);
    var answer: i64 = ints[0] * 100 + (bytes[0] as i64) + ps[0].x;
    var maybe_last: ?i64 = last(ints);
    if (maybe_last is some(v)) { return answer + v; }
    return -1;
}
