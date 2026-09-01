from pathlib import Path

path = Path('lib/portable/slang_check.l')
text = path.read_text()
old = '''    } else if (expr.kind is slang_decls.ExprKind.binary) {
        var left = expr_type(checker, expr.children[0], expected);
        var right_expected: ?ref slang_types.ResolvedType = some(left);
        if (bytes.equal(expr.op, "<<") || bytes.equal(expr.op, ">>")) { right_expected = some(primitive_type("u64")); }
        var right = expr_type(checker, expr.children[1], right_expected);
        type = binop(checker, expr.op, left, right, expr.start, expr.end);
'''
new = '''    } else if (expr.kind is slang_decls.ExprKind.binary) {
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
'''
if text.count(old) != 1:
    raise SystemExit(f'binary-expression patch point count={text.count(old)}')
path.write_text(text.replace(old, new, 1))
