import slang_check;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn has_error(errors: []slang_check.Error, kind: slang_check.ErrorKind) -> bool {
    for (error in errors) {
        if (error.kind is kind) { return true; }
    }
    return false;
}

fn main() -> i64 {
    var linked = "struct Node { value: i64, next: ?ref Node, }\nfn prepend(head: ?ref Node, value: i64) -> ?ref Node { return some(new Node { value: value, next: head }); }\nfn sum(head: ?ref Node) -> i64 { var total: i64 = 0; var cursor = head; while (cursor is some(node)) { total += node.value; cursor = node.next; } return total; }\n";
    var good = slang_check.check(linked);
    require(len(good.names.errors) == 0);
    require(len(good.errors) == 0);
    require(len(good.symbol_types) > 0);
    require(len(good.expression_types) > 0);

    var bad = "const LIMIT: i64 = 3;\nfn bad_type() -> i64 { var flag: bool = 1; return 0; }\nfn bad_place() -> i64 { LIMIT = 4; return 0; }\nfn bad_stmt() -> i64 { 1; }\nfn bad_break() -> i64 { break; return 0; }\nfn generic[T](x: T) -> T { return x; }\n";
    var checked = slang_check.check(bad);
    require(has_error(checked.errors, slang_check.ErrorKind.type_mismatch));
    require(has_error(checked.errors, slang_check.ErrorKind.not_assignable));
    require(has_error(checked.errors, slang_check.ErrorKind.bad_expression_statement));
    require(has_error(checked.errors, slang_check.ErrorKind.break_outside_loop));
    require(has_error(checked.errors, slang_check.ErrorKind.missing_return));
    require(has_error(checked.errors, slang_check.ErrorKind.unsupported_feature));

    return 0;
}
