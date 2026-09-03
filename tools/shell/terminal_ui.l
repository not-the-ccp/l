import byte_display;
import bytes;
import editor;
import presentation;
import prompt;
import term;

pub enum Role {
    prompt_cwd,
    prompt_status,
    prompt_marker,
    command,
    argument,
    quoted_argument,
    pipe,
    suggestion,
    diagnostic,
    plain,
}

pub struct Atom {
    pub role: Role,
    // Atom text is always terminal-safe printable UTF-8. Newlines are row
    // structure, never atom data.
    pub text: []u8,
}

pub struct Row {
    pub atoms: []Atom,
}

pub struct View {
    pub rows: []ref Row,
    pub cursor_row: u64,
    pub cursor_col: u64,
}

struct Builder {
    rows: []ref Row,
    current: ref Row,
    col: u64,
    width: u64,
    cursor_row: u64,
    cursor_col: u64,
    cursor_set: bool,
}

fn new_builder(columns: u64) -> ref Builder {
    // Stay one cell short of the right edge. Exact-width output interacts with
    // terminal autowrap state differently across emulators and makes cursor
    // restoration unnecessarily fragile.
    var width: u64 = 1;
    if (columns > 1) { width = columns - 1; }
    var row = new Row { atoms: [] };
    return new Builder {
        rows: [row],
        current: row,
        col: 0,
        width: width,
        cursor_row: 0,
        cursor_col: 0,
        cursor_set: false,
    };
}

fn next_row(builder: ref Builder) {
    var row = new Row { atoms: [] };
    push(builder.rows, row);
    builder.current = row;
    builder.col = 0;
}

fn map_prompt_role(role: prompt.SegmentRole) -> Role {
    if (role == prompt.SegmentRole.cwd) { return Role.prompt_cwd; }
    if (role == prompt.SegmentRole.status) { return Role.prompt_status; }
    return Role.prompt_marker;
}

fn map_highlight_role(role: presentation.HighlightRole) -> Role {
    if (role == presentation.HighlightRole.command) { return Role.command; }
    if (role == presentation.HighlightRole.quoted_argument) { return Role.quoted_argument; }
    if (role == presentation.HighlightRole.pipe) { return Role.pipe; }
    return Role.argument;
}

fn source_role(analysis: presentation.Analysis, pos: u64) -> Role {
    for (highlight in analysis.highlights) {
        if (pos >= highlight.span.start && pos < highlight.span.end) {
            return map_highlight_role(highlight.role);
        }
    }
    return Role.plain;
}

fn push_atom(builder: ref Builder, role: Role, safe_text: []u8) {
    if (len(safe_text) == 0) { return; }
    var shown = safe_text;
    var w = term.text_width(shown);
    if (w > builder.width) {
        // This can only happen on pathologically narrow terminals because an
        // unsafe-byte representation is short. Never slice UTF-8 to fit.
        shown = "?";
        w = 1;
    }
    if (builder.col != 0 && builder.col + w > builder.width) {
        next_row(builder);
    }
    push(builder.current.atoms, Atom { role: role, text: shown });
    builder.col += w;
}

fn push_raw_unit(builder: ref Builder, src: const []u8, unit: byte_display.Unit, role: Role) {
    push_atom(builder, role, byte_display.representation(src, unit));
}

fn push_safe_bytes(builder: ref Builder, src: const []u8, role: Role) {
    var pos: u64 = 0;
    while (pos < len(src)) {
        var unit = byte_display.next_unit(src, pos);
        if (unit.kind == byte_display.UnitKind.line_break) {
            next_row(builder);
        } else {
            push_raw_unit(builder, src, unit, role);
        }
        pos = unit.end;
    }
}

fn push_prompt(builder: ref Builder, cwd: ?[]u8, home: ?[]u8, status: i64, continuation: bool) {
    var model = prompt.build(cwd, home, status, continuation);
    for (var i: u64 = 0; i < len(model.segments); i += 1) {
        if (i != 0) { push_atom(builder, Role.plain, " "); }
        var segment = model.segments[i];
        push_safe_bytes(builder, segment.text, map_prompt_role(segment.role));
    }
    push_atom(builder, Role.plain, " ");
}

