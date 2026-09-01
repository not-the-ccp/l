// Portable generic algorithms over L's built-in dynamic arrays.
// Behavior such as equality/order is supplied explicitly as function values.

fn swap[T](items: []T, a: u64, b: u64) {
    if (a == b) {
        return;
    }
    var temp: T = items[a];
    items[a] = items[b];
    items[b] = temp;
}

pub fn reverse[T](items: []T) {
    var left: u64 = 0;
    var right = len(items);
    while (left < right) {
        right -= 1;
        if (left >= right) {
            return;
        }
        swap(items, left, right);
        left += 1;
    }
}

pub fn find_by[T](items: []T, value: T, equal: fn(T, T) -> bool) -> ?u64 {
    for (var i: u64 = 0; i < len(items); i += 1) {
        if (equal(items[i], value)) {
            return some(i);
        }
    }
    return none;
}

pub fn contains_by[T](items: []T, value: T, equal: fn(T, T) -> bool) -> bool {
    match (find_by(items, value, equal)) {
        none { return false; }
        some(_) { return true; }
    }
}

pub fn equal_by[T](a: []T, b: []T, equal: fn(T, T) -> bool) -> bool {
    if (len(a) != len(b)) {
        return false;
    }
    for (var i: u64 = 0; i < len(a); i += 1) {
        if (!equal(a[i], b[i])) {
            return false;
        }
    }
    return true;
}

// Restore a max-heap rooted at `start` within items[0..count), where `less`
// defines the desired ascending order.
fn sort_sift_down[T](items: []T, start: u64, count: u64, less: fn(T, T) -> bool) {
    var root = start;
    while (root < count / 2) {
        var child = root * 2 + 1;
        var best = root;
        if (less(items[best], items[child])) {
            best = child;
        }
        var right = child + 1;
        if (right < count && less(items[best], items[right])) {
            best = right;
        }
        if (best == root) {
            return;
        }
        swap(items, root, best);
        root = best;
    }
}

// In-place O(n log n) heapsort. `less(a, b)` should return true exactly when
// a belongs before b in the resulting order.
pub fn sort_by[T](items: []T, less: fn(T, T) -> bool) {
    var count = len(items);
    if (count < 2) {
        return;
    }

    var start = count / 2;
    while (start > 0) {
        start -= 1;
        sort_sift_down(items, start, count, less);
    }

    var end = count;
    while (end > 1) {
        end -= 1;
        swap(items, 0, end);
        sort_sift_down(items, 0, end, less);
    }
}
