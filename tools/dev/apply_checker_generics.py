from pathlib import Path

path = Path('lib/portable/slang_check.l')
text = path.read_text()

def replace_once(old: str, new: str) -> None:
    global text
    if text.count(old) != 1:
        raise SystemExit(f'expected exactly one occurrence, found {text.count(old)}: {old[:80]!r}')
    text = text.replace(old, new, 1)

def replace_between(start: str, end: str, replacement: str) -> None:
    global text
    a = text.index(start)
    b = text.index(end, a)
    text = text[:a] + replacement + '\n\n' + text[b:]

replace_once('    missing_return,\n}', '    missing_return,\n    generic_inference,\n}')
replace_once(
'''struct CandidateScope {
    names: [][]u8,
    types: []ref slang_types.ResolvedType,
}
''',
'''struct CandidateScope {
    names: [][]u8,
    types: []ref slang_types.ResolvedType,
}

struct TypeBindings {
    names: [][]u8,
    types: []ref slang_types.ResolvedType,
}
''')
replace_once('    current_decl: []u8,\n    loop_depth: u64,', '    current_decl: []u8,\n    current_generics: []slang_decls.GenericParam,\n    loop_depth: u64,')

marker = '''fn is_primitive(type: ref slang_types.ResolvedType, name: []u8) -> bool {'''
helpers = r'''fn binding_type(bindings: ref TypeBindings, name: []u8) -> ?ref slang_types.ResolvedType {
    for (var i: u64 = 0; i < len(bindings.names); i += 1) {
        if (bytes.equal(bindings.names[i], name)) { return some(bindings.types[i]); }
    }
    return none;
}

fn bind_type(checker: ref Checker, bindings: ref TypeBindings, name: []u8,
    type: ref slang_types.ResolvedType, start: u64, end: u64, soft: bool) -> bool {
    match (binding_type(bindings, name)) {
        none {
            push(bindings.names, bytes.clone(name));
            push(bindings.types, type);
            return true;
        }
        some(existing) {
            if (same(existing, type)) { return true; }
            if (!soft) { push_error(checker, ErrorKind.generic_inference, name, start, end); }
            return false;
        }
    }
}

fn substitute_type(type: ref slang_types.ResolvedType, bindings: ref TypeBindings) -> ref slang_types.ResolvedType {
    if (type.kind is slang_types.ResolvedKind.generic) {
        match (binding_type(bindings, type.name)) {
            none { return type; }
            some(bound) { return bound; }
        }
    }
    if (len(type.children) == 0) { return type; }
    var children: []ref slang_types.ResolvedType = [];
    for (child in type.children) { push(children, substitute_type(child, bindings)); }
    return make_type(type.kind, type.module, type.name, children, type.parameter_count);
}

fn fully_bound(type: ref slang_types.ResolvedType, bindings: ref TypeBindings) -> bool {
    if (type.kind is slang_types.ResolvedKind.generic) {
        return binding_type(bindings, type.name) is some(_);
    }
    for (child in type.children) {
        if (!fully_bound(child, bindings)) { return false; }
    }
    return true;
}

fn unify_type(checker: ref Checker, pattern: ref slang_types.ResolvedType,
    actual: ref slang_types.ResolvedType, bindings: ref TypeBindings,
    start: u64, end: u64, soft: bool) -> bool {
    if (pattern.kind is slang_types.ResolvedKind.invalid || actual.kind is slang_types.ResolvedKind.invalid) {
        return true;
    }
    if (pattern.kind is slang_types.ResolvedKind.generic) {
        return bind_type(checker, bindings, pattern.name, actual, start, end, soft);
    }
    if (pattern.kind != actual.kind || pattern.parameter_count != actual.parameter_count ||
        len(pattern.children) != len(actual.children)) {
        if (!soft) { push_error(checker, ErrorKind.generic_inference, pattern.name, start, end); }
        return false;
    }
    if (!bytes.equal(pattern.module, actual.module) || !bytes.equal(pattern.name, actual.name)) {
        if (!soft) { push_error(checker, ErrorKind.generic_inference, pattern.name, start, end); }
        return false;
    }
    for (var i: u64 = 0; i < len(pattern.children); i += 1) {
        if (!unify_type(checker, pattern.children[i], actual.children[i], bindings, start, end, soft)) {
            return false;
        }
    }
    return true;
}

fn bindings_complete(generics: []slang_decls.GenericParam, bindings: ref TypeBindings) -> bool {
    for (generic in generics) {
        if (binding_type(bindings, generic.name) is none) { return false; }
    }
    return true;
}

fn seed_nominal_bindings(checker: ref Checker, decl: slang_decls.Decl,
    expected: ?ref slang_types.ResolvedType, bindings: ref TypeBindings,
    start: u64, end: u64) {
    match (expected) {
        none { }
        some(type) {
            if (type.kind is slang_types.ResolvedKind.nominal && bytes.equal(type.module, "main") &&
                bytes.equal(type.name, decl.name) && len(type.children) == len(decl.generics)) {
                for (var i: u64 = 0; i < len(decl.generics); i += 1) {
                    bind_type(checker, bindings, decl.generics[i].name, type.children[i], start, end, true);
                }
            }
        }
    }
}

fn generic_arguments(checker: ref Checker, generics: []slang_decls.GenericParam,
    bindings: ref TypeBindings, start: u64, end: u64) -> []ref slang_types.ResolvedType {
    var out: []ref slang_types.ResolvedType = [];
    for (generic in generics) {
        match (binding_type(bindings, generic.name)) {
            none {
                push_error(checker, ErrorKind.generic_inference, generic.name, start, end);
                push(out, invalid_type());
            }
            some(type) { push(out, type); }
        }
    }
    return out;
}

'''
replace_once(marker, helpers + marker)