fn capture_cursor(builder: ref Builder) {
    if (builder.cursor_set) { return; }
    builder.cursor_row = len(builder.rows) - 1;
    builder.cursor_col = builder.col;
    builder.cursor_set = true;
}

fn append_editor_buffer(builder: ref Builder, model: ref editor.Editor, cwd: ?[]u8, home: ?[]u8, status: i64) {
    push_prompt(builder, cwd, home, status, false);
    if (model.cursor == 0) { capture_cursor(builder); }

    var pos: u64 = 0;
    while (pos < len(model.buffer)) {
        var unit = byte_display.next_unit(model.buffer, pos);
        if (unit.kind == byte_display.UnitKind.line_break) {
            if (model.cursor == pos) { capture_cursor(builder); }
            next_row(builder);
            push_prompt(builder, cwd, home, status, true);
            pos = unit.end;
            if (model.cursor == pos) { capture_cursor(builder); }
            continue;
        }
        push_raw_unit(builder, model.buffer, unit, source_role(model.analysis, pos));
        pos = unit.end;
        if (model.cursor == pos) { capture_cursor(builder); }
    }
    if (model.cursor == len(model.buffer)) { capture_cursor(builder); }

    var suffix = editor.suggestion_suffix(model);
    if (len(suffix) != 0) {
        var suggestion_pos: u64 = 0;
        while (suggestion_pos < len(suffix)) {
            var unit = byte_display.next_unit(suffix, suggestion_pos);
            if (unit.kind == byte_display.UnitKind.line_break) {
                next_row(builder);
                push_prompt(builder, cwd, home, status, true);
            } else {
                push_raw_unit(builder, suffix, unit, Role.suggestion);
            }
            suggestion_pos = unit.end;
        }
    }
}

fn append_diagnostic(builder: ref Builder, model: ref editor.Editor) {
    match (model.analysis.diagnostic) {
        none { return; }
        some(problem) {
            // Incompleteness is already communicated by the continuation
            // prompt. An extra warning row would create visual noise while the
            // user is deliberately typing a multiline command.
            if (problem.kind == presentation.DiagnosticKind.incomplete) { return; }
            next_row(builder);
            push_atom(builder, Role.diagnostic, "! ");
            push_safe_bytes(builder, problem.message, Role.diagnostic);
        }
    }
}

pub fn build(model: ref editor.Editor, cwd: ?[]u8, home: ?[]u8, status: i64, columns: u64) -> View {
    var builder = new_builder(columns);
    append_editor_buffer(builder, model, cwd, home, status);
    append_diagnostic(builder, model);
    if (!builder.cursor_set) { capture_cursor(builder); }
    return View {
        rows: builder.rows,
        cursor_row: builder.cursor_row,
        cursor_col: builder.cursor_col,
    };
}

pub fn plain(view: View) -> []u8 {
    var out: []u8 = [];
    for (var row_index: u64 = 0; row_index < len(view.rows); row_index += 1) {
        if (row_index != 0) { push(out, '\n'); }
        var row = view.rows[row_index];
        for (atom in row.atoms) { bytes.append(out, atom.text); }
    }
    return out;
}

// Render command/builtin output into scrollback without letting arbitrary bytes
// become terminal protocol. Newlines retain their structural meaning; all
// other unsafe bytes are made visible by byte_display.
pub fn safe_scrollback(src: const []u8) -> []u8 {
    var out: []u8 = [];
    var pos: u64 = 0;
    while (pos < len(src)) {
        var unit = byte_display.next_unit(src, pos);
        if (unit.kind == byte_display.UnitKind.line_break) {
            push(out, '\r');
            push(out, '\n');
        } else {
            bytes.append(out, byte_display.representation(src, unit));
        }
        pos = unit.end;
    }
    return out;
}
