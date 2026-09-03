struct Item {
    value: u64,
    flags: u64,
}

fn score(item: Item) -> u64 {
    var weighted = item.value;
    if ((item.flags & 1) != 0) {
        weighted += item.value;
    }
    if ((item.flags & 2) != 0) {
        weighted += 10;
    }
    return weighted;
}

fn total(items: []Item) -> u64 {
    var sum: u64 = 0;
    for (item in items) {
        sum += score(item);
    }
    return sum;
}
