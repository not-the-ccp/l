fn normalize(value: i64, limit: i64) -> i64 {
    var scaled = value * 3;
    return clamp(scaled, 0, limit);
}

fn distance(a: i64, b: i64) -> i64 {
    if (a > b) {
        return a - b;
    }
    return b - a;
}

fn clamp(value: i64, low: i64, high: i64) -> i64 {
    if (value < low) {
        return low;
    }
    if (value > high) {
        return high;
    }
    return value;
}

fn score(a: i64, b: i64) -> i64 {
    return normalize(distance(a, b), 100);
}
