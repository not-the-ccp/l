struct Item {
    value: u64,
    flags: u64,
}

fn score(item: Item) -> u64 {
    var result = item.value;
    if ((item.flags & 1) != 0) {
        result += item.value;
    }
    if ((item.flags & 2) != 0) {
        result += 10;
    }
    return result;
}

fn total(items: []Item) -> u64 {
    var result: u64 = 0;
    for (item in items) {
        result += score(item);
    }
    return result;
}
