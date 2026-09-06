import bytes;
import slang_index;

// Project-level name/module resolution for the self-hosting frontend.
//
// This module deliberately operates on logical module names and already-loaded
// source text. Filesystem/package lookup remains an embedding/tool concern.

pub enum ErrorKind {
    duplicate_module,
    duplicate_name,
    reserved_name,
    unresolved_module,
    import_cycle,
}

pub struct Error {
    pub kind: ErrorKind,
    pub module: []u8,
    pub name: []u8,
    pub target: []u8,
    pub start: u64,
    pub end: u64,
}

pub struct Module {
    pub name: const []u8,
    pub index: slang_index.ModuleIndex,
}

pub enum MemberStatus {
    found,
    missing_module,
    missing_member,
    private_member,
}

pub struct MemberLookup {
    pub status: MemberStatus,
    pub declaration: ?slang_index.Decl,
}

fn empty_error_value() -> []u8 {
    return [];
}

fn push_error(out: []Error, kind: ErrorKind, module: const []u8, name: const []u8,
    target: const []u8, start: u64, end: u64) {
    push(out, Error {
        kind: kind,
        module: bytes.clone(module),
        name: bytes.clone(name),
        target: bytes.clone(target),
        start: start,
        end: end,
    });
}

fn reserved(name: const []u8) -> bool {
    return bytes.equal(name, "len") || bytes.equal(name, "push") ||
        bytes.equal(name, "pop") || bytes.equal(name, "splice");
}

fn contains_name(names: const [][]u8, name: const []u8) -> bool {
    for (existing in names) {
        if (bytes.equal(existing, name)) {
            return true;
        }
    }
    return false;
}

pub fn import_local_name(item: slang_index.Import) -> []u8 {
    match (item.alias) {
        some(alias) { return bytes.clone(alias); }
        none { }
    }

    var start: u64 = 0;
    for (var i: u64 = 0; i < len(item.path); i += 1) {
        if (item.path[i] == '.') {
            start = i + 1;
        }
    }
    return bytes.slice(item.path, start, len(item.path));
}

pub fn find_module(modules: const []Module, name: const []u8) -> ?u64 {
    for (var i: u64 = 0; i < len(modules); i += 1) {
        if (bytes.equal(modules[i].name, name)) {
            return some(i);
        }
    }
    return none;
}

fn host_exists(host_modules: const [][]u8, name: const []u8) -> bool {
    return contains_name(host_modules, name);
}

fn check_module_names(modules: const []Module, out: []Error) {
    for (var i: u64 = 0; i < len(modules); i += 1) {
        for (var j = i + 1; j < len(modules); j += 1) {
            if (bytes.equal(modules[i].name, modules[j].name)) {
                push_error(out, ErrorKind.duplicate_module, modules[j].name, modules[j].name, empty_error_value(), 0, 0);
            }
        }
    }
}

fn claim_name(out: []Error, module: Module, seen: [][]u8, name: const []u8, start: u64, end: u64) {
    if (reserved(name)) {
        push_error(out, ErrorKind.reserved_name, module.name, name, empty_error_value(), start, end);
        return;
    }
    if (contains_name(seen, name)) {
        push_error(out, ErrorKind.duplicate_name, module.name, name, empty_error_value(), start, end);
        return;
    }
    push(seen, bytes.clone(name));
}

fn check_module(module: Module, modules: const []Module, host_modules: const [][]u8, out: []Error) {
    // Syntax errors belong to slang_syntax/slang_index. Avoid cascading semantic
    // diagnostics from an incomplete module.
    if (len(module.index.errors) > 0) {
        return;
    }

    var seen: [][]u8 = [];
    for (item in module.index.imports) {
        var local = import_local_name(item);
        claim_name(out, module, seen, local, item.start, item.end);

        var target_found = false;
        match (find_module(modules, item.path)) {
            some(_) { target_found = true; }
            none { }
        }
        if (!target_found && !host_exists(host_modules, item.path)) {
            push_error(out, ErrorKind.unresolved_module, module.name, local, item.path, item.start, item.end);
        }
    }

    for (decl in module.index.declarations) {
        claim_name(out, module, seen, decl.name, decl.start, decl.end);
    }
}

fn visit(modules: const []Module, states: []u8, index: u64, out: []Error) {
    if (states[index] == 2) {
        return;
    }
    states[index] = 1;

    for (item in modules[index].index.imports) {
        match (find_module(modules, item.path)) {
            none { }
            some(next) {
                if (states[next] == 1) {
                    push_error(out, ErrorKind.import_cycle, modules[index].name,
                        import_local_name(item), item.path, item.start, item.end);
                } else if (states[next] == 0) {
                    visit(modules, states, next, out);
                }
            }
        }
    }

    states[index] = 2;
}

pub fn validate(modules: const []Module, host_modules: const [][]u8) -> []Error {
    var out: []Error = [];
    check_module_names(modules, out);
    for (module in modules) {
        check_module(module, modules, host_modules, out);
    }

    var states: []u8 = [0; len(modules)];
    for (var i: u64 = 0; i < len(modules); i += 1) {
        if (states[i] == 0) {
            visit(modules, states, i, out);
        }
    }
    return out;
}

fn find_decl(module: Module, name: const []u8) -> ?slang_index.Decl {
    for (decl in module.index.declarations) {
        if (bytes.equal(decl.name, name)) {
            return some(decl);
        }
    }
    return none;
}

pub fn member(modules: const []Module, module_name: const []u8, name: const []u8) -> MemberLookup {
    match (find_module(modules, module_name)) {
        none {
            return MemberLookup { status: MemberStatus.missing_module, declaration: none };
        }
        some(index) {
            match (find_decl(modules[index], name)) {
                none {
                    return MemberLookup { status: MemberStatus.missing_member, declaration: none };
                }
                some(decl) {
                    if (!decl.exported) {
                        return MemberLookup { status: MemberStatus.private_member, declaration: some(decl) };
                    }
                    return MemberLookup { status: MemberStatus.found, declaration: some(decl) };
                }
            }
        }
    }
}