import bytes;
import fs;
import slang_decls;
import slang_index;
import slang_syntax;
import stdio;
import strconv;
import sys;

struct Location {
    line: u64,
    column: u64,
}

fn location(text: []u8, offset: u64) -> Location {
    var line: u64 = 1;
    var column: u64 = 1;
    var i: u64 = 0;
    var end = offset;
    if (end > len(text)) { end = len(text); }
    while (i < end) {
        if (text[i] == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
        i += 1;
    }
    return Location { line: line, column: column };
}

fn write_location(path: []u8, loc: Location) {
    stdio.write(path);
    stdio.write(":");
    stdio.write(strconv.format_u64(loc.line));
    stdio.write(":");
    stdio.write(strconv.format_u64(loc.column));
}

fn write_usage() {
    stdio.write("usage: lsyntax [--outline|--ast] FILE\n");
}

fn write_index_kind(kind: slang_index.DeclKind) {
    if (kind is slang_index.DeclKind.constant) { stdio.write("const"); return; }
    if (kind is slang_index.DeclKind.structure) { stdio.write("struct"); return; }
    if (kind is slang_index.DeclKind.enumeration) { stdio.write("enum"); return; }
    stdio.write("fn");
}

fn write_outline(module: slang_index.ModuleIndex) {
    for (item in module.imports) {
        stdio.write("import ");
        stdio.write(item.path);
        match (item.alias) {
            none { }
            some(alias) {
                stdio.write(" as ");
                stdio.write(alias);
            }
        }
        stdio.write("\n");
    }

    for (decl in module.declarations) {
        if (decl.exported) { stdio.write("pub "); }
        write_index_kind(decl.kind);
        stdio.write(" ");
        stdio.write(decl.name);
        stdio.write("\n");
    }
}

fn indent(depth: u64) {
    for (var i: u64 = 0; i < depth * 2; i += 1) { stdio.write(" "); }
}

fn write_expr_kind(kind: slang_decls.ExprKind) {
    if (kind is slang_decls.ExprKind.unit) { stdio.write("unit"); return; }
    if (kind is slang_decls.ExprKind.boolean) { stdio.write("bool"); return; }
    if (kind is slang_decls.ExprKind.integer) { stdio.write("int"); return; }
    if (kind is slang_decls.ExprKind.float) { stdio.write("float"); return; }
    if (kind is slang_decls.ExprKind.string) { stdio.write("string"); return; }
    if (kind is slang_decls.ExprKind.byte) { stdio.write("byte"); return; }
    if (kind is slang_decls.ExprKind.none_value) { stdio.write("none"); return; }
    if (kind is slang_decls.ExprKind.name) { stdio.write("name"); return; }
    if (kind is slang_decls.ExprKind.some_value) { stdio.write("some"); return; }
    if (kind is slang_decls.ExprKind.array) { stdio.write("array"); return; }
    if (kind is slang_decls.ExprKind.repeat) { stdio.write("repeat"); return; }
    if (kind is slang_decls.ExprKind.unary) { stdio.write("unary"); return; }
    if (kind is slang_decls.ExprKind.binary) { stdio.write("binary"); return; }
    if (kind is slang_decls.ExprKind.cast) { stdio.write("cast"); return; }
    if (kind is slang_decls.ExprKind.call) { stdio.write("call"); return; }
    if (kind is slang_decls.ExprKind.index) { stdio.write("index"); return; }
    if (kind is slang_decls.ExprKind.field) { stdio.write("field"); return; }
    if (kind is slang_decls.ExprKind.dereference) { stdio.write("deref"); return; }
    if (kind is slang_decls.ExprKind.allocate) { stdio.write("new"); return; }
    if (kind is slang_decls.ExprKind.struct_literal) { stdio.write("struct-literal"); return; }
    if (kind is slang_decls.ExprKind.anonymous_function) { stdio.write("anonymous-fn"); return; }
    stdio.write("pattern-test");
}

fn write_stmt_kind(kind: slang_decls.StmtKind) {
    if (kind is slang_decls.StmtKind.variable) { stdio.write("var"); return; }
    if (kind is slang_decls.StmtKind.assignment) { stdio.write("assign"); return; }
    if (kind is slang_decls.StmtKind.expression) { stdio.write("expr"); return; }
    if (kind is slang_decls.StmtKind.conditional) { stdio.write("if"); return; }
    if (kind is slang_decls.StmtKind.while_loop) { stdio.write("while"); return; }
    if (kind is slang_decls.StmtKind.for_loop) { stdio.write("for"); return; }
    if (kind is slang_decls.StmtKind.for_in) { stdio.write("for-in"); return; }
    if (kind is slang_decls.StmtKind.match_stmt) { stdio.write("match"); return; }
    if (kind is slang_decls.StmtKind.return_stmt) { stdio.write("return"); return; }
    if (kind is slang_decls.StmtKind.break_stmt) { stdio.write("break"); return; }
    if (kind is slang_decls.StmtKind.continue_stmt) { stdio.write("continue"); return; }
    stdio.write("trap");
}

fn write_pattern(pattern: ref slang_decls.Pattern, depth: u64) {
    indent(depth);
    stdio.write("pattern ");
    if (pattern.kind is slang_decls.PatternKind.wildcard) { stdio.write("_"); }
    else if (pattern.kind is slang_decls.PatternKind.binding) { stdio.write("name "); stdio.write(pattern.name); }
    else if (pattern.kind is slang_decls.PatternKind.unit) { stdio.write("unit"); }
    else if (pattern.kind is slang_decls.PatternKind.none_value) { stdio.write("none"); }
    else if (pattern.kind is slang_decls.PatternKind.some_value) { stdio.write("some"); }
    else if (pattern.kind is slang_decls.PatternKind.boolean) { stdio.write("bool "); stdio.write(pattern.name); }
    else if (pattern.kind is slang_decls.PatternKind.integer) { stdio.write("int "); stdio.write(pattern.name); }
    else if (pattern.kind is slang_decls.PatternKind.byte) { stdio.write("byte "); stdio.write(pattern.name); }
    else { stdio.write("constructor "); stdio.write(pattern.name); }
    stdio.write("\n");
    for (child in pattern.children) { write_pattern(child, depth + 1); }
}

fn write_expr(expr: ref slang_decls.Expr, depth: u64) {
    indent(depth);
    write_expr_kind(expr.kind);
    if (len(expr.op) > 0) { stdio.write(" "); stdio.write(expr.op); }
    if (len(expr.text) > 0) { stdio.write(" "); stdio.write(expr.text); }
    stdio.write("\n");
    match (expr.pattern) {
        none { }
        some(pattern) { write_pattern(pattern, depth + 1); }
    }
    for (field in expr.fields) {
        indent(depth + 1);
        stdio.write("field-init ");
        stdio.write(field.name);
        stdio.write("\n");
        write_expr(field.value, depth + 2);
    }
    for (child in expr.children) { write_expr(child, depth + 1); }
    for (stmt in expr.body) { write_stmt(stmt, depth + 1); }
}

fn write_stmt(stmt: ref slang_decls.Stmt, depth: u64) {
    indent(depth);
    write_stmt_kind(stmt.kind);
    if (len(stmt.name) > 0) { stdio.write(" "); stdio.write(stmt.name); }
    if (len(stmt.op) > 0) { stdio.write(" "); stdio.write(stmt.op); }
    stdio.write("\n");
    match (stmt.init) {
        none { }
        some(value) { indent(depth + 1); stdio.write("init\n"); write_stmt(value, depth + 2); }
    }
    for (expr in stmt.expressions) { write_expr(expr, depth + 1); }
    match (stmt.step) {
        none { }
        some(value) { indent(depth + 1); stdio.write("step\n"); write_stmt(value, depth + 2); }
    }
    for (child in stmt.body) { write_stmt(child, depth + 1); }
    if (len(stmt.alternate) > 0) {
        indent(depth + 1);
        stdio.write("else\n");
        for (child in stmt.alternate) { write_stmt(child, depth + 2); }
    }
    for (arm in stmt.arms) {
        indent(depth + 1);
        stdio.write("arm\n");
        write_pattern(arm.pattern, depth + 2);
        for (child in arm.body) { write_stmt(child, depth + 2); }
    }
}

fn write_decl_kind(kind: slang_decls.DeclKind) {
    if (kind is slang_decls.DeclKind.constant) { stdio.write("const"); return; }
    if (kind is slang_decls.DeclKind.structure) { stdio.write("struct"); return; }
    if (kind is slang_decls.DeclKind.enumeration) { stdio.write("enum"); return; }
    stdio.write("fn");
}

fn write_ast(module: slang_decls.Module) {
    for (decl in module.declarations) {
        write_decl_kind(decl.kind);
        stdio.write(" ");
        stdio.write(decl.name);
        stdio.write("\n");
        match (decl.value) {
            none { }
            some(value) { write_expr(value, 1); }
        }
        for (stmt in decl.body) { write_stmt(stmt, 1); }
    }
}

fn report_errors(path: []u8, source: []u8, errors: []slang_syntax.Error) {
    for (error in errors) {
        var loc = location(source, error.start);
        write_location(path, loc);
        stdio.write(": error: ");
        stdio.write(error.message);
        stdio.write("\n");

        var start = bytes.line_start(source, error.start);
        var end = bytes.line_end(source, error.start);
        if (end > start) {
            stdio.write("  ");
            stdio.write(bytes.slice(source, start, end));
            stdio.write("\n");
        }
    }
}

fn main() -> i64 {
    var args = sys.args();
    var mode: u64 = 0;
    var path: []u8 = [];
    if (len(args) == 1) {
        path = args[0];
    } else if (len(args) == 2 && bytes.equal(args[0], "--outline")) {
        mode = 1;
        path = args[1];
    } else if (len(args) == 2 && bytes.equal(args[0], "--ast")) {
        mode = 2;
        path = args[1];
    } else {
        write_usage();
        return 2;
    }

    var source_opt = fs.read(path);
    match (source_opt) {
        none {
            stdio.write(path);
            stdio.write(": error: cannot read source file\n");
            return 2;
        }
        some(source) {
            var index = slang_index.index(source);
            if (len(index.errors) > 0) {
                report_errors(path, source, index.errors);
                return 1;
            }
            if (mode == 1) { write_outline(index); }
            if (mode == 2) {
                var module = slang_decls.parse(source);
                if (len(module.errors) > 0) {
                    report_errors(path, source, module.errors);
                    return 1;
                }
                write_ast(module);
            }
            return 0;
        }
    }
}
