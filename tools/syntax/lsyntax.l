import bytes;
import fs;
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
    stdio.write("usage: lsyntax FILE\n");
}

fn main() -> i64 {
    var args = sys.args();
    if (len(args) != 1) {
        write_usage();
        return 2;
    }

    var path = args[0];
    var source_opt = fs.read(path);
    match (source_opt) {
        none {
            stdio.write(path);
            stdio.write(": error: cannot read source file\n");
            return 2;
        }
        some(source) {
            var errors = slang_syntax.errors(source);
            if (len(errors) == 0) {
                return 0;
            }

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
            return 1;
        }
    }
}
