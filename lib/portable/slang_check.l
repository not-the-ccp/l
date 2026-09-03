import bytes;
import slang_decls;
import slang_names;
import slang_types;
import strconv;

// First executable semantic-checking layer for the self-hosting frontend.
//
// This pass intentionally starts with the non-generic single-source-module
// subset, but it is a real value/place checker rather than another syntax
// validator. Generic inference, imported value members, and the remaining
// exhaustive semantic rules are layered on after this base is differential-
// tested against the Python oracle.

pub enum ErrorKind {
    invalid_type,
    type_mismatch,
    unsupported_feature,
    ambiguous_value,
    not_a_value,
    array_required,
    mutable_array_required,
    reference_required,
    boolean_required,
    integer_required,
    numeric_required,
    equality_unsupported,
    ordering_unsupported,
    bad_cast,
    field_missing,
    not_assignable,
    function_required,
    arity,
    bad_expression_statement,
    bad_pattern,
    break_outside_loop,
    continue_outside_loop,
    missing_return,
    generic_inference,
    duplicate_pattern,
    non_exhaustive_match,
    literal_range,
}

pub struct Error {
    pub kind: ErrorKind,
    pub name: []u8,
    pub start: u64,
    pub end: u64,
}

pub struct SymbolType {
    pub symbol: u64,
    pub type: ref slang_types.ResolvedType,
}

pub struct ExprType {
    pub start: u64,
    pub end: u64,
    pub type: ref slang_types.ResolvedType,
}

pub struct CheckResult {
    pub names: slang_names.Resolution,
    pub errors: []Error,
    pub symbol_types: []SymbolType,
    pub expression_types: []ExprType,
}

struct CandidateScope {
    names: [][]u8,
    types: []ref slang_types.ResolvedType,
}

struct TypeBindings {
    names: [][]u8,
    types: []ref slang_types.ResolvedType,
}

struct Checker {
    module: slang_types.Module,
    modules: []slang_types.Module,
    names: slang_names.Resolution,
    errors: []Error,
    symbol_types: []SymbolType,
    expression_types: []ExprType,
    candidates: []CandidateScope,
    return_type: ref slang_types.ResolvedType,
    current_decl: []u8,
    current_generics: []slang_decls.GenericParam,
    loop_depth: u64,
}

fn empty_bytes() -> []u8 { return []; }

fn make_type(kind: slang_types.ResolvedKind, module: []u8, name: []u8,
    children: []ref slang_types.ResolvedType, parameter_count: u64) -> ref slang_types.ResolvedType {
    return new slang_types.ResolvedType {
        kind: kind,
        module: bytes.clone(module),
        name: bytes.clone(name),
        children: children,
        parameter_count: parameter_count,
        start: 0,
        end: 0,
    };
}

fn invalid_type() -> ref slang_types.ResolvedType {
    return make_type(slang_types.ResolvedKind.invalid, [], [], [], 0);
}

fn unit_type() -> ref slang_types.ResolvedType {
    return make_type(slang_types.ResolvedKind.unit, [], [], [], 0);
}

fn primitive_type(name: []u8) -> ref slang_types.ResolvedType {
    return make_type(slang_types.ResolvedKind.primitive, [], name, [], 0);
}

fn array_type(inner: ref slang_types.ResolvedType) -> ref slang_types.ResolvedType {
    return make_type(slang_types.ResolvedKind.array, [], [], [inner], 0);
}

fn const_array_type(inner: ref slang_types.ResolvedType) -> ref slang_types.ResolvedType {
    return make_type(slang_types.ResolvedKind.const_array, [], [], [inner], 0);
}

fn array_like(type: ref slang_types.ResolvedType) -> bool {
    return type.kind is slang_types.ResolvedKind.array ||
        type.kind is slang_types.ResolvedKind.const_array;
}

fn optional_type(inner: ref slang_types.ResolvedType) -> ref slang_types.ResolvedType {
    return make_type(slang_types.ResolvedKind.optional, [], [], [inner], 0);
}

fn reference_type(inner: ref slang_types.ResolvedType) -> ref slang_types.ResolvedType {
    return make_type(slang_types.ResolvedKind.reference, [], [], [inner], 0);
}

fn function_type(parameters: []ref slang_types.ResolvedType,
    result: ref slang_types.ResolvedType) -> ref slang_types.ResolvedType {
    var children: []ref slang_types.ResolvedType = [];
    for (parameter in parameters) { push(children, parameter); }
    push(children, result);
    return make_type(slang_types.ResolvedKind.function, [], [], children, len(parameters));
}

fn same(a: ref slang_types.ResolvedType, b: ref slang_types.ResolvedType) -> bool {
    if (a.kind != b.kind) { return false; }
    if (!bytes.equal(a.module, b.module) || !bytes.equal(a.name, b.name)) { return false; }
    if (a.parameter_count != b.parameter_count || len(a.children) != len(b.children)) { return false; }
    for (var i: u64 = 0; i < len(a.children); i += 1) {
        if (!same(a.children[i], b.children[i])) { return false; }
    }
    return true;
}

// Array capability conversion is intentionally shallow. A mutable []T can be
// used where const []T is expected only when T is exactly the same type. The
// conversion is not recursively lifted through optionals, refs, nominal type
// arguments, or another nested array layer.
fn compatible(expected: ref slang_types.ResolvedType,
    actual: ref slang_types.ResolvedType) -> bool {
    if (same(expected, actual)) { return true; }
    if (expected.kind is slang_types.ResolvedKind.const_array &&
        actual.kind is slang_types.ResolvedKind.array &&
        len(expected.children) == 1 && len(actual.children) == 1 &&
        same(expected.children[0], actual.children[0])) {
        return true;
    }
    return false;
}

fn binding_type(bindings: ref TypeBindings, name: []u8) -> ?ref slang_types.ResolvedType {
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

fn unify_type_exact(checker: ref Checker, pattern: ref slang_types.ResolvedType,
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
        if (!unify_type_exact(checker, pattern.children[i], actual.children[i], bindings, start, end, soft)) {
            return false;
        }
    }
    return true;
}

fn unify_type(checker: ref Checker, pattern: ref slang_types.ResolvedType,
    actual: ref slang_types.ResolvedType, bindings: ref TypeBindings,
    start: u64, end: u64, soft: bool) -> bool {
    if (pattern.kind is slang_types.ResolvedKind.const_array &&
        actual.kind is slang_types.ResolvedKind.array &&
        len(pattern.children) == 1 && len(actual.children) == 1) {
        return unify_type_exact(checker, pattern.children[0], actual.children[0],
            bindings, start, end, soft);
    }
    return unify_type_exact(checker, pattern, actual, bindings, start, end, soft);
}

