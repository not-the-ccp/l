struct Node {
    value: i64,
    next: ?ref Node,
}

fn prepend(head: ?ref Node, value: i64) -> ?ref Node {
    return some(new Node { value: value, next: head });
}

fn sum(head: ?ref Node) -> i64 {
    var total: i64 = 0;
    var cursor = head;
    while (cursor is some(node)) {
        total += node.value;
        cursor = node.next;
    }
    return total;
}
