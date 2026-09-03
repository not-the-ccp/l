fn emit(value: i64, flags: u64, limit: u64) -> i64 {
    if (flags == 0) {
        return value;
    }
    return value + (limit as i64);
}

fn pair(a: i64, b: i64) -> i64 {
    return a * 100 + b;
}

fn trim(value: i64) -> i64 {
    return value % 100;
}

fn build(left: i64, right: i64, flags: u64, limit: u64) -> i64 {
    return emit(pair(trim(right), trim(left)), limit, flags);
}