fn contextual_expected(checker: ref Checker, template: ref slang_types.ResolvedType,
    value: ref slang_decls.Expr, bindings: ref TypeBindings) -> ?ref slang_types.ResolvedType {
    if (fully_bound(template, bindings)) {
        return some(substitute_type(template, bindings));
    }

    // String literals have a fixed u8 element type but their outer array
    // capability is contextual. Infer generic element variables from that
    // fixed information before typing the literal, so []T materializes a fresh
    // mutable string while const []T keeps the ordinary read-only inference.
    if (value.kind is slang_decls.ExprKind.string && array_like(template) &&
        len(template.children) == 1) {
        var u8 = primitive_type("u8");
        if (unify_type_exact(checker, template.children[0], u8, bindings,
            value.start, value.end, true) && fully_bound(template, bindings)) {
            return some(substitute_type(template, bindings));
        }
    }
    return none;
}

fn unify_result_expected(checker: ref Checker, result: ref slang_types.ResolvedType,
    expected: ref slang_types.ResolvedType, bindings: ref TypeBindings,
    start: u64, end: u64) {
    // A generic function returning mutable []T may be contextually consumed as
    // const []T. Infer through that one outer conversion without permitting a
    // const result to regain mutability or lifting qualification recursively.
    if (result.kind is slang_types.ResolvedKind.array &&
        expected.kind is slang_types.ResolvedKind.const_array &&
        len(result.children) == 1 && len(expected.children) == 1) {
        unify_type_exact(checker, result.children[0], expected.children[0],
            bindings, start, end, true);
        return;
    }
    unify_type(checker, result, expected, bindings, start, end, true);
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

fn is_primitive(type: ref slang_types.ResolvedType, name: []u8) -> bool {
    return type.kind is slang_types.ResolvedKind.primitive && bytes.equal(type.name, name);
}

fn integer(type: ref slang_types.ResolvedType) -> bool {
    if (!(type.kind is slang_types.ResolvedKind.primitive)) { return false; }
    return bytes.equal(type.name, "i8") || bytes.equal(type.name, "i16") ||
        bytes.equal(type.name, "i32") || bytes.equal(type.name, "i64") ||
        bytes.equal(type.name, "u8") || bytes.equal(type.name, "u16") ||
        bytes.equal(type.name, "u32") || bytes.equal(type.name, "u64");
}

fn integer_width(type: ref slang_types.ResolvedType) -> u64 {
    if (is_primitive(type, "i8") || is_primitive(type, "u8")) { return 8; }
    if (is_primitive(type, "i16") || is_primitive(type, "u16")) { return 16; }
    if (is_primitive(type, "i32") || is_primitive(type, "u32")) { return 32; }
    if (is_primitive(type, "i64") || is_primitive(type, "u64")) { return 64; }
    return 0;
}

fn signed_integer(type: ref slang_types.ResolvedType) -> bool {
    return is_primitive(type, "i8") || is_primitive(type, "i16") ||
        is_primitive(type, "i32") || is_primitive(type, "i64");
}

fn positive_integer_limit(type: ref slang_types.ResolvedType) -> u64 {
    var width = integer_width(type);
    if (signed_integer(type)) {
        if (width == 64) { return 9223372036854775807; }
        return ((1 as u64) << (width - 1)) - 1;
    }
    if (width == 64) { return 18446744073709551615; }
    return ((1 as u64) << width) - 1;
}

fn negative_integer_magnitude_limit(type: ref slang_types.ResolvedType) -> u64 {
    var width = integer_width(type);
    if (width == 64) { return 9223372036854775808; }
    return (1 as u64) << (width - 1);
}

fn positive_literal_fits(text: []u8, type: ref slang_types.ResolvedType) -> bool {
    match (strconv.parse_u64_literal(text)) {
        none { return false; }
        some(value) { return value <= positive_integer_limit(type); }
    }
}

fn negative_literal_fits(text: []u8, type: ref slang_types.ResolvedType) -> bool {
    if (!signed_integer(type)) { return false; }
    match (strconv.parse_u64_literal(text)) {
        none { return false; }
        some(value) { return value <= negative_integer_magnitude_limit(type); }
    }
}

fn floating(type: ref slang_types.ResolvedType) -> bool {
    return type.kind is slang_types.ResolvedKind.primitive &&
        (bytes.equal(type.name, "f32") || bytes.equal(type.name, "f64"));
}

fn numeric(type: ref slang_types.ResolvedType) -> bool {
    return integer(type) || floating(type);
}

fn push_error(checker: ref Checker, kind: ErrorKind, name: []u8, start: u64, end: u64) {
    push(checker.errors, Error {
        kind: kind,
        name: bytes.clone(name),
        start: start,
        end: end,
    });
}

fn record_expr(checker: ref Checker, expr: ref slang_decls.Expr,
    type: ref slang_types.ResolvedType) -> ref slang_types.ResolvedType {
    push(checker.expression_types, ExprType { start: expr.start, end: expr.end, type: type });
    return type;
}

fn require_same(checker: ref Checker, expected: ref slang_types.ResolvedType,
    actual: ref slang_types.ResolvedType, start: u64, end: u64) {
    if (!(expected.kind is slang_types.ResolvedKind.invalid) &&
        !(actual.kind is slang_types.ResolvedKind.invalid) && !same(expected, actual)) {
        push_error(checker, ErrorKind.type_mismatch, [], start, end);
    }
}

fn require_compatible(checker: ref Checker, expected: ref slang_types.ResolvedType,
    actual: ref slang_types.ResolvedType, start: u64, end: u64) {
    if (!(expected.kind is slang_types.ResolvedKind.invalid) &&
        !(actual.kind is slang_types.ResolvedKind.invalid) && !compatible(expected, actual)) {
        push_error(checker, ErrorKind.type_mismatch, [], start, end);
    }
}

fn resolve_syntax_type(checker: ref Checker, generics: []slang_decls.GenericParam,
    source: ref slang_decls.Type, declaration: []u8) -> ref slang_types.ResolvedType {
    var result = slang_types.resolve(checker.modules, 0, generics, source, [], declaration);
    if (len(result.errors) > 0) {
        push_error(checker, ErrorKind.invalid_type, source.name, source.start, source.end);
    }
    return result.type;
}

fn find_decl(checker: ref Checker, name: []u8) -> ?slang_decls.Decl {
    for (decl in checker.module.declarations.declarations) {
        if (bytes.equal(decl.name, name)) { return some(decl); }
    }
    return none;
}

fn find_symbol(checker: ref Checker, kind: slang_names.SymbolKind, name: []u8,
    start: u64) -> ?u64 {
    for (var i: u64 = 0; i < len(checker.names.symbols); i += 1) {
        var symbol = checker.names.symbols[i];
        if (symbol.kind == kind && bytes.equal(symbol.name, name) && symbol.start == start) {
            return some(i);
        }
    }
    return none;
}

fn find_top_symbol(checker: ref Checker, name: []u8) -> ?u64 {
    for (var i: u64 = 0; i < len(checker.names.symbols); i += 1) {
        var symbol = checker.names.symbols[i];
        if (symbol.kind is slang_names.SymbolKind.top_level && bytes.equal(symbol.name, name)) {
            return some(i);
        }
    }
    return none;
}

fn set_symbol_type(checker: ref Checker, symbol: u64, type: ref slang_types.ResolvedType) {
    for (var i: u64 = 0; i < len(checker.symbol_types); i += 1) {
        if (checker.symbol_types[i].symbol == symbol) {
            checker.symbol_types[i].type = type;
            return;
        }
    }
    push(checker.symbol_types, SymbolType { symbol: symbol, type: type });
}

fn symbol_type(checker: ref Checker, symbol: u64) -> ?ref slang_types.ResolvedType {
    for (item in checker.symbol_types) {
        if (item.symbol == symbol) { return some(item.type); }
    }
    return none;
}

fn value_use(checker: ref Checker, expr: ref slang_decls.Expr) -> ?slang_names.Use {
    for (use in checker.names.uses) {
        if (use.kind is slang_names.UseKind.value && use.start == expr.start && use.end == expr.end) {
            return some(use);
        }
    }
    return none;
}

fn push_candidate_scope(checker: ref Checker) {
    push(checker.candidates, CandidateScope { names: [], types: [] });
}

fn pop_candidate_scope(checker: ref Checker) {
    pop(checker.candidates);
}

fn set_candidate(checker: ref Checker, name: []u8, type: ref slang_types.ResolvedType) {
    var index = len(checker.candidates) - 1;
    push(checker.candidates[index].names, bytes.clone(name));
    push(checker.candidates[index].types, type);
}

fn candidate_type(checker: ref Checker, name: []u8) -> ?ref slang_types.ResolvedType {
    var i = len(checker.candidates);
    while (i > 0) {
        i -= 1;
        for (var j: u64 = 0; j < len(checker.candidates[i].names); j += 1) {
            if (bytes.equal(checker.candidates[i].names[j], name)) {
                return some(checker.candidates[i].types[j]);
            }
        }
    }
    return none;
}

fn first_dot(text: []u8) -> ?u64 {
    return bytes.find_byte(text, '.', 0);
}

fn tail_start(text: []u8) -> ?u64 {
    match (first_dot(text)) {
        none { return none; }
        some(dot) { return some(dot + 1); }
    }
}

fn nominal_decl(checker: ref Checker, type: ref slang_types.ResolvedType) -> ?slang_decls.Decl {
    var base = type;
    if (base.kind is slang_types.ResolvedKind.reference && len(base.children) == 1) {
        base = base.children[0];
    }
    if (!(base.kind is slang_types.ResolvedKind.nominal) || !bytes.equal(base.module, "main")) {
        return none;
    }
    return find_decl(checker, base.name);
}

fn field_type(checker: ref Checker, base: ref slang_types.ResolvedType, name: []u8,
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
}

fn apply_field_tail(checker: ref Checker, base: ref slang_types.ResolvedType,
    text: []u8, start: u64, end: u64) -> ref slang_types.ResolvedType {
    var type = base;
    match (tail_start(text)) {
        none { return type; }
        some(mut_pos) {
            var pos = mut_pos;
            while (pos < len(text)) {
                var next = bytes.find_byte(text, '.', pos);
                var finish = len(text);
                match (next) { none { } some(dot) { finish = dot; } }
                var field = bytes.slice(text, pos, finish);
                type = field_type(checker, type, field, start, end);
                match (next) {
                    none { return type; }
                    some(dot) { pos = dot + 1; }
                }
            }
            return type;
        }
    }
}

fn function_signature(checker: ref Checker, decl: slang_decls.Decl) -> ref slang_types.ResolvedType {
    if (len(decl.generics) > 0) {
        return invalid_type();
    }
    var parameters: []ref slang_types.ResolvedType = [];
    for (parameter in decl.parameters) {
        push(parameters, resolve_syntax_type(checker, decl.generics, parameter.type, decl.name));
    }
    var result = unit_type();
    match (decl.return_type) {
        none { }
        some(type) { result = resolve_syntax_type(checker, decl.generics, type, decl.name); }
    }
    return function_type(parameters, result);
}

fn enum_variant(checker: ref Checker, decl: slang_decls.Decl, name: []u8) -> ?slang_decls.Variant {
    for (variant in decl.variants) {
        if (bytes.equal(variant.name, name)) { return some(variant); }
    }
    return none;
}

fn enum_value_type(checker: ref Checker, decl: slang_decls.Decl,
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
                var expected_arg = contextual_expected(checker, template, arguments[i], bindings);
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
                require_compatible(checker, want, expr_type(checker, arguments[i], some(want)),
                    arguments[i].start, arguments[i].end);
            }
            match (expected) {
                none { }
                some(want) { require_compatible(checker, want, out, start, end); }
            }
            return out;
        }
    }
}

