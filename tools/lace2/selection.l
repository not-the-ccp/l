import arrays;

pub struct Range {
    pub anchor: u64,
    pub head: u64,
}

pub struct Set {
    pub ranges: []Range,
    pub primary: u64,
}

pub fn range_start(range: Range) -> u64 {
    if (range.anchor < range.head) { return range.anchor; }
    return range.head;
}

pub fn range_end(range: Range) -> u64 {
    if (range.anchor > range.head) { return range.anchor; }
    return range.head;
}

pub fn range_reversed(range: Range) -> bool {
    return range.head < range.anchor;
}

pub fn single(pos: u64) -> Set {
    return Set {
        ranges: [Range { anchor: pos, head: pos }],
        primary: 0,
    };
}

pub fn clone(set: Set) -> Set {
    return Set {
        ranges: arrays.clone(set.ranges),
        primary: set.primary,
    };
}

pub fn validate(set: Set, byte_len: u64) {
    if (len(set.ranges) == 0) { trap; }
    if (set.primary >= len(set.ranges)) { trap; }
    for (range in set.ranges) {
        if (range.anchor > byte_len || range.head > byte_len) { trap; }
    }
}

fn range_less(a: Range, b: Range) -> bool {
    var as = range_start(a);
    var bs = range_start(b);
    if (as < bs) { return true; }
    if (as > bs) { return false; }
    return range_end(a) < range_end(b);
}

pub fn sort_by_position(set: ref Set) {
    var old_primary = set.ranges[set.primary];
    for (var i: u64 = 1; i < len(set.ranges); i += 1) {
        var value = set.ranges[i];
        var j = i;
        while (j > 0 && range_less(value, set.ranges[j - 1])) {
            set.ranges[j] = set.ranges[j - 1];
            j -= 1;
        }
        set.ranges[j] = value;
    }

    for (var i: u64 = 0; i < len(set.ranges); i += 1) {
        var range = set.ranges[i];
        if (range.anchor == old_primary.anchor && range.head == old_primary.head) {
            set.primary = i;
            return;
        }
    }
    set.primary = 0;
}

pub fn merge_overlaps(set: ref Set) {
    sort_by_position(set);
    if (len(set.ranges) < 2) { return; }

    var out: []Range = [];
    var current = set.ranges[0];
    for (var i: u64 = 1; i < len(set.ranges); i += 1) {
        var next = set.ranges[i];
        var current_end = range_end(current);
        var next_start = range_start(next);
        if (next_start <= current_end) {
            var merged_start = range_start(current);
            var merged_end = range_end(next);
            if (range_end(current) > merged_end) { merged_end = range_end(current); }
            current = Range { anchor: merged_start, head: merged_end };
        } else {
            push(out, current);
            current = next;
        }
    }
    push(out, current);
    set.ranges = out;
    if (set.primary >= len(set.ranges)) { set.primary = len(set.ranges) - 1; }
}
