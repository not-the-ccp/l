import bytes;
import slang_decls;
import slang_index;

// Lexical/value-name resolution for the self-hosting frontend.
//
// This pass deliberately resolves only the lexical root of a dotted value
// expression. `x.field`, `module.member`, and `Enum.Variant` share the same
// syntactic qname shape; later type/member resolution interprets the tail once
// the root identity and subject type are known.
//
// Bare one-segment outer patterns remain contextually ambiguous between a
// binding and a zero-payload enum variant. Those names are tracked as pattern
// candidates rather than prematurely committed to either interpretation.

pub enum SymbolKind {
    builtin,
    import_binding,
    top_level,
    parameter,
    local,
    loop_binding,
    pattern_binding,
    anonymous_parameter,
}

pub struct Symbol {
    pub kind: SymbolKind,
    pub name: []u8,
    pub start: u64,
    pub end: u64,
}

pub enum UseKind {
    value,
    pattern_name,
}

pub enum UseStatus {
    resolved,
    unresolved,
    capture,
    pattern_candidate,
}

pub struct Use {
    pub kind: UseKind,
    pub status: UseStatus,
    pub text: []u8,
    pub root: []u8,
    pub symbol: ?u64,
    pub start: u64,
    pub end: u64,
}

pub enum ErrorKind {
    duplicate_binding,
    shadows_module_name,
    shadows_generic_parameter,
    shadows_outer_runtime_name,
    unresolved_value,
    captures_outer_runtime_name,
}

pub struct Error {
    pub kind: ErrorKind,
    pub name: []u8,
    pub start: u64,
    pub end: u64,
}

pub struct Resolution {
    pub symbols: []Symbol,
    pub uses: []Use,
    pub errors: []Error,
}

struct Scope {
    names: [][]u8,
    symbols: []u64,
    candidates: [][]u8,
}

struct Resolver {
    symbols: []Symbol,
    uses: []Use,
    errors: []Error,
    module_names: [][]u8,
    module_symbols: []u64,
    generic_names: [][]u8,
    forbidden_runtime: [][]u8,
    scopes: []Scope,
}

fn contains(names: const [][]u8, name: const []u8) -> bool {
    for (item in names) {
        if (bytes.equal(item, name)) { return true; }
    }
    return false;
}

fn root_name(text: const []u8) -> []u8 {
    match (bytes.find_byte(text, '.', 0)) {
        none { return bytes.clone(text); }
        some(index) { return bytes.slice(text, 0, index); }
    }
}

fn push_error(resolver: ref Resolver, kind: ErrorKind, name: const []u8, start: u64, end: u64) {
    push(resolver.errors, Error {
        kind: kind,
        name: bytes.clone(name),
        start: start,
        end: end,
    });
}

fn add_symbol(resolver: ref Resolver, kind: SymbolKind, name: const []u8, start: u64, end: u64) -> u64 {
    var index = len(resolver.symbols);
    push(resolver.symbols, Symbol {
        kind: kind,
        name: bytes.clone(name),
        start: start,
        end: end,
    });
    return index;
}

fn push_scope(resolver: ref Resolver) {
    push(resolver.scopes, Scope { names: [], symbols: [], candidates: [] });
}

fn pop_scope(resolver: ref Resolver) {
    pop(resolver.scopes);
}

fn module_symbol(resolver: ref Resolver, name: const []u8) -> ?u64 {
    for (var i: u64 = 0; i < len(resolver.module_names); i += 1) {
        if (bytes.equal(resolver.module_names[i], name)) {
            return some(resolver.module_symbols[i]);
        }
    }
    return none;
}

fn local_symbol(resolver: ref Resolver, name: const []u8) -> ?u64 {
    var i = len(resolver.scopes);
    while (i > 0) {
        i -= 1;
        var scope = resolver.scopes[i];
        for (var j: u64 = 0; j < len(scope.names); j += 1) {
            if (bytes.equal(scope.names[j], name)) {
                return some(scope.symbols[j]);
            }
        }
    }
    return none;
}

fn candidate_visible(resolver: ref Resolver, name: const []u8) -> bool {
    var i = len(resolver.scopes);
    while (i > 0) {
        i -= 1;
        if (contains(resolver.scopes[i].candidates, name)) { return true; }
    }
    return false;
}

fn local_name_visible(resolver: ref Resolver, name: const []u8) -> bool {
    return local_symbol(resolver, name) is some(_);
}