fn name_type(checker: ref Checker, expr: ref slang_decls.Expr,
    expected: ?ref slang_types.ResolvedType) -> ref slang_types.ResolvedType {
    match (value_use(checker, expr)) {
        none {
            push_error(checker, ErrorKind.not_a_value, expr.text, expr.start, expr.end);
            return invalid_type();
        }
        some(use) {
            if (use.status is slang_names.UseStatus.pattern_candidate) {
                match (candidate_type(checker, use.root)) {
                    some(type) { return apply_field_tail(checker, type, expr.text, expr.start, expr.end); }
                    none {
                        push_error(checker, ErrorKind.not_a_value, use.root, expr.start, expr.end);
                        return invalid_type();
                    }
                }
            }
            if (!(use.status is slang_names.UseStatus.resolved)) {
                return invalid_type();
            }
            match (use.symbol) {
                none { return invalid_type(); }
                some(symbol_index) {
                    var symbol = checker.names.symbols[symbol_index];
                    if (symbol.kind is slang_names.SymbolKind.builtin) {
                        push_error(checker, ErrorKind.not_a_value, symbol.name, expr.start, expr.end);
                        return invalid_type();
                    }
                    if (symbol.kind is slang_names.SymbolKind.import_binding) {
                        push_error(checker, ErrorKind.unsupported_feature, symbol.name, expr.start, expr.end);
                        return invalid_type();
                    }
                    match (symbol_type(checker, symbol_index)) {
                        some(type) {
                            return apply_field_tail(checker, type, expr.text, expr.start, expr.end);
                        }
                        none { }
                    }

                    if (symbol.kind is slang_names.SymbolKind.top_level) {
                        match (find_decl(checker, symbol.name)) {
                            none { }
                            some(decl) {
                                if (decl.kind is slang_decls.DeclKind.enumeration) {
                                    match (tail_start(expr.text)) {
                                        none { }
                                        some(pos) {
                                            var variant = bytes.slice(expr.text, pos, len(expr.text));
                                            return enum_value_type(checker, decl, variant, expected, [], expr.start, expr.end);
                                        }
                                    }
                                }
                            }
                        }
                    }

                    push_error(checker, ErrorKind.not_a_value, symbol.name, expr.start, expr.end);
                    return invalid_type();
                }
            }
        }
    }
}

