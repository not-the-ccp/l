import arrays;

pub enum Bias { before, after }

pub struct Point {
    pub offset: u64,
    pub bias: Bias,
}

pub struct Range {
    pub anchor: Point,
    pub head: Point,
}

pub struct Set {
    pub ranges: []Range,
    pub primary: u64,
}

pub fn point(offset: u64, bias: Bias) -> Point {
    return Point { offset: offset, bias: bias };
}

pub fn cursor(pos: u64, bias: Bias) -> Range {
    var p = point(pos, bias);
    return Range { anchor: p, head: p };
}

pub fn range(anchor: u64, head: u64) -> Range {
    if (anchor == head) { return cursor(anchor, Bias.after); }
    if (anchor < head) {
        return Range {
            anchor: point(anchor, Bias.after),
            head: point(head, Bias.before),
        };
    }
    return Range {
        anchor: point(anchor, Bias.before),
        head: point(head, Bias.after),
    };
}

pub fn range_start(value: Range) -> u64 {
    if (value.anchor.offset < value.head.offset) { return value.anchor.offset; }
    return value.head.offset;
}

pub fn range_end(value: Range) -> u64 {
    if (value.anchor.offset > value.head.offset) { return value.anchor.offset; }
    return value.head.offset;
}

pub fn range_reversed(value: Range) -> bool {
    return value.head.offset < value.anchor.offset;
}

pub fn range_empty(value: Range) -> bool {
    return value.anchor.offset == value.head.offset;
}

pub fn single(pos: u64) -> Set {
    return Set {
        ranges: [cursor(pos, Bias.after)],
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
    for (value in set.ranges) {
        if (value.anchor.offset > byte_len || value.head.offset > byte_len) { trap; }
    }
}

fn range_less(a: Range, b: Range) -> bool {
    var a_start = range_start(a);
    var b_start = range_start(b);
    if (a_start < b_start) { return true; }
    if (a_start > b_start) { return false; }
    return range_end(a) < range_end(b);
}

fn same_range(a: Range, b: Range) -> bool {
    return a.anchor.offset == b.anchor.offset &&
        a.anchor.bias == b.anchor.bias &&
        a.head.offset == b.head.offset &&
        a.head.bias == b.head.bias;
}

pub fn sorted(set: Set) -> Set {
    var out = clone(set);
    var old_primary = out.ranges[out.primary];
    for (var i: u64 = 1; i < len(out.ranges); i += 1) {
        var value = out.ranges[i];
        var j = i;
        while (j > 0 && range_less(value, out.ranges[j - 1])) {
            out.ranges[j] = out.ranges[j - 1];
            j -= 1;
        }
        out.ranges[j] = value;
    }

    for (var i: u64 = 0; i < len(out.ranges); i += 1) {
        if (same_range(out.ranges[i], old_primary)) {
            out.primary = i;
            return out;
        }
    }
    out.primary = 0;
    return out;
}

pub fn merged(set: Set) -> Set {
    var ordered = sorted(set);
    if (len(ordered.ranges) < 2) { return ordered; }

    var out: []Range = [];
    var current = ordered.ranges[0];
    for (var i: u64 = 1; i < len(ordered.ranges); i += 1) {
        var next = ordered.ranges[i];
        var current_end = range_end(current);
        var next_start = range_start(next);
        var should_merge = next_start < current_end;
        if (range_empty(next) && next_start == current_end) { should_merge = true; }
        if (should_merge) {
            var merged_start = range_start(current);
            var merged_end = range_end(next);
            if (range_end(current) > merged_end) { merged_end = range_end(current); }
            current = range(merged_start, merged_end);
        } else {
            push(out, current);
            current = next;
        }
    }
    push(out, current);
    var primary = ordered.primary;
    if (primary >= len(out)) { primary = len(out) - 1; }
    return Set { ranges: out, primary: primary };
}