fn bind(resolver: ref Resolver, kind: SymbolKind, name: const []u8, start: u64, end: u64) -> ?u64 {
    if (local_name_visible(resolver, name)) {
        push_error(resolver, ErrorKind.duplicate_binding, name, start, end);
        return none;
    }
    if (module_symbol(resolver, name) is some(_)) {
        push_error(resolver, ErrorKind.shadows_module_name, name, start, end);
        return none;
    }
    if (contains(resolver.generic_names, name)) {
        push_error(resolver, ErrorKind.shadows_generic_parameter, name, start, end);
        return none;
    }
    if (contains(resolver.forbidden_runtime, name)) {
        push_error(resolver, ErrorKind.shadows_outer_runtime_name, name, start, end);
        return none;
    }

    var symbol = add_symbol(resolver, kind, name, start, end);
    var scope_index = len(resolver.scopes) - 1;
    push(resolver.scopes[scope_index].names, bytes.clone(name));
    push(resolver.scopes[scope_index].symbols, symbol);
    return some(symbol);
}

fn add_candidate(resolver: ref Resolver, name: const []u8) {
    var scope_index = len(resolver.scopes) - 1;
    if (!contains(resolver.scopes[scope_index].candidates, name)) {
        push(resolver.scopes[scope_index].candidates, bytes.clone(name));
    }
}

fn add_use(resolver: ref Resolver, kind: UseKind, status: UseStatus, text: const []u8,
    root: const []u8, symbol: ?u64, start: u64, end: u64) {
    push(resolver.uses, Use {
        kind: kind,
        status: status,
        text: bytes.clone(text),
        root: bytes.clone(root),
        symbol: symbol,
        start: start,
        end: end,
    });
}

fn resolve_value_name(resolver: ref Resolver, expr: ref slang_decls.Expr) {
    var root = root_name(expr.text);
    match (local_symbol(resolver, root)) {
        some(symbol) {
            add_use(resolver, UseKind.value, UseStatus.resolved, expr.text, root,
                some(symbol), expr.start, expr.end);
            return;
        }
        none { }
    }

    match (module_symbol(resolver, root)) {
        some(symbol) {
            add_use(resolver, UseKind.value, UseStatus.resolved, expr.text, root,
                some(symbol), expr.start, expr.end);
            return;
        }
        none { }
    }

    if (candidate_visible(resolver, root)) {
        add_use(resolver, UseKind.value, UseStatus.pattern_candidate, expr.text, root,
            none, expr.start, expr.end);
        return;
    }

    if (contains(resolver.forbidden_runtime, root)) {
        add_use(resolver, UseKind.value, UseStatus.capture, expr.text, root,
            none, expr.start, expr.end);
        push_error(resolver, ErrorKind.captures_outer_runtime_name, root, expr.start, expr.end);
        return;
    }

    add_use(resolver, UseKind.value, UseStatus.unresolved, expr.text, root,
        none, expr.start, expr.end);
    push_error(resolver, ErrorKind.unresolved_value, root, expr.start, expr.end);
}

fn record_pattern_name(resolver: ref Resolver, pattern: ref slang_decls.Pattern, status: UseStatus) {
    var root = root_name(pattern.name);
    add_use(resolver, UseKind.pattern_name, status, pattern.name, root,
        none, pattern.start, pattern.end);
}

fn bind_payload_pattern(resolver: ref Resolver, pattern: ref slang_decls.Pattern) {
    if (pattern.kind is slang_decls.PatternKind.binding) {
        bind(resolver, SymbolKind.pattern_binding, pattern.name, pattern.start, pattern.end);
    }
}

fn bind_pattern(resolver: ref Resolver, pattern: ref slang_decls.Pattern) {
    if (pattern.kind is slang_decls.PatternKind.some_value) {
        for (child in pattern.children) { bind_payload_pattern(resolver, child); }
        return;
    }

    if (pattern.kind is slang_decls.PatternKind.constructor) {
        record_pattern_name(resolver, pattern, UseStatus.resolved);
        for (child in pattern.children) { bind_payload_pattern(resolver, child); }
        return;
    }

    if (pattern.kind is slang_decls.PatternKind.binding) {
        // The parser intentionally preserves Python-oracle semantics here: a
        // one-segment outer name may be a binding or a fieldless enum variant.
        // Keep it deferred until the subject type is known.
        add_candidate(resolver, pattern.name);
        record_pattern_name(resolver, pattern, UseStatus.pattern_candidate);
    }
}

