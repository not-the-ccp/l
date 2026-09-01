// Generic portable collection building blocks.
//
// This module deliberately uses only L Core mechanisms. No host modules are
// required, and behavior such as hashing/comparison is supplied explicitly as
// ordinary function values rather than through traits or generic constraints.

pub struct Stack[T] {
    items: []T,
}

pub fn stack_new[T]() -> ref Stack[T] {
    return new Stack { items: [] };
}

pub fn stack_len[T](stack: ref Stack[T]) -> u64 {
    return len(stack.items);
}

pub fn stack_empty[T](stack: ref Stack[T]) -> bool {
    return len(stack.items) == 0;
}

pub fn stack_push[T](stack: ref Stack[T], value: T) {
    push(stack.items, value);
}

pub fn stack_pop[T](stack: ref Stack[T]) -> ?T {
    if (len(stack.items) == 0) {
        return none;
    }
    return some(pop(stack.items));
}

pub fn stack_peek[T](stack: ref Stack[T]) -> ?T {
    if (len(stack.items) == 0) {
        return none;
    }
    return some(stack.items[len(stack.items) - 1]);
}

pub struct Queue[T] {
    items: []T,
    head: u64,
}

pub fn queue_new[T]() -> ref Queue[T] {
    return new Queue { items: [], head: 0 };
}

pub fn queue_len[T](queue: ref Queue[T]) -> u64 {
    return len(queue.items) - queue.head;
}

pub fn queue_empty[T](queue: ref Queue[T]) -> bool {
    return queue.head == len(queue.items);
}

fn queue_compact[T](queue: ref Queue[T]) {
    if (queue.head == 0) {
        return;
    }
    if (queue.head == len(queue.items) || (queue.head >= 64 && queue.head * 2 >= len(queue.items))) {
        var empty: []T = [];
        splice(queue.items, 0, queue.head, empty);
        queue.head = 0;
    }
}

pub fn queue_push[T](queue: ref Queue[T], value: T) {
    push(queue.items, value);
}

pub fn queue_pop[T](queue: ref Queue[T]) -> ?T {
    if (queue.head >= len(queue.items)) {
        return none;
    }
    var value: T = queue.items[queue.head];
    queue.head += 1;
    queue_compact(queue);
    return some(value);
}

pub fn queue_peek[T](queue: ref Queue[T]) -> ?T {
    if (queue.head >= len(queue.items)) {
        return none;
    }
    return some(queue.items[queue.head]);
}

pub struct Heap[T] {
    items: []T,
    less: fn(T, T) -> bool,
}

pub fn heap_new[T](less: fn(T, T) -> bool) -> ref Heap[T] {
    return new Heap { items: [], less: less };
}

pub fn heap_len[T](heap: ref Heap[T]) -> u64 {
    return len(heap.items);
}

pub fn heap_empty[T](heap: ref Heap[T]) -> bool {
    return len(heap.items) == 0;
}

fn heap_sift_up[T](heap: ref Heap[T], start: u64) {
    var index = start;
    while (index > 0) {
        var parent = (index - 1) / 2;
        if (!heap.less(heap.items[index], heap.items[parent])) {
            return;
        }
        var temp: T = heap.items[index];
        heap.items[index] = heap.items[parent];
        heap.items[parent] = temp;
        index = parent;
    }
}

fn heap_sift_down[T](heap: ref Heap[T], start: u64) {
    var index = start;
    var count = len(heap.items);
    while (index < count / 2) {
        var left = index * 2 + 1;
        var best = left;
        var right = left + 1;
        if (right < count && heap.less(heap.items[right], heap.items[left])) {
            best = right;
        }
        if (!heap.less(heap.items[best], heap.items[index])) {
            return;
        }
        var temp: T = heap.items[index];
        heap.items[index] = heap.items[best];
        heap.items[best] = temp;
        index = best;
    }
}

pub fn heap_push[T](heap: ref Heap[T], value: T) {
    push(heap.items, value);
    heap_sift_up(heap, len(heap.items) - 1);
}

pub fn heap_peek[T](heap: ref Heap[T]) -> ?T {
    if (len(heap.items) == 0) {
        return none;
    }
    return some(heap.items[0]);
}