fn binop(checker: ref Checker, op: []u8, left: ref slang_types.ResolvedType,
    right: ref slang_types.ResolvedType, start: u64, end: u64) -> ref slang_types.ResolvedType {
    if (bytes.equal(op, "&&") || bytes.equal(op, "||")) {
        if (!is_primitive(left, "bool") || !is_primitive(right, "bool")) {
            push_error(checker, ErrorKind.boolean_required, op, start, end);
        }
        return primitive_type("bool");
    }

    if (bytes.equal(op, "==") || bytes.equal(op, "!=")) {
        require_same(checker, left, right, start, end);
        var ok = is_primitive(left, "bool") || numeric(left) ||
            left.kind is slang_types.ResolvedKind.reference;
        if (!ok) { push_error(checker, ErrorKind.equality_unsupported, op, start, end); }
        return primitive_type("bool");
    }

    if (bytes.equal(op, "<") || bytes.equal(op, "<=") || bytes.equal(op, ">") || bytes.equal(op, ">=")) {
        require_same(checker, left, right, start, end);
        if (!numeric(left)) { push_error(checker, ErrorKind.ordering_unsupported, op, start, end); }
        return primitive_type("bool");
    }

    if (bytes.equal(op, "<<") || bytes.equal(op, ">>")) {
        if (!integer(left)) { push_error(checker, ErrorKind.integer_required, op, start, end); }
        require_same(checker, primitive_type("u64"), right, start, end);
        return left;
    }

    if (bytes.equal(op, "&") || bytes.equal(op, "|") || bytes.equal(op, "^")) {
        if (!integer(left) || !integer(right)) {
            push_error(checker, ErrorKind.integer_required, op, start, end);
        }
        require_same(checker, left, right, start, end);
        return left;
    }

    if (bytes.equal(op, "+") || bytes.equal(op, "-") || bytes.equal(op, "*") ||
        bytes.equal(op, "/") || bytes.equal(op, "%")) {
        if (!numeric(left) || !numeric(right)) {
            push_error(checker, ErrorKind.numeric_required, op, start, end);
        }
        if (bytes.equal(op, "%") && floating(left)) {
            push_error(checker, ErrorKind.integer_required, op, start, end);
        }
        require_same(checker, left, right, start, end);
        return left;
    }

    push_error(checker, ErrorKind.unsupported_feature, op, start, end);
    return invalid_type();
}

fn builtin_call(checker: ref Checker, name: []u8, args: []ref slang_decls.Expr,
    start: u64, end: u64) -> ref slang_types.ResolvedType {
    if (bytes.equal(name, "len")) {
        if (len(args) != 1) { push_error(checker, ErrorKind.arity, name, start, end); return invalid_type(); }
        var array = expr_type(checker, args[0], none);
        if (!array_like(array)) {
            push_error(checker, ErrorKind.array_required, name, start, end);
        }
        return primitive_type("u64");
    }
    if (bytes.equal(name, "push")) {
        if (len(args) != 2) { push_error(checker, ErrorKind.arity, name, start, end); return invalid_type(); }
        var array = expr_type(checker, args[0], none);
        if (array.kind is slang_types.ResolvedKind.const_array) {
            push_error(checker, ErrorKind.mutable_array_required, name, args[0].start, args[0].end);
            return unit_type();
        }
        if (!(array.kind is slang_types.ResolvedKind.array) || len(array.children) != 1) {
            push_error(checker, ErrorKind.array_required, name, start, end);
            return unit_type();
        }
        var value = expr_type(checker, args[1], some(array.children[0]));
        require_compatible(checker, array.children[0], value, args[1].start, args[1].end);
        return unit_type();
    }
    if (bytes.equal(name, "pop")) {
        if (len(args) != 1) { push_error(checker, ErrorKind.arity, name, start, end); return invalid_type(); }
        var array = expr_type(checker, args[0], none);
        if (array.kind is slang_types.ResolvedKind.const_array) {
            push_error(checker, ErrorKind.mutable_array_required, name, args[0].start, args[0].end);
            if (len(array.children) == 1) { return array.children[0]; }
            return invalid_type();
        }
        if (!(array.kind is slang_types.ResolvedKind.array) || len(array.children) != 1) {
            push_error(checker, ErrorKind.array_required, name, start, end);
            return invalid_type();
        }
        return array.children[0];
    }
    if (bytes.equal(name, "splice")) {
        if (len(args) != 4) { push_error(checker, ErrorKind.arity, name, start, end); return invalid_type(); }
        var array = expr_type(checker, args[0], none);
        if (array.kind is slang_types.ResolvedKind.const_array) {
            push_error(checker, ErrorKind.mutable_array_required, name, args[0].start, args[0].end);
            return unit_type();
        }
        if (!(array.kind is slang_types.ResolvedKind.array) || len(array.children) != 1) {
            push_error(checker, ErrorKind.array_required, name, start, end);
            return unit_type();
        }
        require_same(checker, primitive_type("u64"), expr_type(checker, args[1], some(primitive_type("u64"))), args[1].start, args[1].end);
        require_same(checker, primitive_type("u64"), expr_type(checker, args[2], some(primitive_type("u64"))), args[2].start, args[2].end);
        var replacement = const_array_type(array.children[0]);
        require_compatible(checker, replacement, expr_type(checker, args[3], some(replacement)),
            args[3].start, args[3].end);
        return unit_type();
    }
    return invalid_type();
}

fn instantiate_generic_call(checker: ref Checker, decl: slang_decls.Decl,
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
        some(want) { unify_result_expected(checker, result, want, bindings, start, end); }
    }
    for (var i: u64 = 0; i < len(args); i += 1) {
        var template = resolve_syntax_type(checker, decl.generics, decl.parameters[i].type, decl.name);
        var expected_arg = contextual_expected(checker, template, args[i], bindings);
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
        require_compatible(checker, want, expr_type(checker, args[i], some(want)), args[i].start, args[i].end);
    }
    return substitute_type(result, bindings);
}

