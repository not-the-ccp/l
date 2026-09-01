fn array_reverse[T](a: []T) {
    var left = 0 as u64;
    var right = len(a);
    while (left < right) {
        right -= 1;
        if (left >= right) { break; }
        var tmp: T = a[left];
        a[left] = a[right];
        a[right] = tmp;
        left += 1;
    }
}

fn array_find[T](a: []T, value: T, equal: fn(T, T) -> bool) -> ?u64 {
    for (var i = 0 as u64; i < len(a); i += 1) {
        if (equal(a[i], value)) { return some(i); }
    }
    return none;
}

struct Queue[T] {
    items: []T;
    head: u64;
}

fn queue_new[T]() -> ref Queue[T] {
    return new Queue { items: [], head: 0 };
}

fn queue_push[T](q: ref Queue[T], value: T) { push(q.items, value); }

fn queue_pop[T](q: ref Queue[T]) -> ?T {
    if (q.head == len(q.items)) { return none; }
    var value: T = q.items[q.head];
    q.head += 1;
    return some(value);
}

struct Entry[K, V] {
    key: K;
    value: V;
    next: ?ref Entry[K, V];
}

struct Map[K, V] {
    buckets: []?ref Entry[K, V];
    hash: fn(K) -> u64;
    equal: fn(K, K) -> bool;
}

fn map_new[K, V](hash: fn(K) -> u64, equal: fn(K, K) -> bool) -> ref Map[K, V] {
    return new Map { buckets: [none; 16], hash: hash, equal: equal };
}

fn map_put[K, V](map: ref Map[K, V], key: K, value: V) {
    var index = map.hash(key) % len(map.buckets);
    var cursor = map.buckets[index];
    while (cursor is some(entry)) {
        if (map.equal(entry.key, key)) {
            entry.value = value;
            return;
        }
        cursor = entry.next;
    }
    map.buckets[index] = some(new Entry { key: key, value: value, next: map.buckets[index] });
}

fn map_get[K, V](map: ref Map[K, V], key: K) -> ?V {
    var index = map.hash(key) % len(map.buckets);
    var cursor = map.buckets[index];
    while (cursor is some(entry)) {
        if (map.equal(entry.key, key)) { return some(entry.value); }
        cursor = entry.next;
    }
    return none;
}

fn bytes_equal(a: []u8, b: []u8) -> bool {
    if (len(a) != len(b)) { return false; }
    for (var i = 0 as u64; i < len(a); i += 1) {
        if (a[i] != b[i]) { return false; }
    }
    return true;
}

fn bytes_hash(a: []u8) -> u64 {
    var h: u64 = 14695981039346656037;
    for (var i = 0 as u64; i < len(a); i += 1) {
        h ^= a[i] as u64;
        h *= 1099511628211;
    }
    return h;
}

fn int_equal(a: i64, b: i64) -> bool { return a == b; }

fn test() -> i64 {
    var map: ref Map[[]u8, i64] = map_new(bytes_hash, bytes_equal);
    map_put(map, "alpha", 10);
    map_put(map, "beta", 20);
    map_put(map, "alpha", 30);

    var score: i64 = 0;
    var a = map_get(map, "alpha");
    if (a is some(v)) { score += v; }
    var missing = map_get(map, "missing");
    if (missing is none) { score += 100; }

    var xs = [4, 1, 7, 2];
    array_reverse(xs);
    if (xs[0] == 2 && xs[3] == 4) { score += 10; }
    var found = array_find(xs, 7, int_equal);
    if (found is some(i)) { score += i as i64; }
    return score;
}
