struct Heap[T] {
    items: []T;
    less: fn(T, T) -> bool;
}

fn heap_new[T](less: fn(T, T) -> bool) -> ref Heap[T] {
    return new Heap { items: [], less: less };
}

fn heap_push[T](h: ref Heap[T], value: T) {
    push(h.items, value);
    var i = len(h.items) - 1;
    while (i > 0) {
        var parent = (i - 1) / 2;
        if (!h.less(h.items[i], h.items[parent])) { break; }
        var tmp: T = h.items[i];
        h.items[i] = h.items[parent];
        h.items[parent] = tmp;
        i = parent;
    }
}

fn heap_pop[T](h: ref Heap[T]) -> ?T {
    if (len(h.items) == 0) { return none; }
    var result: T = h.items[0];
    var last: T = pop(h.items);
    if (len(h.items) == 0) { return some(result); }
    h.items[0] = last;
    var i: u64 = 0;
    while (true) {
        var left = i * 2 + 1;
        if (left >= len(h.items)) { break; }
        var right = left + 1;
        var best = left;
        if (right < len(h.items) && h.less(h.items[right], h.items[left])) {
            best = right;
        }
        if (!h.less(h.items[best], h.items[i])) { break; }
        var tmp: T = h.items[i];
        h.items[i] = h.items[best];
        h.items[best] = tmp;
        i = best;
    }
    return some(result);
}

fn less_i64(a: i64, b: i64) -> bool { return a < b; }

fn test() -> i64 {
    var h: ref Heap[i64] = heap_new(less_i64);
    heap_push(h, 5);
    heap_push(h, 1);
    heap_push(h, 9);
    heap_push(h, 3);
    var score: i64 = 0;
    var factor: i64 = 1000;
    while (heap_pop(h) is some(x)) {
        score += x * factor;
        factor /= 10;
    }
    return score;
}
