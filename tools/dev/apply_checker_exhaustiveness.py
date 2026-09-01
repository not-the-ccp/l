from pathlib import Path

path = Path('lib/portable/slang_check.l')
text = path.read_text()

def replace_once(old: str, new: str) -> None:
    global text
    if text.count(old) != 1:
        raise SystemExit(f'expected one occurrence, found {text.count(old)}: {old[:100]!r}')
    text = text.replace(old, new, 1)

replace_once(
'''    missing_return,
    generic_inference,
}''',
'''    missing_return,
    generic_inference,
    duplicate_pattern,
    non_exhaustive_match,
}''')

marker = 'fn check_stmt(checker: ref Checker, stmt: ref slang_decls.Stmt) {'
helpers = r'''struct PatternCoverage {
    wildcard: bool,
    key: []u8,
}

fn coverage_key(pattern: ref slang_decls.Pattern, key: []u8) -> PatternCoverage {
    return PatternCoverage { wildcard: false, key: bytes.clone(key) };
}

fn pattern_coverage(checker: ref Checker, pattern: ref slang_decls.Pattern,
    subject: ref slang_types.ResolvedType) -> PatternCoverage {
    if (pattern.kind is slang_decls.PatternKind.wildcard) {
        return PatternCoverage { wildcard: true, key: [] };
    }
    if (pattern.kind is slang_decls.PatternKind.unit) { return coverage_key(pattern, "()"); }
    if (pattern.kind is slang_decls.PatternKind.none_value) { return coverage_key(pattern, "none"); }
    if (pattern.kind is slang_decls.PatternKind.some_value) { return coverage_key(pattern, "some"); }
    if (pattern.kind is slang_decls.PatternKind.boolean ||
        pattern.kind is slang_decls.PatternKind.integer ||
        pattern.kind is slang_decls.PatternKind.byte) {
        return coverage_key(pattern, pattern.name);
    }
    if (pattern.kind is slang_decls.PatternKind.constructor) {
        var name = pattern.name;
        match (tail_start(name)) { none { } some(pos) { name = bytes.slice(name, pos, len(name)); } }
        return coverage_key(pattern, name);
    }
    if (pattern.kind is slang_decls.PatternKind.binding) {
        // A bare name is a closed enum case only when it names a fieldless
        // variant of the subject enum. Otherwise it is a binding catch-all.
        if (subject.kind is slang_types.ResolvedKind.nominal && bytes.equal(subject.module, "main")) {
            match (find_decl(checker, subject.name)) {
                none { }
                some(decl) {
                    if (decl.kind is slang_decls.DeclKind.enumeration) {
                        match (enum_variant(checker, decl, pattern.name)) {
                            none { }
                            some(variant) {
                                if (len(variant.payload) == 0) { return coverage_key(pattern, pattern.name); }
                            }
                        }
                    }
                }
            }
        }
        return PatternCoverage { wildcard: true, key: [] };
    }
    return PatternCoverage { wildcard: false, key: [] };
}

fn coverage_contains(seen: [][]u8, key: []u8) -> bool {
    for (item in seen) { if (bytes.equal(item, key)) { return true; } }
    return false;
}

fn require_coverage(checker: ref Checker, seen: [][]u8, key: []u8,
    start: u64, end: u64) {
    if (!coverage_contains(seen, key)) {
        push_error(checker, ErrorKind.non_exhaustive_match, key, start, end);
    }
}

fn check_match_coverage(checker: ref Checker, stmt: ref slang_decls.Stmt,
    subject: ref slang_types.ResolvedType) {
    if (subject.kind is slang_types.ResolvedKind.invalid) { return; }
    var seen: [][]u8 = [];
    var wildcard = false;
    for (arm in stmt.arms) {
        var coverage = pattern_coverage(checker, arm.pattern, subject);
        if (coverage.wildcard) {
            wildcard = true;
        } else if (len(coverage.key) > 0) {
            if (coverage_contains(seen, coverage.key)) {
                push_error(checker, ErrorKind.duplicate_pattern, coverage.key,
                    arm.pattern.start, arm.pattern.end);
            } else {
                push(seen, coverage.key);
            }
        }
    }
    if (wildcard) { return; }

    if (subject.kind is slang_types.ResolvedKind.unit) {
        require_coverage(checker, seen, "()", stmt.start, stmt.end);
        return;
    }
    if (is_primitive(subject, "bool")) {
        require_coverage(checker, seen, "true", stmt.start, stmt.end);
        require_coverage(checker, seen, "false", stmt.start, stmt.end);
        return;
    }
    if (subject.kind is slang_types.ResolvedKind.optional) {
        require_coverage(checker, seen, "none", stmt.start, stmt.end);
        require_coverage(checker, seen, "some", stmt.start, stmt.end);
        return;
    }
    if (subject.kind is slang_types.ResolvedKind.nominal && bytes.equal(subject.module, "main")) {
        match (find_decl(checker, subject.name)) {
            none { }
            some(decl) {
                if (decl.kind is slang_decls.DeclKind.enumeration) {
                    for (variant in decl.variants) {
                        require_coverage(checker, seen, variant.name, stmt.start, stmt.end);
                    }
                    return;
                }
            }
        }
    }

    // Integer, byte, float, refs, arrays, function values and future open
    // domains cannot be enumerated by a finite literal-arm list.
    push_error(checker, ErrorKind.non_exhaustive_match, [], stmt.start, stmt.end);
}

'''
replace_once(marker, helpers + marker)

