fn normalize(value: u64) -> u64 {
    return value & 0xff;
}

fn decode(value: u64) -> u64 {
    return value * 3;
}

fn fill(out: []u64) {
    push(out, normalize(decode(10)));
    push(out, 11);
    push(out, normalize(decode(20)));
    push(out, 21);
    push(out, normalize(decode(30)));
    push(out, 31);
    push(out, normalize(decode(40)));
    push(out, 41);
    push(out, normalize(decode(50)));
    push(out, 51);
    push(out, normalize(decode(60)));
    push(out, 61);
}