replace_between('fn field_type(checker: ref Checker,', 'fn apply_field_tail(checker: ref Checker,', r'''fn field_type(checker: ref Checker, base: ref slang_types.ResolvedType, name: []u8,
    start: u64, end: u64) -> ref slang_types.ResolvedType {
    var nominal = base;
    if (nominal.kind is slang_types.ResolvedKind.reference && len(nominal.children) == 1) {
        nominal = nominal.children[0];
    }
    match (nominal_decl(checker, nominal)) {
        none {
            push_error(checker, ErrorKind.field_missing, name, start, end);
            return invalid_type();
        }
        some(decl) {
            if (len(decl.generics) != len(nominal.children)) {
                push_error(checker, ErrorKind.invalid_type, decl.name, start, end);
                return invalid_type();
            }
            var bindings = new TypeBindings { names: [], types: [] };
            for (var i: u64 = 0; i < len(decl.generics); i += 1) {
                bind_type(checker, bindings, decl.generics[i].name, nominal.children[i], start, end, false);
            }
            for (field in decl.fields) {
                if (bytes.equal(field.name, name)) {
                    var template = resolve_syntax_type(checker, decl.generics, field.type, decl.name);
                    return substitute_type(template, bindings);
                }
            }
            push_error(checker, ErrorKind.field_missing, name, start, end);
            return invalid_type();
        }
    }
}''')