old_match = '''    if (stmt.kind is slang_decls.StmtKind.match_stmt) {
        var subject = expr_type(checker, stmt.expressions[0], none);
        for (arm in stmt.arms) {
            push_candidate_scope(checker);
            check_pattern(checker, arm.pattern, subject, true);
            check_block(checker, arm.body);
            pop_candidate_scope(checker);
        }
        return;
    }
'''
new_match = '''    if (stmt.kind is slang_decls.StmtKind.match_stmt) {
        var subject = expr_type(checker, stmt.expressions[0], none);
        for (arm in stmt.arms) {
            push_candidate_scope(checker);
            check_pattern(checker, arm.pattern, subject, true);
            check_block(checker, arm.body);
            pop_candidate_scope(checker);
        }
        check_match_coverage(checker, stmt, subject);
        return;
    }
'''
replace_once(old_match, new_match)
path.write_text(text)

cli = Path('tools/check/lcheck.l')
c = cli.read_text()
old = '''    if (kind is slang_check.ErrorKind.continue_outside_loop) { stdio.write("continue outside loop"); return; }
    stdio.write("function may fall off the end");
'''
new = '''    if (kind is slang_check.ErrorKind.continue_outside_loop) { stdio.write("continue outside loop"); return; }
    if (kind is slang_check.ErrorKind.generic_inference) { stdio.write("cannot infer generic type arguments"); return; }
    if (kind is slang_check.ErrorKind.duplicate_pattern) { stdio.write("duplicate match arm"); return; }
    if (kind is slang_check.ErrorKind.non_exhaustive_match) { stdio.write("non-exhaustive match"); return; }
    stdio.write("function may fall off the end");
'''
if c.count(old) != 1:
    raise SystemExit(f'lcheck diagnostic patch point count={c.count(old)}')
cli.write_text(c.replace(old, new, 1))

diff = Path('tests/selfhost_checker_diff.py')
d = diff.read_text()
needle = ']\n\n\ndef python_accepts'
if needle not in d:
    raise SystemExit('differential insertion point missing')
cases = r'''    (
        "exhaustive bool match",
        "fn f(x: bool) -> i64 { match (x) { true { return 1; } false { return 0; } } }",
    ),
    (
        "non-exhaustive bool match",
        "fn f(x: bool) -> i64 { match (x) { true { return 1; } } }",
    ),
    (
        "non-exhaustive optional match",
        "fn f(x: ?i64) -> i64 { match (x) { some(v) { return v; } } }",
    ),
    (
        "non-exhaustive enum match",
        "enum Color { red, green, blue, } fn f(x: Color) -> i64 { match (x) { red { return 1; } green { return 2; } } }",
    ),
    (
        "integer match requires catchall",
        "fn f(x: i64) -> i64 { match (x) { 0 { return 0; } 1 { return 1; } } }",
    ),
    (
        "integer binding catchall",
        "fn f(x: i64) -> i64 { match (x) { 0 { return 0; } other { return other; } } }",
    ),
    (
        "duplicate bool arm",
        "fn f(x: bool) -> i64 { match (x) { true { return 1; } true { return 2; } false { return 0; } } }",
    ),
    (
        "unit match exhaustive",
        "fn f(x: ()) -> i64 { match (x) { () { return 1; } } }",
    ),
'''
diff.write_text(d.replace(needle, cases + ']\n\n\ndef python_accepts', 1))
