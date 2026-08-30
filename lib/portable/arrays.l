pub fn clone[T](src: []T) -> []T {
    var out: []T = [];
    for (item in src) {
        push(out, item);
    }
    return out;
}

pub fn clear[T](items: []T) {
    splice(items, 0, len(items), []);
}

pub fn insert[T](items: []T, index: u64, value: T) {
    if (index > len(items)) { trap; }
    splice(items, index, index, [value]);
}

pub fn remove[T](items: []T, index: u64) -> T {
    if (index >= len(items)) { trap; }
    var old: T = items[index];
    splice(items, index, index + 1, []);
    return old;
}

pub fn truncate[T](items: []T, new_len: u64) {
    if (new_len > len(items)) { trap; }
    splice(items, new_len, len(items), []);
}
