import bytes;
import slang_decls;
import slang_index;
import slang_project;

// Resolution of structured type syntax to stable semantic identities.
// Expression typing is deliberately not part of this layer.

pub enum ErrorKind {
    duplicate_generic,
    unknown_type,
    not_a_type,
    private_type,
    type_arity,
}

pub struct Error {
    pub kind: ErrorKind,
    pub module: []u8,
    pub declaration: []u8,
    pub name: []u8,
    pub start: u64,
    pub end: u64,
    pub expected: u64,
    pub actual: u64,
}

pub struct HostType {
    pub module: []u8,
    pub name: []u8,
}

pub struct Module {
    pub name: []u8,
    pub index: slang_index.ModuleIndex,
    pub declarations: slang_decls.Module,
}

pub enum ResolvedKind {
    invalid,
    unit,
    primitive,
    generic,
    nominal,
    host,
    optional,
    reference,
    array,
    const_array,
    function,
}

pub struct ResolvedType {
    pub kind: ResolvedKind,
    pub module: []u8,
    pub name: []u8,
    pub children: []ref ResolvedType,
    pub parameter_count: u64,
    pub start: u64,
    pub end: u64,
}

pub struct ResolveResult {
    pub type: ref ResolvedType,
    pub errors: []Error,
}

struct NameParts {
    qualified: bool,
    first: []u8,
    rest: []u8,
}

pub fn parse_module(name: []u8, source: []u8) -> Module {
    return Module {
        name: bytes.clone(name),
        index: slang_index.index(source),
        declarations: slang_decls.parse(source),
    };
}

fn empty_bytes() -> []u8 { return []; }

fn resolved(kind: ResolvedKind, module: []u8, name: []u8, children: []ref ResolvedType,
    parameter_count: u64, source: ref slang_decls.Type) -> ref ResolvedType {
    return new ResolvedType {
        kind: kind,
        module: bytes.clone(module),
        name: bytes.clone(name),
        children: children,
        parameter_count: parameter_count,
        start: source.start,
        end: source.end,
    };
}

fn push_error(out: []Error, kind: ErrorKind, module: Module, declaration: []u8,
    type: ref slang_decls.Type, expected: u64, actual: u64) {
    push(out, Error {
        kind: kind,
        module: bytes.clone(module.name),
        declaration: bytes.clone(declaration),
        name: bytes.clone(type.name),
        start: type.start,
        end: type.end,
        expected: expected,
        actual: actual,
    });
}

fn primitive(name: []u8) -> bool {
    return bytes.equal(name, "bool") ||
        bytes.equal(name, "i8") || bytes.equal(name, "i16") ||
        bytes.equal(name, "i32") || bytes.equal(name, "i64") ||
        bytes.equal(name, "u8") || bytes.equal(name, "u16") ||
        bytes.equal(name, "u32") || bytes.equal(name, "u64") ||
        bytes.equal(name, "f32") || bytes.equal(name, "f64");
}

fn generic_exists(generics: []slang_decls.GenericParam, name: []u8) -> bool {
    for (generic in generics) {
        if (bytes.equal(generic.name, name)) { return true; }
    }
    return false;
}

fn split_name(name: []u8) -> NameParts {
    match (bytes.find_byte(name, '.', 0)) {
        none {
            return NameParts { qualified: false, first: bytes.clone(name), rest: [] };
        }
        some(dot) {
            return NameParts {
                qualified: true,
                first: bytes.slice(name, 0, dot),
                rest: bytes.slice(name, dot + 1, len(name)),
            };
        }
    }
}

fn find_module(modules: []Module, name: []u8) -> ?u64 {
    for (var i: u64 = 0; i < len(modules); i += 1) {
        if (bytes.equal(modules[i].name, name)) { return some(i); }
    }
    return none;
}

fn find_decl(module: Module, name: []u8) -> ?slang_decls.Decl {
    for (decl in module.declarations.declarations) {
        if (bytes.equal(decl.name, name)) { return some(decl); }
    }
    return none;
}

fn find_import(module: Module, local: []u8) -> ?slang_index.Import {
    for (item in module.index.imports) {
        var bound = slang_project.import_local_name(item);
        if (bytes.equal(bound, local)) { return some(item); }
    }
    return none;
}