replace_between('fn enum_value_type(checker: ref Checker,', 'fn name_type(checker: ref Checker,', r'''fn enum_value_type(checker: ref Checker, decl: slang_decls.Decl,
    variant_name: []u8, expected: ?ref slang_types.ResolvedType,
    arguments: []ref slang_decls.Expr, start: u64, end: u64) -> ref slang_types.ResolvedType {
    match (enum_variant(checker, decl, variant_name)) {
        none {
            push_error(checker, ErrorKind.not_a_value, variant_name, start, end);
            return invalid_type();
        }
        some(variant) {
            if (len(variant.payload) != len(arguments)) {
                push_error(checker, ErrorKind.arity, variant.name, start, end);
                return invalid_type();
            }
            var bindings = new TypeBindings { names: [], types: [] };
            seed_nominal_bindings(checker, decl, expected, bindings, start, end);
            for (var i: u64 = 0; i < len(arguments); i += 1) {
                var template = resolve_syntax_type(checker, decl.generics, variant.payload[i], decl.name);
                var expected_arg: ?ref slang_types.ResolvedType = none;
                if (fully_bound(template, bindings)) { expected_arg = some(substitute_type(template, bindings)); }
                var actual = expr_type(checker, arguments[i], expected_arg);
                unify_type(checker, template, actual, bindings, arguments[i].start, arguments[i].end, false);
            }
            if (!bindings_complete(decl.generics, bindings)) {
                push_error(checker, ErrorKind.generic_inference, decl.name, start, end);
                return invalid_type();
            }
            var args = generic_arguments(checker, decl.generics, bindings, start, end);
            var out = make_type(slang_types.ResolvedKind.nominal, "main", decl.name, args, 0);
            for (var i: u64 = 0; i < len(arguments); i += 1) {
                var template = resolve_syntax_type(checker, decl.generics, variant.payload[i], decl.name);
                var want = substitute_type(template, bindings);
                require_same(checker, want, expr_type(checker, arguments[i], some(want)),
                    arguments[i].start, arguments[i].end);
            }
            match (expected) {
                none { }
                some(want) { require_same(checker, want, out, start, end); }
            }
            return out;
        }
    }
}''')

call_marker = 'fn call_type(checker: ref Checker, expr: ref slang_decls.Expr,'
generic_call = r'''fn instantiate_generic_call(checker: ref Checker, decl: slang_decls.Decl,
    args: []ref slang_decls.Expr, expected: ?ref slang_types.ResolvedType,
    start: u64, end: u64) -> ref slang_types.ResolvedType {
    if (len(args) != len(decl.parameters)) {
        push_error(checker, ErrorKind.arity, decl.name, start, end);
        return invalid_type();
    }
    var bindings = new TypeBindings { names: [], types: [] };
    var result = unit_type();
    match (decl.return_type) {
        none { }
        some(syntax) { result = resolve_syntax_type(checker, decl.generics, syntax, decl.name); }
    }
    match (expected) {
        none { }
        some(want) { unify_type(checker, result, want, bindings, start, end, true); }
    }
    for (var i: u64 = 0; i < len(args); i += 1) {
        var template = resolve_syntax_type(checker, decl.generics, decl.parameters[i].type, decl.name);
        var expected_arg: ?ref slang_types.ResolvedType = none;
        if (fully_bound(template, bindings)) { expected_arg = some(substitute_type(template, bindings)); }
        var actual = expr_type(checker, args[i], expected_arg);
        unify_type(checker, template, actual, bindings, args[i].start, args[i].end, false);
    }
    if (!bindings_complete(decl.generics, bindings)) {
        push_error(checker, ErrorKind.generic_inference, decl.name, start, end);
        return invalid_type();
    }
    if (bytes.equal(checker.current_decl, decl.name)) {
        for (generic in decl.generics) {
            match (binding_type(bindings, generic.name)) {
                none { }
                some(type) {
                    if (!(type.kind is slang_types.ResolvedKind.generic) || !bytes.equal(type.name, generic.name)) {
                        push_error(checker, ErrorKind.generic_inference, generic.name, start, end);
                    }
                }
            }
        }
    }
    for (var i: u64 = 0; i < len(args); i += 1) {
        var template = resolve_syntax_type(checker, decl.generics, decl.parameters[i].type, decl.name);
        var want = substitute_type(template, bindings);
        require_same(checker, want, expr_type(checker, args[i], some(want)), args[i].start, args[i].end);
    }
    return substitute_type(result, bindings);
}

'''
replace_once(call_marker, generic_call + call_marker)
replace_once(
'''                                    if (decl.kind is slang_decls.DeclKind.function && len(decl.generics) > 0) {
                                        push_error(checker, ErrorKind.unsupported_feature, decl.name, expr.start, expr.end);
                                        return invalid_type();
                                    }
''',
'''                                    if (decl.kind is slang_decls.DeclKind.function && len(decl.generics) > 0) {
                                        return instantiate_generic_call(checker, decl, args, expected, expr.start, expr.end);
                                    }
''')

