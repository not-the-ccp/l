import bytes;
import slang_decls;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn main() -> i64 {
    var source: []u8 = "const SCALE: i64 = 1 + 2 * 3;\nfn choose[T](xs: []T, pred: fn(T) -> bool) -> ?T { var i: u64 = 0; while (i < len(xs)) { if (pred(xs[i])) { return some(xs[i]); } else { i += 1; } } return none; }\nfn walk(xs: []i64) -> i64 { var total: i64 = 0; for (value in xs) { total += value; } for (var i: i64 = 0; i < 3; i += 1) { total += i; } match (total) { 0 { return 0; } other { return other; } } }\nfn forms(x: i64) -> i64 { var f: fn(i64) -> i64 = fn(v: i64) -> i64 { return v + 1; }; var p = Point { x: x, y: f(x), }; var ys = [x, p.x, f(x)]; var zs = [x; 3]; if (x is 0) { return ys[0] as i64; } return *new x; }\n";
    var module = slang_decls.parse(source);
    require(len(module.errors) == 0);
    require(len(module.declarations) == 4);

    var scale = module.declarations[0];
    require(scale.kind is slang_decls.DeclKind.constant);
    match (scale.value) {
        none { trap; }
        some(value) {
            require(value.kind is slang_decls.ExprKind.binary);
            require(bytes.equal(value.op, "+"));
            require(value.children[1].kind is slang_decls.ExprKind.binary);
            require(bytes.equal(value.children[1].op, "*"));
        }
    }

    var choose = module.declarations[1];
    require(choose.kind is slang_decls.DeclKind.function);
    require(len(choose.body) == 3);
    require(choose.body[0].kind is slang_decls.StmtKind.variable);
    require(choose.body[1].kind is slang_decls.StmtKind.while_loop);
    var loop = choose.body[1];
    require(len(loop.expressions) == 1);
    require(loop.expressions[0].kind is slang_decls.ExprKind.binary);
    require(len(loop.body) == 1);
    require(loop.body[0].kind is slang_decls.StmtKind.conditional);
    var conditional = loop.body[0];
    require(conditional.expressions[0].kind is slang_decls.ExprKind.call);
    require(len(conditional.body) == 1);
    require(conditional.body[0].kind is slang_decls.StmtKind.return_stmt);
    require(conditional.body[0].expressions[0].kind is slang_decls.ExprKind.some_value);
    require(len(conditional.alternate) == 1);
    require(conditional.alternate[0].kind is slang_decls.StmtKind.assignment);
    require(bytes.equal(conditional.alternate[0].op, "+="));
    require(choose.body[2].kind is slang_decls.StmtKind.return_stmt);
    require(choose.body[2].expressions[0].kind is slang_decls.ExprKind.none_value);

    var walk = module.declarations[2];
    require(len(walk.body) == 4);
    require(walk.body[1].kind is slang_decls.StmtKind.for_in);
    require(bytes.equal(walk.body[1].name, "value"));
    require(walk.body[2].kind is slang_decls.StmtKind.for_loop);
    match (walk.body[2].init) {
        none { trap; }
        some(init) { require(init.kind is slang_decls.StmtKind.variable); }
    }
    match (walk.body[2].step) {
        none { trap; }
        some(step) { require(step.kind is slang_decls.StmtKind.assignment); }
    }
    require(walk.body[3].kind is slang_decls.StmtKind.match_stmt);
    require(len(walk.body[3].arms) == 2);
    require(walk.body[3].arms[0].pattern.kind is slang_decls.PatternKind.integer);
    require(walk.body[3].arms[1].pattern.kind is slang_decls.PatternKind.binding);

    var forms = module.declarations[3];
    require(len(forms.body) == 6);
    require(forms.body[0].expressions[0].kind is slang_decls.ExprKind.anonymous_function);
    require(len(forms.body[0].expressions[0].body) == 1);
    require(forms.body[1].expressions[0].kind is slang_decls.ExprKind.struct_literal);
    require(len(forms.body[1].expressions[0].fields) == 2);
    require(forms.body[2].expressions[0].kind is slang_decls.ExprKind.array);
    require(forms.body[3].expressions[0].kind is slang_decls.ExprKind.repeat);
    require(forms.body[4].kind is slang_decls.StmtKind.conditional);
    require(forms.body[4].expressions[0].kind is slang_decls.ExprKind.pattern_test);
    match (forms.body[4].expressions[0].pattern) {
        none { trap; }
        some(pattern) { require(pattern.kind is slang_decls.PatternKind.integer); }
    }
    require(forms.body[4].body[0].expressions[0].kind is slang_decls.ExprKind.cast);
    require(forms.body[5].expressions[0].kind is slang_decls.ExprKind.dereference);
    require(forms.body[5].expressions[0].children[0].kind is slang_decls.ExprKind.allocate);

    return 0;
}