fn type_decl(kind: slang_decls.DeclKind) -> bool {
    return kind is slang_decls.DeclKind.structure || kind is slang_decls.DeclKind.enumeration;
}

fn host_type(host_types: []HostType, module: []u8, name: []u8) -> bool {
    for (type in host_types) {
        if (bytes.equal(type.module, module) && bytes.equal(type.name, name)) { return true; }
    }
    return false;
}

fn resolve_children(modules: []Module, module_index: u64, generics: []slang_decls.GenericParam,
    source: ref slang_decls.Type, host_types: []HostType, declaration: []u8, out: []Error) -> []ref ResolvedType {
    var children: []ref ResolvedType = [];
    for (child in source.children) {
        push(children, resolve_one(modules, module_index, generics, child, host_types, declaration, out));
    }
    return children;
}

fn arity(out: []Error, module: Module, declaration: []u8, source: ref slang_decls.Type,
    expected: u64) -> bool {
    var actual = len(source.children);
    if (actual != expected) {
        push_error(out, ErrorKind.type_arity, module, declaration, source, expected, actual);
        return false;
    }
    return true;
}

fn resolve_local(modules: []Module, module_index: u64, generics: []slang_decls.GenericParam,
    source: ref slang_decls.Type, children: []ref ResolvedType, declaration: []u8,
    out: []Error) -> ref ResolvedType {
    var module = modules[module_index];

    if (generic_exists(generics, source.name)) {
        arity(out, module, declaration, source, 0);
        return resolved(ResolvedKind.generic, empty_bytes(), source.name, children, 0, source);
    }
    if (primitive(source.name)) {
        arity(out, module, declaration, source, 0);
        return resolved(ResolvedKind.primitive, empty_bytes(), source.name, children, 0, source);
    }

    match (find_decl(module, source.name)) {
        none {
            push_error(out, ErrorKind.unknown_type, module, declaration, source, 0, len(source.children));
            return resolved(ResolvedKind.invalid, empty_bytes(), source.name, children, 0, source);
        }
        some(target) {
            if (!type_decl(target.kind)) {
                push_error(out, ErrorKind.not_a_type, module, declaration, source, 0, len(source.children));
                return resolved(ResolvedKind.invalid, module.name, source.name, children, 0, source);
            }
            arity(out, module, declaration, source, len(target.generics));
            return resolved(ResolvedKind.nominal, module.name, target.name, children, 0, source);
        }
    }
}

fn resolve_qualified(modules: []Module, module_index: u64, source: ref slang_decls.Type,
    parts: NameParts, children: []ref ResolvedType, host_types: []HostType,
    declaration: []u8, out: []Error) -> ref ResolvedType {
    var module = modules[module_index];
    match (find_import(module, parts.first)) {
        none {
            push_error(out, ErrorKind.unknown_type, module, declaration, source, 0, len(source.children));
            return resolved(ResolvedKind.invalid, empty_bytes(), source.name, children, 0, source);
        }
        some(item) {
            match (find_module(modules, item.path)) {
                some(target_index) {
                    var target_module = modules[target_index];
                    match (find_decl(target_module, parts.rest)) {
                        none {
                            push_error(out, ErrorKind.unknown_type, module, declaration, source, 0, len(source.children));
                            return resolved(ResolvedKind.invalid, target_module.name, parts.rest, children, 0, source);
                        }
                        some(target) {
                            if (!type_decl(target.kind)) {
                                push_error(out, ErrorKind.not_a_type, module, declaration, source, 0, len(source.children));
                                return resolved(ResolvedKind.invalid, target_module.name, target.name, children, 0, source);
                            }
                            if (!target.exported) {
                                push_error(out, ErrorKind.private_type, module, declaration, source, 0, len(source.children));
                                return resolved(ResolvedKind.invalid, target_module.name, target.name, children, 0, source);
                            }
                            arity(out, module, declaration, source, len(target.generics));
                            return resolved(ResolvedKind.nominal, target_module.name, target.name, children, 0, source);
                        }
                    }
                }
                none {
                    if (host_type(host_types, item.path, parts.rest)) {
                        arity(out, module, declaration, source, 0);
                        return resolved(ResolvedKind.host, item.path, parts.rest, children, 0, source);
                    }
                    push_error(out, ErrorKind.unknown_type, module, declaration, source, 0, len(source.children));
                    return resolved(ResolvedKind.invalid, item.path, parts.rest, children, 0, source);
                }
            }
        }
    }
}

