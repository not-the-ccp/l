import bytes;
import slang_decls;
import slang_types;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn main() -> i64 {
    var source: []u8 = "struct Demo[T] { a: const []T, b: []const []T, c: const [][]T, }";
    var module = slang_types.parse_module("demo", source);
    require(len(module.declarations.errors) == 0);
    require(len(module.declarations.declarations) == 1);
    var decl = module.declarations.declarations[0];
    require(len(decl.fields) == 3);

    var a = slang_types.resolve([module], 0, decl.generics, decl.fields[0].type, [], decl.name);
    require(len(a.errors) == 0);
    require(a.type.kind is slang_types.ResolvedKind.const_array);
    require(a.type.children[0].kind is slang_types.ResolvedKind.generic);
    require(bytes.equal(a.type.children[0].name, "T"));

    var b = slang_types.resolve([module], 0, decl.generics, decl.fields[1].type, [], decl.name);
    require(len(b.errors) == 0);
    require(b.type.kind is slang_types.ResolvedKind.array);
    require(b.type.children[0].kind is slang_types.ResolvedKind.const_array);
    require(b.type.children[0].children[0].kind is slang_types.ResolvedKind.generic);

    var c = slang_types.resolve([module], 0, decl.generics, decl.fields[2].type, [], decl.name);
    require(len(c.errors) == 0);
    require(c.type.kind is slang_types.ResolvedKind.const_array);
    require(c.type.children[0].kind is slang_types.ResolvedKind.array);
    require(c.type.children[0].children[0].kind is slang_types.ResolvedKind.generic);

    return 0;
}