fn resolve_pattern_without_binding(resolver: ref Resolver, pattern: ref slang_decls.Pattern) {
    if (pattern.kind is slang_decls.PatternKind.constructor) {
        record_pattern_name(resolver, pattern, UseStatus.resolved);
    } else if (pattern.kind is slang_decls.PatternKind.binding) {
        record_pattern_name(resolver, pattern, UseStatus.pattern_candidate);
    }
}

fn visible_runtime_names(resolver: ref Resolver) -> [][]u8 {
    var out: [][]u8 = [];
    for (scope in resolver.scopes) {
        for (name in scope.names) {
            if (!contains(out, name)) { push(out, bytes.clone(name)); }
        }
        for (name in scope.candidates) {
            if (!contains(out, name)) { push(out, bytes.clone(name)); }
        }
    }
    return out;
}

fn resolve_block(resolver: ref Resolver, body: const []ref slang_decls.Stmt, new_scope: bool) {
    if (new_scope) { push_scope(resolver); }
    for (stmt in body) { resolve_stmt(resolver, stmt); }
    if (new_scope) { pop_scope(resolver); }
}

fn resolve_anonymous(resolver: ref Resolver, expr: ref slang_decls.Expr) {
    var old_scopes = resolver.scopes;
    var old_forbidden = resolver.forbidden_runtime;

    var forbidden = old_forbidden;
    for (name in visible_runtime_names(resolver)) {
        if (!contains(forbidden, name)) { push(forbidden, bytes.clone(name)); }
    }

    resolver.scopes = [];
    resolver.forbidden_runtime = forbidden;
    push_scope(resolver);
    for (parameter in expr.parameters) {
        bind(resolver, SymbolKind.anonymous_parameter, parameter.name, parameter.start, parameter.end);
    }
    resolve_block(resolver, expr.body, false);
    pop_scope(resolver);
    resolver.scopes = old_scopes;
    resolver.forbidden_runtime = old_forbidden;
}

fn resolve_expr(resolver: ref Resolver, expr: ref slang_decls.Expr) {
    if (expr.kind is slang_decls.ExprKind.name) {
        resolve_value_name(resolver, expr);
        return;
    }

    if (expr.kind is slang_decls.ExprKind.anonymous_function) {
        resolve_anonymous(resolver, expr);
        return;
    }

    if (expr.kind is slang_decls.ExprKind.pattern_test) {
        for (child in expr.children) { resolve_expr(resolver, child); }
        match (expr.pattern) {
            none { }
            some(pattern) { resolve_pattern_without_binding(resolver, pattern); }
        }
        return;
    }

    for (child in expr.children) { resolve_expr(resolver, child); }
    for (field in expr.fields) { resolve_expr(resolver, field.value); }
}

fn resolve_condition(resolver: ref Resolver, expr: ref slang_decls.Expr) {
    if (!(expr.kind is slang_decls.ExprKind.pattern_test)) {
        resolve_expr(resolver, expr);
        return;
    }

    for (child in expr.children) { resolve_expr(resolver, child); }
    match (expr.pattern) {
        none { }
        some(pattern) { bind_pattern(resolver, pattern); }
    }
}

