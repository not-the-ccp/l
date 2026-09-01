import bytes;
import fs;
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
    if (end > len(text)) {
        end = len(text);
    }
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
    stdio.write("usage: lsyntax [--outline] FILE\n");
}

fn write_kind(kind: slang_index.DeclKind) {
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
        if (decl.exported) {
            stdio.write("pub ");
        }
        write_kind(decl.kind);
        stdio.write(" ");
        stdio.write(decl.name);
        stdio.write("\n");
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
    var outline = false;
    var path: []u8 = [];
    if (len(args) == 1) {
        path = args[0];
    } else if (len(args) == 2 && bytes.equal(args[0], "--outline")) {
        outline = true;
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
            var module = slang_index.index(source);
            if (len(module.errors) > 0) {
                report_errors(path, source, module.errors);
                return 1;
            }
            if (outline) {
                write_outline(module);
            }
            return 0;
        }
    }
}
