import bytes;
import slang_decls;
import slang_types;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn count(errors: []slang_types.Error, kind: slang_types.ErrorKind) -> u64 {
    var total: u64 = 0;
    for (error in errors) {
        if (error.kind == kind) { total += 1; }
    }
    return total;
}

fn find_decl(module: slang_types.Module, name: []u8) -> slang_decls.Decl {
    for (decl in module.declarations.declarations) {
        if (bytes.equal(decl.name, name)) { return decl; }
    }
    trap;
}

fn main() -> i64 {
    var hosts: []slang_types.HostType = [
        slang_types.HostType { module: "ffi", name: "Handle" },
    ];

    var modules: []slang_types.Module = [
        slang_types.parse_module("base", "pub struct Box[T] { pub value: T, } struct Secret { value: i64, } pub fn helper() { }"),
        slang_types.parse_module("app", "import base as b; import ffi; pub struct Local[T] { pub local: T, pub boxed: b.Box[T], pub handle: ffi.Handle, pub bytes: []u8, pub callback: fn(T) -> ?ref b.Box[T], }"),
    ];

    var good_errors = slang_types.validate(modules, hosts);
    require(len(good_errors) == 0);

    var local = find_decl(modules[1], "Local");
    var boxed = slang_types.resolve(modules, 1, local.generics, local.fields[1].type, hosts, local.name);
    require(len(boxed.errors) == 0);
    require(boxed.type.kind is slang_types.ResolvedKind.nominal);
    require(bytes.equal(boxed.type.module, "base"));
    require(bytes.equal(boxed.type.name, "Box"));
    require(len(boxed.type.children) == 1);
    require(boxed.type.children[0].kind is slang_types.ResolvedKind.generic);
    require(bytes.equal(boxed.type.children[0].name, "T"));

    var handle = slang_types.resolve(modules, 1, local.generics, local.fields[2].type, hosts, local.name);
    require(len(handle.errors) == 0);
    require(handle.type.kind is slang_types.ResolvedKind.host);
    require(bytes.equal(handle.type.module, "ffi"));
    require(bytes.equal(handle.type.name, "Handle"));

    var callback = slang_types.resolve(modules, 1, local.generics, local.fields[4].type, hosts, local.name);
    require(len(callback.errors) == 0);
    require(callback.type.kind is slang_types.ResolvedKind.function);
    require(callback.type.parameter_count == 1);
    require(len(callback.type.children) == 2);
    require(callback.type.children[0].kind is slang_types.ResolvedKind.generic);
    require(callback.type.children[1].kind is slang_types.ResolvedKind.optional);
    require(callback.type.children[1].children[0].kind is slang_types.ResolvedKind.reference);
    require(callback.type.children[1].children[0].children[0].kind is slang_types.ResolvedKind.nominal);

    var arity_modules: []slang_types.Module = [
        modules[0],
        slang_types.parse_module("bad", "import base as b; struct Wrong { value: b.Box, }"),
    ];
    var arity_errors = slang_types.validate(arity_modules, hosts);
    require(count(arity_errors, slang_types.ErrorKind.type_arity) == 1);

    var primitive_arity: []slang_types.Module = [
        slang_types.parse_module("bad", "struct Wrong { value: i64[u8], }"),
    ];
    var primitive_errors = slang_types.validate(primitive_arity, hosts);
    require(count(primitive_errors, slang_types.ErrorKind.type_arity) == 1);

    var unknown: []slang_types.Module = [
        slang_types.parse_module("bad", "struct Wrong { value: Missing, }"),
    ];
    var unknown_errors = slang_types.validate(unknown, hosts);
    require(count(unknown_errors, slang_types.ErrorKind.unknown_type) == 1);

    var private_modules: []slang_types.Module = [
        modules[0],
        slang_types.parse_module("bad", "import base as b; struct Wrong { value: b.Secret, }"),
    ];
    var private_errors = slang_types.validate(private_modules, hosts);
    require(count(private_errors, slang_types.ErrorKind.private_type) == 1);

    var value_as_type: []slang_types.Module = [
        modules[0],
        slang_types.parse_module("bad", "import base as b; struct Wrong { value: b.helper, }"),
    ];
    var value_errors = slang_types.validate(value_as_type, hosts);
    require(count(value_errors, slang_types.ErrorKind.not_a_type) == 1);

    var duplicate_generic: []slang_types.Module = [
        slang_types.parse_module("bad", "struct Wrong[T, T] { value: T, }"),
    ];
    var duplicate_errors = slang_types.validate(duplicate_generic, hosts);
    require(count(duplicate_errors, slang_types.ErrorKind.duplicate_generic) == 1);

    var bad_host: []slang_types.Module = [
        slang_types.parse_module("bad", "import ffi; struct Wrong { value: ffi.Missing, }"),
    ];
    var bad_host_errors = slang_types.validate(bad_host, hosts);
    require(count(bad_host_errors, slang_types.ErrorKind.unknown_type) == 1);

    return 0;
}
