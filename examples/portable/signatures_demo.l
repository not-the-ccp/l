import bytes;
import slang_decls;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn named(type: ref slang_decls.Type, name: []u8) -> bool {
    return type.kind is slang_decls.TypeKind.named && bytes.equal(type.name, name);
}

fn main() -> i64 {
    var source = "pub const LIMIT: u64 = 10;\npub struct Pair[A, B] { pub left: A, right: ?ref pkg.Node[B], }\npub enum Result[T] { ok(T), err([]u8), }\npub fn map[T, U](value: T, f: fn(T) -> U) -> U { return f(value); }\n";
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
    require(len(pair.fields) == 2);
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

    var result = module.declarations[2];
    require(result.kind is slang_decls.DeclKind.enumeration);
    require(len(result.generics) == 1);
    require(len(result.variants) == 2);
    require(bytes.equal(result.variants[0].name, "ok"));
    require(named(result.variants[0].payload[0], "T"));
    require(result.variants[1].payload[0].kind is slang_decls.TypeKind.array);
    require(named(result.variants[1].payload[0].children[0], "u8"));

    var function = module.declarations[3];
    require(function.kind is slang_decls.DeclKind.function);
    require(len(function.generics) == 2);
    require(len(function.parameters) == 2);
    require(named(function.parameters[0].type, "T"));
    var callback = function.parameters[1].type;
    require(callback.kind is slang_decls.TypeKind.function);
    require(callback.parameter_count == 1);
    require(len(callback.children) == 2);
    require(named(callback.children[0], "T"));
    require(named(callback.children[1], "U"));
    match (function.return_type) {
        none { trap; }
        some(type) { require(named(type, "U")); }
    }

    var malformed = slang_decls.parse("fn broken( {\n");
    require(len(malformed.errors) > 0);
    require(len(malformed.declarations) == 0);

    return 0;
}
