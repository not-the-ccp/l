struct Queue[T] {
    items: []T,
    head: u64,
}

fn queue_new[T]() -> ref Queue[T] {
    return new Queue { items: [], head: 0 };
}

fn queue_push[T](q: ref Queue[T], value: T) {
    push(q.items, value);
}

fn queue_pop[T](q: ref Queue[T]) -> ?T {
    if (q.head >= len(q.items)) {
        return none;
    }
    var value: T = q.items[q.head];
    q.head += 1;
    return some(value);
}
