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

    var const_good: []u8 = "struct Node { value: i64, }\nfn first[T](items: const []T) -> T { return items[0]; }\nfn count(items: const []i64) -> u64 { var n: u64 = 0; for (item in items) { n += 1; } return n; }\nfn writable_string() -> i64 { var bytes: []u8 = \"xy\"; bytes[0] = 'q'; return bytes[0] as i64; }\nfn main() -> i64 { var values: []i64 = [1, 2]; var view: const []i64 = values; view = values; var x: i64 = first(values); var n = count(view); var bytes: []u8 = []; splice(bytes, 0, 0, \"abc\"); var inner: []i64 = [1]; var outer: const [][]i64 = [inner]; outer[0][0] = 2; var nodes: []ref Node = [new Node { value: 1 }]; var node_view: const []ref Node = nodes; node_view[0].value = 7; return x + n as i64 + inner[0] + node_view[0].value; }\n";
    var const_good_checked = slang_check.check(const_good);
    require(len(const_good_checked.names.errors) == 0);
    require(len(const_good_checked.errors) == 0);

    var const_to_mutable: []u8 = "fn main() -> i64 { var r: const []i64 = [1]; var w: []i64 = r; return len(w) as i64; }\n";
    var const_to_mutable_checked = slang_check.check(const_to_mutable);
    require(has_error(const_to_mutable_checked.errors, slang_check.ErrorKind.type_mismatch));

    var const_index_write: []u8 = "fn main() -> i64 { var r: const []i64 = [1]; r[0] = 2; return r[0]; }\n";
    var const_index_write_checked = slang_check.check(const_index_write);
    require(has_error(const_index_write_checked.errors, slang_check.ErrorKind.not_assignable));

    var const_push: []u8 = "fn main() -> i64 { var r: const []i64 = [1]; push(r, 2); return 0; }\n";
    var const_push_checked = slang_check.check(const_push);
    require(has_error(const_push_checked.errors, slang_check.ErrorKind.mutable_array_required));

    var const_pop: []u8 = "fn main() -> i64 { var r: const []i64 = [1]; var x = pop(r); return x; }\n";
    var const_pop_checked = slang_check.check(const_pop);
    require(has_error(const_pop_checked.errors, slang_check.ErrorKind.mutable_array_required));

    var const_splice: []u8 = "fn main() -> i64 { var r: const []i64 = [1]; splice(r, 0, 1, [2]); return 0; }\n";
    var const_splice_checked = slang_check.check(const_splice);
    require(has_error(const_splice_checked.errors, slang_check.ErrorKind.mutable_array_required));

    var inferred_string_write: []u8 = "fn main() -> i64 { var s = \"x\"; s[0] = 'y'; return 0; }\n";
    var inferred_string_write_checked = slang_check.check(inferred_string_write);
    require(has_error(inferred_string_write_checked.errors, slang_check.ErrorKind.not_assignable));

    var mutable_generic_string: []u8 = "fn use_mutable[T](items: []T) -> u64 { return len(items); }\nfn main() -> i64 { return use_mutable(\"x\") as i64; }\n";
    var mutable_generic_string_checked = slang_check.check(mutable_generic_string);
    require(has_error(mutable_generic_string_checked.errors, slang_check.ErrorKind.generic_inference) ||
        has_error(mutable_generic_string_checked.errors, slang_check.ErrorKind.type_mismatch));

    var nested_no_lift: []u8 = "fn main() -> i64 { var x: [][]i64 = [[1]]; var y: const []const []i64 = x; return len(y) as i64; }\n";
    var nested_no_lift_checked = slang_check.check(nested_no_lift);
    require(has_error(nested_no_lift_checked.errors, slang_check.ErrorKind.type_mismatch));

    var const_result_to_mutable: []u8 = "fn readonly[T](x: const []T) -> const []T { return x; }\nfn main() -> i64 { var x: []i64 = readonly([1]); return len(x) as i64; }\n";
    var const_result_to_mutable_checked = slang_check.check(const_result_to_mutable);
    require(has_error(const_result_to_mutable_checked.errors, slang_check.ErrorKind.type_mismatch) ||
        has_error(const_result_to_mutable_checked.errors, slang_check.ErrorKind.generic_inference));

    var mutable_result_to_const: []u8 = "fn make[T](x: T) -> []T { return [x]; }\nfn main() -> i64 { var x: const []i64 = make(1); return x[0]; }\n";
    var mutable_result_to_const_checked = slang_check.check(mutable_result_to_const);
    require(len(mutable_result_to_const_checked.errors) == 0);

    var bad: []u8 = "const LIMIT: i64 = 3;\nfn bad_type() -> i64 { var flag: bool = 1; return 0; }\nfn bad_place() -> i64 { LIMIT = 4; return 0; }\nfn bad_stmt() -> i64 { 1; }\nfn bad_break() -> i64 { break; return 0; }\n";
    var checked = slang_check.check(bad);
    require(has_error(checked.errors, slang_check.ErrorKind.type_mismatch));
    require(has_error(checked.errors, slang_check.ErrorKind.not_assignable));
    require(has_error(checked.errors, slang_check.ErrorKind.bad_expression_statement));
    require(has_error(checked.errors, slang_check.ErrorKind.break_outside_loop));
    require(has_error(checked.errors, slang_check.ErrorKind.missing_return));

    return 0;
}
