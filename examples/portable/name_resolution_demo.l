import bytes;
import slang_names;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn has_error(errors: []slang_names.Error, kind: slang_names.ErrorKind, name: []u8) -> bool {
    for (error in errors) {
        if (error.kind == kind && bytes.equal(error.name, name)) { return true; }
    }
    return false;
}

fn has_use(uses: []slang_names.Use, status: slang_names.UseStatus, root: []u8) -> bool {
    for (use in uses) {
        if (use.status == status && bytes.equal(use.root, root)) { return true; }
    }
    return false;
}

fn main() -> i64 {
    var source = "import alpha.beta as ext;\nconst LIMIT: i64 = 3;\nfn helper(x: i64) -> i64 { return x; }\nfn good[T](xs: []T, n: i64) -> i64 { var y: i64 = n; if (true) { var sibling: i64 = y; } else { var sibling: i64 = y; } for (item in xs) { var copy = item; } var local_call = helper(y); var remote = ext.value; match (y) { other { return other; } } }\nfn bad_capture(x: i64) -> i64 { var f: fn(i64) -> i64 = fn(y: i64) -> i64 { return x + y; }; return 0; }\nfn bad_shadow(x: i64) -> i64 { var helper: i64 = x; return helper; }\nfn bad_unresolved() -> i64 { return missing; }\n";

    var result = slang_names.resolve(source);

    require(has_error(result.errors, slang_names.ErrorKind.captures_outer_runtime_name, "x"));
    require(has_error(result.errors, slang_names.ErrorKind.shadows_module_name, "helper"));
    require(has_error(result.errors, slang_names.ErrorKind.unresolved_value, "missing"));

    require(has_use(result.uses, slang_names.UseStatus.resolved, "helper"));
    require(has_use(result.uses, slang_names.UseStatus.resolved, "ext"));
    require(has_use(result.uses, slang_names.UseStatus.resolved, "y"));
    require(has_use(result.uses, slang_names.UseStatus.capture, "x"));
    require(has_use(result.uses, slang_names.UseStatus.pattern_candidate, "other"));

    // Sibling blocks are separate lexical scopes. Reusing a local spelling in
    // the other branch must not be diagnosed as shadowing/duplication.
    require(!has_error(result.errors, slang_names.ErrorKind.duplicate_binding, "sibling"));

    return 0;
}