replace_between('fn struct_literal_type(checker: ref Checker,', 'fn expr_type(checker: ref Checker,', r'''fn struct_literal_type(checker: ref Checker, expr: ref slang_decls.Expr,
    expected: ?ref slang_types.ResolvedType) -> ref slang_types.ResolvedType {
    if (len(expr.children) != 1 || !(expr.children[0].kind is slang_decls.ExprKind.name) ||
        first_dot(expr.children[0].text) is some(_)) {
        push_error(checker, ErrorKind.not_a_value, [], expr.start, expr.end);
        return invalid_type();
    }
    var name = expr.children[0].text;
    match (find_decl(checker, name)) {
        none {
            push_error(checker, ErrorKind.not_a_value, name, expr.start, expr.end);
            return invalid_type();
        }
        some(decl) {
            if (!(decl.kind is slang_decls.DeclKind.structure)) {
                push_error(checker, ErrorKind.not_a_value, name, expr.start, expr.end);
                return invalid_type();
            }
            if (len(decl.fields) != len(expr.fields)) {
                push_error(checker, ErrorKind.arity, name, expr.start, expr.end);
            }
            var bindings = new TypeBindings { names: [], types: [] };
            seed_nominal_bindings(checker, decl, expected, bindings, expr.start, expr.end);
            for (field in decl.fields) {
                var found = false;
                for (supplied in expr.fields) {
                    if (bytes.equal(field.name, supplied.name)) {
                        found = true;
                        var template = resolve_syntax_type(checker, decl.generics, field.type, decl.name);
                        var expected_field: ?ref slang_types.ResolvedType = none;
                        if (fully_bound(template, bindings)) { expected_field = some(substitute_type(template, bindings)); }
                        var actual = expr_type(checker, supplied.value, expected_field);
                        unify_type(checker, template, actual, bindings, supplied.start, supplied.end, false);
                    }
                }
                if (!found) { push_error(checker, ErrorKind.field_missing, field.name, expr.start, expr.end); }
            }
            if (!bindings_complete(decl.generics, bindings)) {
                push_error(checker, ErrorKind.generic_inference, decl.name, expr.start, expr.end);
                return invalid_type();
            }
            var generic_args = generic_arguments(checker, decl.generics, bindings, expr.start, expr.end);
            var out = make_type(slang_types.ResolvedKind.nominal, "main", decl.name, generic_args, 0);
            for (field in decl.fields) {
                for (supplied in expr.fields) {
                    if (bytes.equal(field.name, supplied.name)) {
                        var template = resolve_syntax_type(checker, decl.generics, field.type, decl.name);
                        var want = substitute_type(template, bindings);
                        require_same(checker, want, expr_type(checker, supplied.value, some(want)),
                            supplied.start, supplied.end);
                    }
                }
            }
            match (expected) { none { } some(want) { require_same(checker, want, out, expr.start, expr.end); } }
            return out;
        }
    }
}''')

# Types written inside a generic function may refer to its type parameters.
text = text.replace('resolve_syntax_type(checker, [], target_syntax, checker.current_decl)',
                    'resolve_syntax_type(checker, checker.current_generics, target_syntax, checker.current_decl)')
text = text.replace('resolve_syntax_type(checker, [], parameter.type, old_decl)',
                    'resolve_syntax_type(checker, checker.current_generics, parameter.type, old_decl)')
text = text.replace('resolve_syntax_type(checker, [], syntax, old_decl)',
                    'resolve_syntax_type(checker, checker.current_generics, syntax, old_decl)')
text = text.replace('resolve_syntax_type(checker, [], syntax, checker.current_decl)',
                    'resolve_syntax_type(checker, checker.current_generics, syntax, checker.current_decl)')

# Generic enum patterns use the subject's already-resolved nominal arguments.
old = '''                if (!(decl.kind is slang_decls.DeclKind.enumeration) || len(decl.generics) > 0) {
                    push_error(checker, ErrorKind.bad_pattern, pattern.name, pattern.start, pattern.end); return;
                }
                var variant_name = pattern.name;'''