fn resolve_stmt(resolver: ref Resolver, stmt: ref slang_decls.Stmt) {
    if (stmt.kind is slang_decls.StmtKind.variable) {
        for (expr in stmt.expressions) { resolve_expr(resolver, expr); }
        bind(resolver, SymbolKind.local, stmt.name, stmt.start, stmt.end);
        return;
    }

    if (stmt.kind is slang_decls.StmtKind.assignment || stmt.kind is slang_decls.StmtKind.expression ||
        stmt.kind is slang_decls.StmtKind.return_stmt) {
        for (expr in stmt.expressions) { resolve_expr(resolver, expr); }
        return;
    }

    if (stmt.kind is slang_decls.StmtKind.conditional) {
        push_scope(resolver);
        if (len(stmt.expressions) > 0) { resolve_condition(resolver, stmt.expressions[0]); }
        resolve_block(resolver, stmt.body, false);
        pop_scope(resolver);
        resolve_block(resolver, stmt.alternate, true);
        return;
    }

    if (stmt.kind is slang_decls.StmtKind.while_loop) {
        push_scope(resolver);
        if (len(stmt.expressions) > 0) { resolve_condition(resolver, stmt.expressions[0]); }
        resolve_block(resolver, stmt.body, false);
        pop_scope(resolver);
        return;
    }

    if (stmt.kind is slang_decls.StmtKind.for_in) {
        for (expr in stmt.expressions) { resolve_expr(resolver, expr); }
        push_scope(resolver);
        bind(resolver, SymbolKind.loop_binding, stmt.name, stmt.start, stmt.end);
        resolve_block(resolver, stmt.body, false);
        pop_scope(resolver);
        return;
    }

    if (stmt.kind is slang_decls.StmtKind.for_loop) {
        push_scope(resolver);
        match (stmt.init) { none { } some(init) { resolve_stmt(resolver, init); } }
        for (expr in stmt.expressions) { resolve_expr(resolver, expr); }
        match (stmt.step) { none { } some(step) { resolve_stmt(resolver, step); } }
        resolve_block(resolver, stmt.body, true);
        pop_scope(resolver);
        return;
    }

    if (stmt.kind is slang_decls.StmtKind.match_stmt) {
        for (expr in stmt.expressions) { resolve_expr(resolver, expr); }
        for (arm in stmt.arms) {
            push_scope(resolver);
            bind_pattern(resolver, arm.pattern);
            resolve_block(resolver, arm.body, false);
            pop_scope(resolver);
        }
        return;
    }

    // break/continue/trap contain no value names.
}

fn add_module_name(resolver: ref Resolver, kind: SymbolKind, name: const []u8, start: u64, end: u64) {
    var symbol = add_symbol(resolver, kind, name, start, end);
    push(resolver.module_names, bytes.clone(name));
    push(resolver.module_symbols, symbol);
}

fn seed_module(resolver: ref Resolver, index: slang_index.ModuleIndex, module: slang_decls.Module) {
    add_module_name(resolver, SymbolKind.builtin, "len", 0, 0);
    add_module_name(resolver, SymbolKind.builtin, "push", 0, 0);
    add_module_name(resolver, SymbolKind.builtin, "pop", 0, 0);
    add_module_name(resolver, SymbolKind.builtin, "splice", 0, 0);

    for (item in index.imports) {
        var local = bytes.clone(item.path);
        match (item.alias) {
            some(alias) { local = bytes.clone(alias); }
            none {
                var start: u64 = 0;
                for (var i: u64 = 0; i < len(item.path); i += 1) {
                    if (item.path[i] == '.') { start = i + 1; }
                }
                local = bytes.slice(item.path, start, len(item.path));
            }
        }
        add_module_name(resolver, SymbolKind.import_binding, local, item.start, item.end);
    }

    for (decl in module.declarations) {
        add_module_name(resolver, SymbolKind.top_level, decl.name, decl.start, decl.end);
    }
}

fn resolve_function(resolver: ref Resolver, decl: slang_decls.Decl) {
    resolver.generic_names = [];
    for (generic in decl.generics) { push(resolver.generic_names, bytes.clone(generic.name)); }
    resolver.forbidden_runtime = [];
    resolver.scopes = [];
    push_scope(resolver);
    for (parameter in decl.parameters) {
        bind(resolver, SymbolKind.parameter, parameter.name, parameter.start, parameter.end);
    }
    resolve_block(resolver, decl.body, false);
    pop_scope(resolver);
    resolver.scopes = [];
    resolver.generic_names = [];
    resolver.forbidden_runtime = [];
}

pub fn resolve(text: const []u8) -> Resolution {
    var index = slang_index.index(text);
    var module = slang_decls.parse(text);
    var resolver = new Resolver {
        symbols: [],
        uses: [],
        errors: [],
        module_names: [],
        module_symbols: [],
        generic_names: [],
        forbidden_runtime: [],
        scopes: [],
    };

    if (len(index.errors) > 0 || len(module.errors) > 0) {
        return Resolution { symbols: [], uses: [], errors: [] };
    }

    seed_module(resolver, index, module);

    for (decl in module.declarations) {
        if (decl.kind is slang_decls.DeclKind.constant) {
            match (decl.value) { none { } some(value) { resolve_expr(resolver, value); } }
        } else if (decl.kind is slang_decls.DeclKind.function) {
            resolve_function(resolver, decl);
        }
    }

    return Resolution {
        symbols: resolver.symbols,
        uses: resolver.uses,
        errors: resolver.errors,
    };
}