fn call_type(checker: ref Checker, expr: ref slang_decls.Expr,
    expected: ?ref slang_types.ResolvedType) -> ref slang_types.ResolvedType {
    var callee = expr.children[0];
    var args: []ref slang_decls.Expr = [];
    for (var i: u64 = 1; i < len(expr.children); i += 1) { push(args, expr.children[i]); }

    if (callee.kind is slang_decls.ExprKind.name) {
        match (value_use(checker, callee)) {
            none { }
            some(use) {
                match (use.symbol) {
                    none { }
                    some(symbol_index) {
                        var symbol = checker.names.symbols[symbol_index];
                        if (symbol.kind is slang_names.SymbolKind.builtin) {
                            return builtin_call(checker, symbol.name, args, expr.start, expr.end);
                        }
                        if (symbol.kind is slang_names.SymbolKind.top_level) {
                            match (find_decl(checker, symbol.name)) {
                                none { }
                                some(decl) {
                                    if (decl.kind is slang_decls.DeclKind.enumeration) {
                                        match (tail_start(callee.text)) {
                                            none { }
                                            some(pos) {
                                                var variant = bytes.slice(callee.text, pos, len(callee.text));
                                                return enum_value_type(checker, decl, variant, expected, args, expr.start, expr.end);
                                            }
                                        }
                                    }
                                    if (decl.kind is slang_decls.DeclKind.function && len(decl.generics) > 0) {
                                        return instantiate_generic_call(checker, decl, args, expected, expr.start, expr.end);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    var callee_type = expr_type(checker, callee, none);
    if (!(callee_type.kind is slang_types.ResolvedKind.function)) {
        push_error(checker, ErrorKind.function_required, [], expr.start, expr.end);
        return invalid_type();
    }
    if (callee_type.parameter_count != len(args) || len(callee_type.children) != len(args) + 1) {
        push_error(checker, ErrorKind.arity, [], expr.start, expr.end);
        return invalid_type();
    }
    for (var i: u64 = 0; i < len(args); i += 1) {
        var actual = expr_type(checker, args[i], some(callee_type.children[i]));
        require_compatible(checker, callee_type.children[i], actual, args[i].start, args[i].end);
    }
    return callee_type.children[len(callee_type.children) - 1];
}

fn struct_literal_type(checker: ref Checker, expr: ref slang_decls.Expr,
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
                        var expected_field = contextual_expected(checker, template, supplied.value, bindings);
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
                        require_compatible(checker, want, expr_type(checker, supplied.value, some(want)),
                            supplied.start, supplied.end);
                    }
                }
            }
            match (expected) { none { } some(want) { require_compatible(checker, want, out, expr.start, expr.end); } }
            return out;
        }
    }
}

fn expr_type(checker: ref Checker, expr: ref slang_decls.Expr,
    expected: ?ref slang_types.ResolvedType) -> ref slang_types.ResolvedType {
    var type = invalid_type();

    if (expr.kind is slang_decls.ExprKind.unit) {
        type = unit_type();
    } else if (expr.kind is slang_decls.ExprKind.boolean) {
        type = primitive_type("bool");
    } else if (expr.kind is slang_decls.ExprKind.byte) {
        type = primitive_type("u8");
    } else if (expr.kind is slang_decls.ExprKind.string) {
        var u8 = primitive_type("u8");
        var mutable_context = false;
        match (expected) {
            none { }
            some(want) {
                if (want.kind is slang_types.ResolvedKind.array && len(want.children) == 1 &&
                    same(want.children[0], u8)) {
                    mutable_context = true;
                }
            }
        }
        if (mutable_context) { type = array_type(u8); }
        else { type = const_array_type(u8); }
    } else if (expr.kind is slang_decls.ExprKind.integer) {
        type = primitive_type("i64");
        match (expected) { none { } some(want) { if (integer(want)) { type = want; } } }
        if (!positive_literal_fits(expr.text, type)) {
            push_error(checker, ErrorKind.literal_range, expr.text, expr.start, expr.end);
        }
    } else if (expr.kind is slang_decls.ExprKind.float) {
        type = primitive_type("f64");
        match (expected) { none { } some(want) { if (floating(want)) { type = want; } } }
    } else if (expr.kind is slang_decls.ExprKind.none_value) {
        match (expected) {
            some(want) {
                if (want.kind is slang_types.ResolvedKind.optional) { type = want; }
                else { push_error(checker, ErrorKind.ambiguous_value, "none", expr.start, expr.end); }
            }
            none { push_error(checker, ErrorKind.ambiguous_value, "none", expr.start, expr.end); }
        }
    } else if (expr.kind is slang_decls.ExprKind.some_value) {
        var inner_expected: ?ref slang_types.ResolvedType = none;
        match (expected) {
            none { }
            some(want) {
                if (want.kind is slang_types.ResolvedKind.optional && len(want.children) == 1) {
                    inner_expected = some(want.children[0]);
                }
            }
        }
        var inner = expr_type(checker, expr.children[0], inner_expected);
        type = optional_type(inner);
    } else if (expr.kind is slang_decls.ExprKind.name) {
        type = name_type(checker, expr, expected);
    } else if (expr.kind is slang_decls.ExprKind.array) {
        var element: ?ref slang_types.ResolvedType = none;
        match (expected) {
            some(want) { if (array_like(want) && len(want.children) == 1) { element = some(want.children[0]); } }
            none { }
        }
        if (len(expr.children) == 0 && element is none) {
            push_error(checker, ErrorKind.ambiguous_value, "[]", expr.start, expr.end);
        } else {
            if (element is none && len(expr.children) > 0) { element = some(expr_type(checker, expr.children[0], none)); }
            match (element) {
                none { }
                some(elem) {
                    for (child in expr.children) {
                        require_compatible(checker, elem, expr_type(checker, child, some(elem)), child.start, child.end);
                    }
                    type = array_type(elem);
                }
            }
        }
    } else if (expr.kind is slang_decls.ExprKind.repeat) {
        var elem_expected: ?ref slang_types.ResolvedType = none;
        match (expected) {
            some(want) { if (array_like(want) && len(want.children) == 1) { elem_expected = some(want.children[0]); } }
            none { }
        }
        var elem = expr_type(checker, expr.children[0], elem_expected);
        require_same(checker, primitive_type("u64"), expr_type(checker, expr.children[1], some(primitive_type("u64"))), expr.children[1].start, expr.children[1].end);
        type = array_type(elem);
    } else if (expr.kind is slang_decls.ExprKind.unary) {
        var child_expected = expected;
        var child = invalid_type();
        var handled_signed_min = false;
        if (bytes.equal(expr.op, "-") && expr.children[0].kind is slang_decls.ExprKind.integer) {
            match (expected) {
                none { }
                some(want) {
                    if (signed_integer(want)) {
                        if (!negative_literal_fits(expr.children[0].text, want)) {
                            push_error(checker, ErrorKind.literal_range, expr.children[0].text,
                                expr.start, expr.end);
                        }
                        child = record_expr(checker, expr.children[0], want);
                        handled_signed_min = true;
                    }
                }
            }
        }
        if (!handled_signed_min) { child = expr_type(checker, expr.children[0], child_expected); }
        if (bytes.equal(expr.op, "!")) {
            if (!is_primitive(child, "bool")) { push_error(checker, ErrorKind.boolean_required, expr.op, expr.start, expr.end); }
        } else if (bytes.equal(expr.op, "~")) {
            if (!integer(child)) { push_error(checker, ErrorKind.integer_required, expr.op, expr.start, expr.end); }
        } else if (bytes.equal(expr.op, "-")) {
            if (!numeric(child)) { push_error(checker, ErrorKind.numeric_required, expr.op, expr.start, expr.end); }
        }
        type = child;
    } else if (expr.kind is slang_decls.ExprKind.dereference) {
        var child = expr_type(checker, expr.children[0], none);
        if (!(child.kind is slang_types.ResolvedKind.reference) || len(child.children) != 1) {
            push_error(checker, ErrorKind.reference_required, [], expr.start, expr.end);
        } else { type = child.children[0]; }
    } else if (expr.kind is slang_decls.ExprKind.binary) {
        var left_expected = expected;
        if (bytes.equal(expr.op, "&&") || bytes.equal(expr.op, "||")) {
            left_expected = some(primitive_type("bool"));
        } else if (bytes.equal(expr.op, "==") || bytes.equal(expr.op, "!=") ||
            bytes.equal(expr.op, "<") || bytes.equal(expr.op, "<=") ||
            bytes.equal(expr.op, ">") || bytes.equal(expr.op, ">=")) {
            left_expected = none;
        }
        var left = expr_type(checker, expr.children[0], left_expected);
        var right_expected: ?ref slang_types.ResolvedType = some(left);
        if (bytes.equal(expr.op, "&&") || bytes.equal(expr.op, "||")) {
            right_expected = some(primitive_type("bool"));
        } else if (bytes.equal(expr.op, "<<") || bytes.equal(expr.op, ">>")) {
            right_expected = some(primitive_type("u64"));
        }
        var right = expr_type(checker, expr.children[1], right_expected);
        type = binop(checker, expr.op, left, right, expr.start, expr.end);
    } else if (expr.kind is slang_decls.ExprKind.cast) {
        var from = expr_type(checker, expr.children[0], none);
        match (expr.type) {
            none { }
            some(target_syntax) {
                var to = resolve_syntax_type(checker, checker.current_generics, target_syntax, checker.current_decl);
                if (!numeric(from) || !numeric(to)) { push_error(checker, ErrorKind.bad_cast, [], expr.start, expr.end); }
                type = to;
            }
        }
    } else if (expr.kind is slang_decls.ExprKind.allocate) {
        var inner_expected: ?ref slang_types.ResolvedType = none;
        match (expected) { some(want) { if (want.kind is slang_types.ResolvedKind.reference && len(want.children) == 1) { inner_expected = some(want.children[0]); } } none { } }
        type = reference_type(expr_type(checker, expr.children[0], inner_expected));
    } else if (expr.kind is slang_decls.ExprKind.index) {
        var array = expr_type(checker, expr.children[0], none);
        require_same(checker, primitive_type("u64"), expr_type(checker, expr.children[1], some(primitive_type("u64"))), expr.children[1].start, expr.children[1].end);
        if (!array_like(array) || len(array.children) != 1) {
            push_error(checker, ErrorKind.array_required, [], expr.start, expr.end);
        } else { type = array.children[0]; }
    } else if (expr.kind is slang_decls.ExprKind.field) {
        type = field_type(checker, expr_type(checker, expr.children[0], none), expr.text, expr.start, expr.end);
    } else if (expr.kind is slang_decls.ExprKind.struct_literal) {
        type = struct_literal_type(checker, expr, expected);
    } else if (expr.kind is slang_decls.ExprKind.call) {
        type = call_type(checker, expr, expected);
    } else if (expr.kind is slang_decls.ExprKind.anonymous_function) {
        var old_return = checker.return_type;
        var old_decl = checker.current_decl;
        var old_candidates = checker.candidates;
        checker.candidates = [];
        var parameters: []ref slang_types.ResolvedType = [];
        for (parameter in expr.parameters) {
            var ptype = resolve_syntax_type(checker, checker.current_generics, parameter.type, old_decl);
            push(parameters, ptype);
            match (find_symbol(checker, slang_names.SymbolKind.anonymous_parameter, parameter.name, parameter.start)) {
                none { }
                some(symbol) { set_symbol_type(checker, symbol, ptype); }
            }
        }
        var result = unit_type();
        match (expr.type) { none { } some(syntax) { result = resolve_syntax_type(checker, checker.current_generics, syntax, old_decl); } }
        checker.return_type = result;
        check_block(checker, expr.body);
        checker.return_type = old_return;
        checker.current_decl = old_decl;
        checker.candidates = old_candidates;
        type = function_type(parameters, result);
    } else if (expr.kind is slang_decls.ExprKind.pattern_test) {
        var subject = expr_type(checker, expr.children[0], none);
        match (expr.pattern) { none { } some(pattern) { check_pattern(checker, pattern, subject, false); } }
        type = primitive_type("bool");
    }

    match (expected) { none { } some(want) { require_compatible(checker, want, type, expr.start, expr.end); } }
    return record_expr(checker, expr, type);
}

fn place_try(checker: ref Checker, expr: ref slang_decls.Expr, report: bool) -> ?ref slang_types.ResolvedType {
    if (expr.kind is slang_decls.ExprKind.name) {
        match (value_use(checker, expr)) {
            none { }
            some(use) {
                if (use.status is slang_names.UseStatus.pattern_candidate) {
                    match (candidate_type(checker, use.root)) {
                        none { }
                        some(type) { return some(apply_field_tail(checker, type, expr.text, expr.start, expr.end)); }
                    }
                }
                match (use.symbol) {
                    none { }
                    some(symbol_index) {
                        var kind = checker.names.symbols[symbol_index].kind;
                        var local = kind is slang_names.SymbolKind.parameter || kind is slang_names.SymbolKind.local ||
                            kind is slang_names.SymbolKind.loop_binding || kind is slang_names.SymbolKind.pattern_binding ||
                            kind is slang_names.SymbolKind.anonymous_parameter;
                        if (local) {
                            match (symbol_type(checker, symbol_index)) {
                                none { }
                                some(type) { return some(apply_field_tail(checker, type, expr.text, expr.start, expr.end)); }
                            }
                        }
                    }
                }
            }
        }
        if (report) { push_error(checker, ErrorKind.not_assignable, expr.text, expr.start, expr.end); }
        return none;
    }

    if (expr.kind is slang_decls.ExprKind.index) {
        var base = expr_type(checker, expr.children[0], none);
        require_same(checker, primitive_type("u64"), expr_type(checker, expr.children[1], some(primitive_type("u64"))), expr.children[1].start, expr.children[1].end);
        if (base.kind is slang_types.ResolvedKind.array && len(base.children) == 1) { return some(base.children[0]); }
        if (base.kind is slang_types.ResolvedKind.const_array) {
            if (report) { push_error(checker, ErrorKind.not_assignable, [], expr.start, expr.end); }
            return none;
        }
        if (report) { push_error(checker, ErrorKind.array_required, [], expr.start, expr.end); }
        return none;
    }

    if (expr.kind is slang_decls.ExprKind.dereference) {
        var base = expr_type(checker, expr.children[0], none);
        if (base.kind is slang_types.ResolvedKind.reference && len(base.children) == 1) { return some(base.children[0]); }
        if (report) { push_error(checker, ErrorKind.reference_required, [], expr.start, expr.end); }
        return none;
    }

    if (expr.kind is slang_decls.ExprKind.field) {
        match (place_try(checker, expr.children[0], false)) {
            some(base) { return some(field_type(checker, base, expr.text, expr.start, expr.end)); }
            none { }
        }
        var base = expr_type(checker, expr.children[0], none);
        if (base.kind is slang_types.ResolvedKind.reference) {
            return some(field_type(checker, base, expr.text, expr.start, expr.end));
        }
        if (report) { push_error(checker, ErrorKind.not_assignable, expr.text, expr.start, expr.end); }
        return none;
    }

    if (report) { push_error(checker, ErrorKind.not_assignable, [], expr.start, expr.end); }
    return none;
}

fn bind_pattern_symbol(checker: ref Checker, pattern: ref slang_decls.Pattern,
    type: ref slang_types.ResolvedType) {
    match (find_symbol(checker, slang_names.SymbolKind.pattern_binding, pattern.name, pattern.start)) {
        none { }
        some(symbol) { set_symbol_type(checker, symbol, type); }
    }
}

fn check_pattern(checker: ref Checker, pattern: ref slang_decls.Pattern,
    subject: ref slang_types.ResolvedType, bind: bool) {
    if (pattern.kind is slang_decls.PatternKind.wildcard) { return; }
    if (pattern.kind is slang_decls.PatternKind.unit) {
        require_same(checker, unit_type(), subject, pattern.start, pattern.end); return;
    }
    if (pattern.kind is slang_decls.PatternKind.none_value) {
        if (!(subject.kind is slang_types.ResolvedKind.optional)) { push_error(checker, ErrorKind.bad_pattern, "none", pattern.start, pattern.end); }
        return;
    }
    if (pattern.kind is slang_decls.PatternKind.some_value) {
        if (!(subject.kind is slang_types.ResolvedKind.optional) || len(subject.children) != 1) {
            push_error(checker, ErrorKind.bad_pattern, "some", pattern.start, pattern.end); return;
        }
        if (bind) {
            for (child in pattern.children) {
                if (child.kind is slang_decls.PatternKind.binding) { bind_pattern_symbol(checker, child, subject.children[0]); }
            }
        }
        return;
    }
    if (pattern.kind is slang_decls.PatternKind.boolean) {
        require_same(checker, primitive_type("bool"), subject, pattern.start, pattern.end); return;
    }
    if (pattern.kind is slang_decls.PatternKind.integer) {
        if (!integer(subject)) { push_error(checker, ErrorKind.bad_pattern, pattern.name, pattern.start, pattern.end); }
        return;
    }
    if (pattern.kind is slang_decls.PatternKind.byte) {
        require_same(checker, primitive_type("u8"), subject, pattern.start, pattern.end); return;
    }
    if (pattern.kind is slang_decls.PatternKind.binding) {
        // A bare outer name is contextually a fieldless enum variant if one of
        // the subject enum's variants has that spelling; otherwise it binds.
        var is_variant = false;
        if (subject.kind is slang_types.ResolvedKind.nominal && bytes.equal(subject.module, "main")) {
            match (find_decl(checker, subject.name)) {
                none { }
                some(decl) {
                    if (decl.kind is slang_decls.DeclKind.enumeration) {
                        match (enum_variant(checker, decl, pattern.name)) {
                            none { }
                            some(variant) { if (len(variant.payload) == 0) { is_variant = true; } }
                        }
                    }
                }
            }
        }
        if (!is_variant && bind) { set_candidate(checker, pattern.name, subject); }
        return;
    }
    if (pattern.kind is slang_decls.PatternKind.constructor) {
        if (!(subject.kind is slang_types.ResolvedKind.nominal) || !bytes.equal(subject.module, "main")) {
            push_error(checker, ErrorKind.bad_pattern, pattern.name, pattern.start, pattern.end); return;
        }
        match (find_decl(checker, subject.name)) {
            none { push_error(checker, ErrorKind.bad_pattern, pattern.name, pattern.start, pattern.end); }
            some(decl) {
                if (!(decl.kind is slang_decls.DeclKind.enumeration) || len(decl.generics) != len(subject.children)) {
                    push_error(checker, ErrorKind.bad_pattern, pattern.name, pattern.start, pattern.end); return;
                }
                var bindings = new TypeBindings { names: [], types: [] };
                for (var gi: u64 = 0; gi < len(decl.generics); gi += 1) {
                    bind_type(checker, bindings, decl.generics[gi].name, subject.children[gi], pattern.start, pattern.end, false);
                }
                var variant_name = pattern.name;
                match (tail_start(pattern.name)) { none { } some(pos) { variant_name = bytes.slice(pattern.name, pos, len(pattern.name)); } }
                match (enum_variant(checker, decl, variant_name)) {
                    none { push_error(checker, ErrorKind.bad_pattern, pattern.name, pattern.start, pattern.end); }
                    some(variant) {
                        if (len(variant.payload) != len(pattern.children)) {
                            push_error(checker, ErrorKind.arity, pattern.name, pattern.start, pattern.end); return;
                        }
                        if (bind) {
                            for (var i: u64 = 0; i < len(pattern.children); i += 1) {
                                if (pattern.children[i].kind is slang_decls.PatternKind.binding) {
                                    var template = resolve_syntax_type(checker, decl.generics, variant.payload[i], decl.name);
                                    bind_pattern_symbol(checker, pattern.children[i], substitute_type(template, bindings));
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

fn check_condition(checker: ref Checker, expr: ref slang_decls.Expr, allow_binding: bool) {
    if (expr.kind is slang_decls.ExprKind.pattern_test && len(expr.children) == 1) {
        var subject = expr_type(checker, expr.children[0], none);
        match (expr.pattern) {
            none { }
            some(pattern) { check_pattern(checker, pattern, subject, allow_binding); }
        }
        return;
    }
    require_same(checker, primitive_type("bool"), expr_type(checker, expr, some(primitive_type("bool"))), expr.start, expr.end);
}

struct PatternCoverage {
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

    // Integer, byte, float, refs, mutable/const arrays, function values and
    // future open domains cannot be enumerated by a finite literal-arm list.
    push_error(checker, ErrorKind.non_exhaustive_match, [], stmt.start, stmt.end);
}

fn check_stmt(checker: ref Checker, stmt: ref slang_decls.Stmt) {
    if (stmt.kind is slang_decls.StmtKind.variable) {
        var expected: ?ref slang_types.ResolvedType = none;
        match (stmt.type) { none { } some(syntax) { expected = some(resolve_syntax_type(checker, checker.current_generics, syntax, checker.current_decl)); } }
        var actual = expr_type(checker, stmt.expressions[0], expected);
        var type = actual;
        match (expected) { none { } some(want) { require_compatible(checker, want, actual, stmt.start, stmt.end); type = want; } }
        match (find_symbol(checker, slang_names.SymbolKind.local, stmt.name, stmt.start)) {
            none { }
            some(symbol) { set_symbol_type(checker, symbol, type); }
        }
        return;
    }

    if (stmt.kind is slang_decls.StmtKind.assignment) {
        match (place_try(checker, stmt.expressions[0], true)) {
            none { }
            some(place) {
                var want = place;
                if (bytes.equal(stmt.op, "<<=") || bytes.equal(stmt.op, ">>=")) { want = primitive_type("u64"); }
                var actual = expr_type(checker, stmt.expressions[1], some(want));
                if (bytes.equal(stmt.op, "=")) { require_compatible(checker, place, actual, stmt.start, stmt.end); }
                else {
                    var op = bytes.slice(stmt.op, 0, len(stmt.op) - 1);
                    binop(checker, op, place, actual, stmt.start, stmt.end);
                }
            }
        }
        return;
    }

    if (stmt.kind is slang_decls.StmtKind.expression) {
        if (len(stmt.expressions) != 1 || !(stmt.expressions[0].kind is slang_decls.ExprKind.call)) {
            push_error(checker, ErrorKind.bad_expression_statement, [], stmt.start, stmt.end);
        } else { expr_type(checker, stmt.expressions[0], none); }
        return;
    }

    if (stmt.kind is slang_decls.StmtKind.conditional) {
        push_candidate_scope(checker);
        check_condition(checker, stmt.expressions[0], true);
        check_block(checker, stmt.body);
        pop_candidate_scope(checker);
        check_block(checker, stmt.alternate);
        return;
    }

    if (stmt.kind is slang_decls.StmtKind.while_loop) {
        checker.loop_depth += 1;
        push_candidate_scope(checker);
        check_condition(checker, stmt.expressions[0], true);
        check_block(checker, stmt.body);
        pop_candidate_scope(checker);
        checker.loop_depth -= 1;
        return;
    }

    if (stmt.kind is slang_decls.StmtKind.for_loop) {
        checker.loop_depth += 1;
        match (stmt.init) { none { } some(init) { check_stmt(checker, init); } }
        for (condition in stmt.expressions) { check_condition(checker, condition, false); }
        match (stmt.step) { none { } some(step) { check_stmt(checker, step); } }
        check_block(checker, stmt.body);
        checker.loop_depth -= 1;
        return;
    }

    if (stmt.kind is slang_decls.StmtKind.for_in) {
        var array = expr_type(checker, stmt.expressions[0], none);
        if (!array_like(array) || len(array.children) != 1) {
            push_error(checker, ErrorKind.array_required, stmt.name, stmt.start, stmt.end);
        } else {
            match (find_symbol(checker, slang_names.SymbolKind.loop_binding, stmt.name, stmt.start)) {
                none { }
                some(symbol) { set_symbol_type(checker, symbol, array.children[0]); }
            }
        }
        checker.loop_depth += 1;
        check_block(checker, stmt.body);
        checker.loop_depth -= 1;
        return;
    }

    if (stmt.kind is slang_decls.StmtKind.match_stmt) {
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

    if (stmt.kind is slang_decls.StmtKind.return_stmt) {
        if (len(stmt.expressions) == 0) { require_same(checker, checker.return_type, unit_type(), stmt.start, stmt.end); }
        else { require_compatible(checker, checker.return_type, expr_type(checker, stmt.expressions[0], some(checker.return_type)), stmt.start, stmt.end); }
        return;
    }

    if (stmt.kind is slang_decls.StmtKind.break_stmt) {
        if (checker.loop_depth == 0) { push_error(checker, ErrorKind.break_outside_loop, [], stmt.start, stmt.end); }
        return;
    }
    if (stmt.kind is slang_decls.StmtKind.continue_stmt) {
        if (checker.loop_depth == 0) { push_error(checker, ErrorKind.continue_outside_loop, [], stmt.start, stmt.end); }
        return;
    }
    // trap has no additional type rules.
}

fn check_block(checker: ref Checker, body: []ref slang_decls.Stmt) {
    for (stmt in body) { check_stmt(checker, stmt); }
}

fn stmt_returns(stmt: ref slang_decls.Stmt) -> bool {
    if (stmt.kind is slang_decls.StmtKind.return_stmt || stmt.kind is slang_decls.StmtKind.trap_stmt) { return true; }
    if (stmt.kind is slang_decls.StmtKind.conditional) {
        return len(stmt.alternate) > 0 && block_returns(stmt.body) && block_returns(stmt.alternate);
    }
    if (stmt.kind is slang_decls.StmtKind.match_stmt) {
        if (len(stmt.arms) == 0) { return false; }
        for (arm in stmt.arms) { if (!block_returns(arm.body)) { return false; } }
        return true;
    }
    return false;
}

fn block_returns(body: []ref slang_decls.Stmt) -> bool {
    for (stmt in body) { if (stmt_returns(stmt)) { return true; } }
    return false;
}

fn seed_top_level(checker: ref Checker) {
    for (decl in checker.module.declarations.declarations) {
        match (find_top_symbol(checker, decl.name)) {
            none { }
            some(symbol) {
                if (decl.kind is slang_decls.DeclKind.constant) {
                    match (decl.value_type) {
                        none { }
                        some(syntax) { set_symbol_type(checker, symbol, resolve_syntax_type(checker, decl.generics, syntax, decl.name)); }
                    }
                } else if (decl.kind is slang_decls.DeclKind.function && len(decl.generics) == 0) {
                    set_symbol_type(checker, symbol, function_signature(checker, decl));
                }
            }
        }
    }
}

fn check_decl(checker: ref Checker, decl: slang_decls.Decl) {
    checker.current_decl = bytes.clone(decl.name);
    if (decl.kind is slang_decls.DeclKind.constant) {
        match (decl.value) {
            none { }
            some(value) {
                match (decl.value_type) {
                    none { }
                    some(syntax) {
                        var expected = resolve_syntax_type(checker, decl.generics, syntax, decl.name);
                        require_compatible(checker, expected, expr_type(checker, value, some(expected)), value.start, value.end);
                    }
                }
            }
        }
        return;
    }
    if (!(decl.kind is slang_decls.DeclKind.function)) { return; }
    checker.current_generics = decl.generics;

    for (parameter in decl.parameters) {
        var type = resolve_syntax_type(checker, decl.generics, parameter.type, decl.name);
        match (find_symbol(checker, slang_names.SymbolKind.parameter, parameter.name, parameter.start)) {
            none { }
            some(symbol) { set_symbol_type(checker, symbol, type); }
        }
    }
    var result = unit_type();
    match (decl.return_type) { none { } some(syntax) { result = resolve_syntax_type(checker, decl.generics, syntax, decl.name); } }
    checker.return_type = result;
    checker.loop_depth = 0;
    checker.candidates = [];
    check_block(checker, decl.body);
    if (!(result.kind is slang_types.ResolvedKind.unit) && !block_returns(decl.body)) {
        push_error(checker, ErrorKind.missing_return, decl.name, decl.start, decl.end);
    }
}

pub fn check(source: []u8) -> CheckResult {
    var module = slang_types.parse_module("main", source);
    var modules: []slang_types.Module = [module];
    var names = slang_names.resolve(source);
    var checker = new Checker {
        module: module,
        modules: modules,
        names: names,
        errors: [],
        symbol_types: [],
        expression_types: [],
        candidates: [],
        return_type: unit_type(),
        current_decl: [],
        current_generics: [],
        loop_depth: 0,
    };

    if (len(module.index.errors) > 0 || len(module.declarations.errors) > 0) {
        return CheckResult { names: names, errors: [], symbol_types: [], expression_types: [] };
    }

    seed_top_level(checker);
    for (decl in module.declarations.declarations) { check_decl(checker, decl); }
    return CheckResult {
        names: names,
        errors: checker.errors,
        symbol_types: checker.symbol_types,
        expression_types: checker.expression_types,
    };
}
