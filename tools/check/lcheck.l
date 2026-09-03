import bytes;
import fs;
import slang_check;
import slang_names;
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

fn write_prefix(path: []u8, source: []u8, offset: u64) {
    var loc = location(source, offset);
    stdio.write(path);
    stdio.write(":");
    stdio.write(strconv.format_u64(loc.line));
    stdio.write(":");
    stdio.write(strconv.format_u64(loc.column));
    stdio.write(": error: ");
}

fn write_source_line(source: []u8, offset: u64) {
    var start = bytes.line_start(source, offset);
    var end = bytes.line_end(source, offset);
    if (end > start) {
        stdio.write("  ");
        stdio.write(bytes.slice(source, start, end));
        stdio.write("\n");
    }
}

fn write_name_error(kind: slang_names.ErrorKind) {
    if (kind is slang_names.ErrorKind.duplicate_binding) { stdio.write("duplicate binding"); return; }
    if (kind is slang_names.ErrorKind.shadows_module_name) { stdio.write("name shadows a module-level name"); return; }
    if (kind is slang_names.ErrorKind.shadows_generic_parameter) { stdio.write("name shadows a generic parameter"); return; }
    if (kind is slang_names.ErrorKind.shadows_outer_runtime_name) { stdio.write("name shadows an outer anonymous-function runtime name"); return; }
    if (kind is slang_names.ErrorKind.captures_outer_runtime_name) { stdio.write("anonymous function captures an outer runtime name"); return; }
    stdio.write("unresolved value name");
}

fn write_check_error(kind: slang_check.ErrorKind) {
    if (kind is slang_check.ErrorKind.invalid_type) { stdio.write("invalid type"); return; }
    if (kind is slang_check.ErrorKind.type_mismatch) { stdio.write("type mismatch"); return; }
    if (kind is slang_check.ErrorKind.unsupported_feature) { stdio.write("semantic feature not implemented by the L-written checker yet"); return; }
    if (kind is slang_check.ErrorKind.ambiguous_value) { stdio.write("ambiguous value requires an expected type"); return; }
    if (kind is slang_check.ErrorKind.not_a_value) { stdio.write("name is not a value"); return; }
    if (kind is slang_check.ErrorKind.array_required) { stdio.write("array value required"); return; }
    if (kind is slang_check.ErrorKind.reference_required) { stdio.write("reference value required"); return; }
    if (kind is slang_check.ErrorKind.boolean_required) { stdio.write("boolean value required"); return; }
    if (kind is slang_check.ErrorKind.integer_required) { stdio.write("integer value required"); return; }
    if (kind is slang_check.ErrorKind.numeric_required) { stdio.write("numeric value required"); return; }
    if (kind is slang_check.ErrorKind.equality_unsupported) { stdio.write("equality is not defined for this type"); return; }
    if (kind is slang_check.ErrorKind.ordering_unsupported) { stdio.write("ordering is not defined for this type"); return; }
    if (kind is slang_check.ErrorKind.bad_cast) { stdio.write("invalid numeric cast"); return; }
    if (kind is slang_check.ErrorKind.field_missing) { stdio.write("unknown field"); return; }
    if (kind is slang_check.ErrorKind.not_assignable) { stdio.write("expression is not assignable"); return; }
    if (kind is slang_check.ErrorKind.function_required) { stdio.write("called value is not a function"); return; }
    if (kind is slang_check.ErrorKind.arity) { stdio.write("wrong argument/payload arity"); return; }
    if (kind is slang_check.ErrorKind.bad_expression_statement) { stdio.write("only calls may be expression statements"); return; }
    if (kind is slang_check.ErrorKind.bad_pattern) { stdio.write("pattern does not match the subject type"); return; }
    if (kind is slang_check.ErrorKind.break_outside_loop) { stdio.write("break outside loop"); return; }
    if (kind is slang_check.ErrorKind.continue_outside_loop) { stdio.write("continue outside loop"); return; }
    if (kind is slang_check.ErrorKind.generic_inference) { stdio.write("cannot infer generic type arguments"); return; }
    if (kind is slang_check.ErrorKind.duplicate_pattern) { stdio.write("duplicate match arm"); return; }
    if (kind is slang_check.ErrorKind.non_exhaustive_match) { stdio.write("non-exhaustive match"); return; }
    if (kind is slang_check.ErrorKind.literal_range) { stdio.write("integer literal does not fit contextual type"); return; }
    stdio.write("function may fall off the end");
}

fn report_syntax(path: []u8, source: []u8, errors: []slang_syntax.Error) {
    for (error in errors) {
        write_prefix(path, source, error.start);
        stdio.write(error.message);
        stdio.write("\n");
        write_source_line(source, error.start);
    }
}

fn report_names(path: []u8, source: []u8, errors: []slang_names.Error) {
    for (error in errors) {
        write_prefix(path, source, error.start);
        write_name_error(error.kind);
        if (len(error.name) > 0) {
            stdio.write(": ");
            stdio.write(error.name);
        }
        stdio.write("\n");
        write_source_line(source, error.start);
    }
}

fn report_check(path: []u8, source: []u8, errors: []slang_check.Error) {
    for (error in errors) {
        write_prefix(path, source, error.start);
        write_check_error(error.kind);
        if (len(error.name) > 0) {
            stdio.write(": ");
            stdio.write(error.name);
        }
        stdio.write("\n");
        write_source_line(source, error.start);
    }
}

fn main() -> i64 {
    var args = sys.args();
    if (len(args) != 1) {
        stdio.write("usage: lcheck FILE\n");
        return 2;
    }
    var path = args[0];
    match (fs.read(path)) {
        none {
            stdio.write(path);
            stdio.write(": error: cannot read source file\n");
            return 2;
        }
        some(source) {
            var syntax = slang_syntax.errors(source);
            if (len(syntax) > 0) {
                report_syntax(path, source, syntax);
                return 1;
            }
            var checked = slang_check.check(source);
            if (len(checked.names.errors) > 0) {
                report_names(path, source, checked.names.errors);
            }
            if (len(checked.errors) > 0) {
                report_check(path, source, checked.errors);
            }
            if (len(checked.names.errors) > 0 || len(checked.errors) > 0) { return 1; }
            return 0;
        }
    }
}
