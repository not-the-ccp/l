import bytes;
import slang_decls;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn named(type: ref slang_decls.Type, name: const []u8) -> bool {
    return type.kind is slang_decls.TypeKind.named && bytes.equal(type.name, name);
}

fn main() -> i64 {
    var source: []u8 = "pub const LIMIT: u64 = 10;\npub struct Pair[A, B] { pub left: A, right: ?ref pkg.Node[B], view: const []A, nested: []const []B, }\npub enum Result[T] { ok(T), err(const []u8), }\npub fn map[T, U](value: T, f: fn(T) -> U, bytes: const []u8) -> U { return f(value); }\n";
    var module = slang_decls.parse(source);
    require(len(module.errors) == 0);
    require(len(module.declarations) == 4);

    var constant = module.declarations[0];
    require(constant.kind is slang_decls.DeclKind.constant);
    require(bytes.equal(constant.name, "LIMIT"));
    require(constant.exported);
    match (constant.value_type) {
        none { trap; }
        some(type) { require(named(type, "u64")); }
    }

    var pair = module.declarations[1];
    require(pair.kind is slang_decls.DeclKind.structure);
    require(len(pair.generics) == 2);
    require(bytes.equal(pair.generics[0].name, "A"));
    require(bytes.equal(pair.generics[1].name, "B"));
    if (len(pair.fields) != 4) { return 21; }
    require(pair.fields[0].exported);
    require(named(pair.fields[0].type, "A"));
    var optional = pair.fields[1].type;
    require(optional.kind is slang_decls.TypeKind.optional);
    require(len(optional.children) == 1);
    var reference = optional.children[0];
    require(reference.kind is slang_decls.TypeKind.reference);
    var node = reference.children[0];
    require(named(node, "pkg.Node"));
    require(len(node.children) == 1);
    require(named(node.children[0], "B"));

    var view = pair.fields[2].type;
    if (!(view.kind is slang_decls.TypeKind.const_array)) { return 22; }
    if (len(view.children) != 1) { return 23; }
    if (!named(view.children[0], "A")) { return 24; }

    var nested = pair.fields[3].type;
    if (!(nested.kind is slang_decls.TypeKind.array)) { return 25; }
    if (len(nested.children) != 1) { return 26; }
    if (!(nested.children[0].kind is slang_decls.TypeKind.const_array)) { return 27; }
    if (!named(nested.children[0].children[0], "B")) { return 28; }

    var result = module.declarations[2];
    require(result.kind is slang_decls.DeclKind.enumeration);
    require(len(result.generics) == 1);
    require(len(result.variants) == 2);
    require(bytes.equal(result.variants[0].name, "ok"));
    require(named(result.variants[0].payload[0], "T"));
    if (!(result.variants[1].payload[0].kind is slang_decls.TypeKind.const_array)) { return 29; }
    if (!named(result.variants[1].payload[0].children[0], "u8")) { return 30; }

    var function = module.declarations[3];
    require(function.kind is slang_decls.DeclKind.function);
    require(len(function.generics) == 2);
    if (len(function.parameters) != 3) { return 31; }
    require(named(function.parameters[0].type, "T"));
    var callback = function.parameters[1].type;
    require(callback.kind is slang_decls.TypeKind.function);
    require(callback.parameter_count == 1);
    require(len(callback.children) == 2);
    require(named(callback.children[0], "T"));
    require(named(callback.children[1], "U"));
    if (!(function.parameters[2].type.kind is slang_decls.TypeKind.const_array)) { return 32; }
    if (!named(function.parameters[2].type.children[0], "u8")) { return 33; }
    match (function.return_type) {
        none { trap; }
        some(type) { require(named(type, "U")); }
    }

    var malformed = slang_decls.parse("fn broken( {\n");
    require(len(malformed.errors) > 0);
    require(len(malformed.declarations) == 0);

    return 0;
}
