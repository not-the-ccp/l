import slang_check;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn has_error(errors: []slang_check.Error, kind: slang_check.ErrorKind) -> bool {
    for (error in errors) {
        if (error.kind == kind) { return true; }
    }
    return false;
}

fn main() -> i64 {
    var linked: []u8 = "struct Node { value: i64, next: ?ref Node, }\nfn prepend(head: ?ref Node, value: i64) -> ?ref Node { return some(new Node { value: value, next: head }); }\nfn sum(head: ?ref Node) -> i64 { var total: i64 = 0; var cursor = head; while (cursor is some(node)) { total += node.value; cursor = node.next; } return total; }\n";
    var good = slang_check.check(linked);
    require(len(good.names.errors) == 0);
    require(len(good.errors) == 0);
    require(len(good.symbol_types) > 0);
    require(len(good.expression_types) > 0);

    var generic: []u8 = "struct Box[T] { value: T, }\nfn identity[T](x: T) -> T { return x; }\nfn empty[T]() -> []T { return []; }\nfn main() -> i64 { var box: Box[i64] = Box { value: identity(7) }; var xs: []i64 = empty(); return box.value + len(xs) as i64; }\n";
    var generic_checked = slang_check.check(generic);
    require(len(generic_checked.names.errors) == 0);
    require(len(generic_checked.errors) == 0);

    var bad: []u8 = "const LIMIT: i64 = 3;\nfn bad_type() -> i64 { var flag: bool = 1; return 0; }\nfn bad_place() -> i64 { LIMIT = 4; return 0; }\nfn bad_stmt() -> i64 { 1; }\nfn bad_break() -> i64 { break; return 0; }\n";
    var checked = slang_check.check(bad);
    require(has_error(checked.errors, slang_check.ErrorKind.type_mismatch));
    require(has_error(checked.errors, slang_check.ErrorKind.not_assignable));
    require(has_error(checked.errors, slang_check.ErrorKind.bad_expression_statement));
    require(has_error(checked.errors, slang_check.ErrorKind.break_outside_loop));
    require(has_error(checked.errors, slang_check.ErrorKind.missing_return));

    return 0;
}