new = '''                if (!(decl.kind is slang_decls.DeclKind.enumeration) || len(decl.generics) != len(subject.children)) {
                    push_error(checker, ErrorKind.bad_pattern, pattern.name, pattern.start, pattern.end); return;
                }
                var bindings = new TypeBindings { names: [], types: [] };
                for (var gi: u64 = 0; gi < len(decl.generics); gi += 1) {
                    bind_type(checker, bindings, decl.generics[gi].name, subject.children[gi], pattern.start, pattern.end, false);
                }
                var variant_name = pattern.name;'''
replace_once(old, new)
replace_once(
'''                                    bind_pattern_symbol(checker, pattern.children[i],
                                        resolve_syntax_type(checker, decl.generics, variant.payload[i], decl.name));''',
'''                                    var template = resolve_syntax_type(checker, decl.generics, variant.payload[i], decl.name);
                                    bind_pattern_symbol(checker, pattern.children[i], substitute_type(template, bindings));''')

# Generic function bodies are checked abstractly; generic functions remain non-first-class.
replace_once(
'''    if (!(decl.kind is slang_decls.DeclKind.function)) { return; }
    if (len(decl.generics) > 0) {
        push_error(checker, ErrorKind.unsupported_feature, decl.name, decl.start, decl.end);
        return;
    }

    for (parameter in decl.parameters) {''',
'''    if (!(decl.kind is slang_decls.DeclKind.function)) { return; }
    checker.current_generics = decl.generics;

    for (parameter in decl.parameters) {''')
replace_once('        current_decl: [],\n        loop_depth: 0,', '        current_decl: [],\n        current_generics: [],\n        loop_depth: 0,')

path.write_text(text)

# Add generic differential cases to the existing oracle comparison corpus.
diff = Path('tests/selfhost_checker_diff.py')
d = diff.read_text()
needle = ']\n\n\ndef python_accepts'
if needle not in d:
    raise SystemExit('differential corpus insertion point not found')
generic_cases = r'''    (
        "generic identity inference",
        "fn identity[T](x: T) -> T { return x; } fn main() -> i64 { return identity(7); }",
    ),
    (
        "generic expected-result inference",
        "fn empty[T]() -> []T { return []; } fn main() { var xs: []i64 = empty(); }",
    ),
    (
        "generic struct inference",
        "struct Box[T] { value: T, } fn main() -> i64 { var b: Box[i64] = Box { value: 4 }; return b.value; }",
    ),
    (
        "generic enum inference and pattern",
        "enum Maybe[T] { just(T), nothing, } fn get(x: Maybe[i64]) -> i64 { match (x) { Maybe.just(v) { return v; } Maybe.nothing { return 0; } } } fn main() -> i64 { var x: Maybe[i64] = Maybe.just(9); return get(x); }",
    ),
    (
        "generic queue core example",
        """
struct Queue[T] { items: []T, head: u64, }
fn queue_new[T]() -> ref Queue[T] { return new Queue { items: [], head: 0 }; }
fn queue_push[T](q: ref Queue[T], value: T) { push(q.items, value); }
fn queue_pop[T](q: ref Queue[T]) -> ?T {
    if (q.head >= len(q.items)) { return none; }
    var value: T = q.items[q.head];
    q.head += 1;
    return some(value);
}
fn main() -> i64 {
    var q: ref Queue[i64] = queue_new();
    queue_push(q, 5);
    match (queue_pop(q)) { some(v) { return v; } none { return 0; } }
}
""",
    ),
    (
        "generic function is not first class",
        "fn identity[T](x: T) -> T { return x; } fn main() { var f = identity; }",
    ),
    (
        "conflicting generic inference rejected",
        "fn choose[T](a: T, b: T) -> T { return a; } fn main() { var x = choose(1, true); }",
    ),
    (
        "unconstrained generic inference rejected",
        "fn empty[T]() -> []T { return []; } fn main() { empty(); }",
    ),
    (
        "type-changing generic recursion rejected",
        "fn bad[T](x: T) { bad([x]); } fn main() { bad(1); }",
    ),
'''
d = d.replace(needle, generic_cases + ']\n\n\ndef python_accepts', 1)
diff.write_text(d)