fn resolve_one(modules: []Module, module_index: u64, generics: []slang_decls.GenericParam,
    source: ref slang_decls.Type, host_types: []HostType, declaration: []u8,
    out: []Error) -> ref ResolvedType {
    var children = resolve_children(modules, module_index, generics, source, host_types, declaration, out);

    if (source.kind is slang_decls.TypeKind.unit) {
        return resolved(ResolvedKind.unit, empty_bytes(), empty_bytes(), children, 0, source);
    }
    if (source.kind is slang_decls.TypeKind.optional) {
        return resolved(ResolvedKind.optional, empty_bytes(), empty_bytes(), children, 0, source);
    }
    if (source.kind is slang_decls.TypeKind.reference) {
        return resolved(ResolvedKind.reference, empty_bytes(), empty_bytes(), children, 0, source);
    }
    if (source.kind is slang_decls.TypeKind.array) {
        return resolved(ResolvedKind.array, empty_bytes(), empty_bytes(), children, 0, source);
    }
    if (source.kind is slang_decls.TypeKind.const_array) {
        return resolved(ResolvedKind.const_array, empty_bytes(), empty_bytes(), children, 0, source);
    }
    if (source.kind is slang_decls.TypeKind.function) {
        return resolved(ResolvedKind.function, empty_bytes(), empty_bytes(), children, source.parameter_count, source);
    }

    var parts = split_name(source.name);
    if (!parts.qualified) {
        return resolve_local(modules, module_index, generics, source, children, declaration, out);
    }
    return resolve_qualified(modules, module_index, source, parts, children, host_types, declaration, out);
}

pub fn resolve(modules: []Module, module_index: u64, generics: []slang_decls.GenericParam,
    source: ref slang_decls.Type, host_types: []HostType, declaration: []u8) -> ResolveResult {
    var errors: []Error = [];
    var type = resolve_one(modules, module_index, generics, source, host_types, declaration, errors);
    return ResolveResult { type: type, errors: errors };
}

fn duplicate_generics(module: Module, declaration: slang_decls.Decl, out: []Error) {
    for (var i: u64 = 0; i < len(declaration.generics); i += 1) {
        for (var j = i + 1; j < len(declaration.generics); j += 1) {
            if (bytes.equal(declaration.generics[i].name, declaration.generics[j].name)) {
                var fake = new slang_decls.Type {
                    kind: slang_decls.TypeKind.named,
                    name: bytes.clone(declaration.generics[j].name),
                    children: [],
                    parameter_count: 0,
                    start: declaration.generics[j].start,
                    end: declaration.generics[j].end,
                };
                push_error(out, ErrorKind.duplicate_generic, module, declaration.name, fake, 0, 0);
            }
        }
    }
}

fn validate_decl(modules: []Module, module_index: u64, declaration: slang_decls.Decl,
    host_types: []HostType, out: []Error) {
    var module = modules[module_index];
    duplicate_generics(module, declaration, out);

    match (declaration.value_type) {
        none { }
        some(type) { resolve_one(modules, module_index, declaration.generics, type, host_types, declaration.name, out); }
    }
    for (field in declaration.fields) {
        resolve_one(modules, module_index, declaration.generics, field.type, host_types, declaration.name, out);
    }
    for (variant in declaration.variants) {
        for (type in variant.payload) {
            resolve_one(modules, module_index, declaration.generics, type, host_types, declaration.name, out);
        }
    }
    for (parameter in declaration.parameters) {
        resolve_one(modules, module_index, declaration.generics, parameter.type, host_types, declaration.name, out);
    }
    match (declaration.return_type) {
        none { }
        some(type) { resolve_one(modules, module_index, declaration.generics, type, host_types, declaration.name, out); }
    }
}

pub fn validate(modules: []Module, host_types: []HostType) -> []Error {
    var out: []Error = [];
    for (var i: u64 = 0; i < len(modules); i += 1) {
        if (len(modules[i].index.errors) > 0 || len(modules[i].declarations.errors) > 0) {
            continue;
        }
        for (declaration in modules[i].declarations.declarations) {
            validate_decl(modules, i, declaration, host_types, out);
        }
    }
    return out;
}
