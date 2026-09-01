import collections;

fn require(ok: bool) {
    if (!ok) {
        trap;
    }
}

fn hash_i64(value: i64) -> u64 {
    var x = value as u64;
    x ^= x >> 33;
    x *= 11400714819323198485;
    x ^= x >> 29;
    return x;
}

fn equal_i64(a: i64, b: i64) -> bool {
    return a == b;
}

fn less_i64(a: i64, b: i64) -> bool {
    return a < b;
}

fn main() -> i64 {
    var stack: ref collections.Stack[i64] = collections.stack_new();
    collections.stack_push(stack, 10);
    collections.stack_push(stack, 20);
    match (collections.stack_pop(stack)) {
        none { trap; }
        some(value) { require(value == 20); }
    }
    require(collections.stack_len(stack) == 1);

    var queue: ref collections.Queue[i64] = collections.queue_new();
    for (var i: i64 = 0; i < 200; i += 1) {
        collections.queue_push(queue, i);
    }
    for (var i: i64 = 0; i < 200; i += 1) {
        match (collections.queue_pop(queue)) {
            none { trap; }
            some(value) { require(value == i); }
        }
    }
    require(collections.queue_empty(queue));

    var heap = collections.heap_new(less_i64);
    collections.heap_push(heap, 9);
    collections.heap_push(heap, 2);
    collections.heap_push(heap, 7);
    collections.heap_push(heap, 1);
    var expected: []i64 = [1, 2, 7, 9];
    for (want in expected) {
        match (collections.heap_pop(heap)) {
            none { trap; }
            some(value) { require(value == want); }
        }
    }

    var map: ref collections.Map[i64, i64] = collections.map_new(hash_i64, equal_i64);
    for (var i: i64 = 0; i < 200; i += 1) {
        require(collections.map_set(map, i, i * 3));
    }
    require(collections.map_len(map) == 200);
    for (var i: i64 = 0; i < 200; i += 1) {
        match (collections.map_get(map, i)) {
            none { trap; }
            some(value) { require(value == i * 3); }
        }
    }
    require(!collections.map_set(map, 42, 999));
    match (collections.map_get(map, 42)) {
        none { trap; }
        some(value) { require(value == 999); }
    }
    match (collections.map_remove(map, 42)) {
        none { trap; }
        some(value) { require(value == 999); }
    }
    require(!collections.map_contains(map, 42));

    var set = collections.set_new(hash_i64, equal_i64);
    require(collections.set_add(set, 4));
    require(!collections.set_add(set, 4));
    require(collections.set_contains(set, 4));
    require(collections.set_remove(set, 4));
    require(!collections.set_contains(set, 4));

    return 0;
}