pub fn heap_pop[T](heap: ref Heap[T]) -> ?T {
    if (len(heap.items) == 0) {
        return none;
    }
    var result: T = heap.items[0];
    var last: T = pop(heap.items);
    if (len(heap.items) > 0) {
        heap.items[0] = last;
        heap_sift_down(heap, 0);
    }
    return some(result);
}

struct MapEntry[K, V] {
    key: K,
    value: V,
    next: ?ref MapEntry[K, V],
}

pub struct Map[K, V] {
    buckets: []?ref MapEntry[K, V],
    size: u64,
    hash: fn(K) -> u64,
    equal: fn(K, K) -> bool,
}

fn map_bucket[K, V](map: ref Map[K, V], key: K) -> u64 {
    return map.hash(key) % len(map.buckets);
}

fn map_rehash[K, V](map: ref Map[K, V], count: u64) {
    var next_buckets: []?ref MapEntry[K, V] = [none; count];
    for (bucket in map.buckets) {
        var cursor = bucket;
        while (cursor is some(entry)) {
            var following = entry.next;
            var index = map.hash(entry.key) % count;
            entry.next = next_buckets[index];
            next_buckets[index] = some(entry);
            cursor = following;
        }
    }
    map.buckets = next_buckets;
}

pub fn map_new[K, V](hash: fn(K) -> u64, equal: fn(K, K) -> bool) -> ref Map[K, V] {
    var buckets: []?ref MapEntry[K, V] = [none; 16];
    return new Map { buckets: buckets, size: 0, hash: hash, equal: equal };
}

pub fn map_len[K, V](map: ref Map[K, V]) -> u64 {
    return map.size;
}

pub fn map_empty[K, V](map: ref Map[K, V]) -> bool {
    return map.size == 0;
}

pub fn map_get[K, V](map: ref Map[K, V], key: K) -> ?V {
    var cursor = map.buckets[map_bucket(map, key)];
    while (cursor is some(entry)) {
        if (map.equal(entry.key, key)) {
            return some(entry.value);
        }
        cursor = entry.next;
    }
    return none;
}

pub fn map_contains[K, V](map: ref Map[K, V], key: K) -> bool {
    var cursor = map.buckets[map_bucket(map, key)];
    while (cursor is some(entry)) {
        if (map.equal(entry.key, key)) {
            return true;
        }
        cursor = entry.next;
    }
    return false;
}

pub fn map_set[K, V](map: ref Map[K, V], key: K, value: V) -> bool {
    var index = map_bucket(map, key);
    var cursor = map.buckets[index];
    while (cursor is some(entry)) {
        if (map.equal(entry.key, key)) {
            entry.value = value;
            return false;
        }
        cursor = entry.next;
    }

    if ((map.size + 1) * 4 > len(map.buckets) * 3) {
        map_rehash(map, len(map.buckets) * 2);
        index = map_bucket(map, key);
    }

    var entry: ref MapEntry[K, V] = new MapEntry {
        key: key,
        value: value,
        next: map.buckets[index],
    };
    map.buckets[index] = some(entry);
    map.size += 1;
    return true;
}

pub fn map_remove[K, V](map: ref Map[K, V], key: K) -> ?V {
    var index = map_bucket(map, key);
    var cursor = map.buckets[index];
    var previous: ?ref MapEntry[K, V] = none;
    while (cursor is some(entry)) {
        if (map.equal(entry.key, key)) {
            match (previous) {
                none {
                    map.buckets[index] = entry.next;
                }
                some(prev) {
                    prev.next = entry.next;
                }
            }
            map.size -= 1;
            return some(entry.value);
        }
        previous = some(entry);
        cursor = entry.next;
    }
    return none;
}

pub struct Set[T] {
    map: ref Map[T, ()],
}

pub fn set_new[T](hash: fn(T) -> u64, equal: fn(T, T) -> bool) -> ref Set[T] {
    var map: ref Map[T, ()] = map_new(hash, equal);
    return new Set { map: map };
}

pub fn set_len[T](set: ref Set[T]) -> u64 {
    return map_len(set.map);
}

pub fn set_contains[T](set: ref Set[T], value: T) -> bool {
    return map_contains(set.map, value);
}

pub fn set_add[T](set: ref Set[T], value: T) -> bool {
    return map_set(set.map, value, ());
}

pub fn set_remove[T](set: ref Set[T], value: T) -> bool {
    var removed = map_remove(set.map, value);
    match (removed) {
        none { return false; }
        some(_) { return true; }
    }
}
