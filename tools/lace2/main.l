import arrays;
import bytes;
import fs;
import sys;
import term;
import tools.lace2.display_bytes as display;
import tools.lace2.editor_model as model;
import tools.lace2.linewise as linewise;
import tools.lace2.navigation as nav;
import tools.lace2.piece_tree as text;
import tools.lace2.render as render;

struct Ui {
    editor: ref model.Editor,
    path: []u8,
    top_start: u64,
    top_line_number: u64,
    hscroll: u64,
    message: []u8,
    last_search: []u8,
    last_search_forward: bool,
    running: bool,
}

struct CountKey {
    count: u64,
    key: []u8,
}

fn set_message(ui: ref Ui, value: []u8) {
    ui.message = bytes.clone(value);
}

fn key_is(key: []u8, value: u8) -> bool {
    return len(key) == 1 && key[0] == value;
}

fn key_sequence(key: []u8, sequence: []u8) -> bool {
    return bytes.equal(key, sequence);
}

fn key_left(key: []u8) -> bool {
    return key_sequence(key, "\x1b[D") || key_sequence(key, "\x1bOD");
}

fn key_right(key: []u8) -> bool {
    return key_sequence(key, "\x1b[C") || key_sequence(key, "\x1bOC");
}

fn key_up(key: []u8) -> bool {
    return key_sequence(key, "\x1b[A") || key_sequence(key, "\x1bOA");
}

fn key_down(key: []u8) -> bool {
    return key_sequence(key, "\x1b[B") || key_sequence(key, "\x1bOB");
}

fn key_home(key: []u8) -> bool {
    return key_sequence(key, "\x1b[H") || key_sequence(key, "\x1bOH") ||
        key_sequence(key, "\x1b[1~") || key_sequence(key, "\x1b[7~");
}

fn key_end(key: []u8) -> bool {
    return key_sequence(key, "\x1b[F") || key_sequence(key, "\x1bOF") ||
        key_sequence(key, "\x1b[4~") || key_sequence(key, "\x1b[8~");
}

fn key_delete(key: []u8) -> bool {
    return key_sequence(key, "\x1b[3~");
}

fn line_number_at(doc: ref text.Text, start: u64) -> u64 {
    if (start > text.byte_len(doc)) { trap; }
    var line: u64 = 1;
    for (var pos: u64 = 0; pos < start; pos += 1) {
        if (text.byte_at(doc, pos) == '\n') { line += 1; }
    }
    return line;
}

fn reset_top_to_cursor(ui: ref Ui) {
    ui.top_start = nav.line_start(ui.editor.doc, model.cursor(ui.editor));
    ui.top_line_number = line_number_at(ui.editor.doc, ui.top_start);
}

fn ensure_vertical_visibility(ui: ref Ui, rows: u64) {
    var cursor_line = nav.line_start(ui.editor.doc, model.cursor(ui.editor));
    if (ui.top_start > text.byte_len(ui.editor.doc) || cursor_line < ui.top_start) {
        reset_top_to_cursor(ui);
        return;
    }

    var content_rows: u64 = 1;
    if (rows > 2) { content_rows = rows - 2; }
    while (true) {
        var line = ui.top_start;
        var visible = false;
        var row: u64 = 0;
        while (row < content_rows) {
            if (line == cursor_line) { visible = true; break; }
            var next = nav.next_line_start(ui.editor.doc, line);
            match (next) {
                none { break; }
                some(value) { line = value; }
            }
            row += 1;
        }
        if (visible) { return; }
        var next_top = nav.next_line_start(ui.editor.doc, ui.top_start);
        match (next_top) {
            none { reset_top_to_cursor(ui); return; }
            some(value) {
                ui.top_start = value;
                ui.top_line_number += 1;
            }
        }
    }
}

fn ensure_horizontal_visibility(ui: ref Ui, cols: u64) {
    if (cols <= 8) { ui.hscroll = 0; return; }
    var pos = model.cursor(ui.editor);
    var start = nav.line_start(ui.editor.doc, pos);
    var column = nav.screen_column(ui.editor.doc, start, pos, ui.editor.tab_width);
    var content_cols = cols - 6;
    if (column < ui.hscroll) { ui.hscroll = column; }
    else if (column >= ui.hscroll + content_cols) { ui.hscroll = column - content_cols + 1; }
}

fn redraw(ui: ref Ui) {
    var rows = term.rows();
    var cols = term.cols();
    ensure_vertical_visibility(ui, rows);
    ensure_horizontal_visibility(ui, cols);
    var frame = render.draw(
        ui.editor,
        ui.path,
        ui.message,
        ui.top_start,
        ui.top_line_number,
        ui.hscroll,
        rows,
        cols
    );
    term.write(frame.bytes);
}

fn save(ui: ref Ui) -> bool {
    if (fs.write(ui.path, text.to_bytes(ui.editor.doc))) {
        model.mark_saved(ui.editor);
        set_message(ui, "written");
        return true;
    }
    set_message(ui, "write failed");
    return false;
}

fn read_count(first: []u8) -> CountKey {
    if (len(first) != 1 || first[0] < '1' || first[0] > '9') {
        return CountKey { count: 1, key: first };
    }
    var count: u64 = (first[0] - '0') as u64;
    while (true) {
        var next_opt = term.read_key();
        match (next_opt) {
            none { return CountKey { count: count, key: [] }; }
            some(next) {
                if (len(next) == 1 && next[0] >= '0' && next[0] <= '9') {
                    count = count * 10 + ((next[0] - '0') as u64);
                } else {
                    return CountKey { count: count, key: next };
                }
            }
        }
    }
}

fn drop_prompt_atom(value: []u8) {
    if (len(value) == 0) { return; }
    var start = len(value) - 1;
    while (start > 0 && (value[start] & 0xc0) == 0x80) { start -= 1; }
    splice(value, start, len(value), []);
}

fn prompt(ui: ref Ui, prefix: []u8) -> ?[]u8 {
    var value: []u8 = [];
    while (true) {
        var shown = bytes.clone(prefix);
        bytes.append(shown, value);
        set_message(ui, shown);
        redraw(ui);
        var key_opt = term.read_key();
        match (key_opt) {
            none { set_message(ui, ""); return none; }
            some(key) {
                if (key_is(key, 0x1b) || key_is(key, 0x03)) {
                    set_message(ui, "");
                    return none;
                }
                if (key_is(key, '\r') || key_is(key, '\n')) {
                    set_message(ui, "");
                    return some(value);
                }
                if (key_is(key, 0x7f) || key_is(key, 0x08)) {
                    drop_prompt_atom(value);
                } else if (len(key) > 0 && key[0] >= 0x20 && key[0] != 0x7f) {
                    bytes.append(value, key);
                }
            }
        }
    }
}

fn run_search(ui: ref Ui, forward: bool) {
    var prefix: []u8 = "/";
    if (!forward) { prefix = "?"; }
    var query_opt = prompt(ui, prefix);
    match (query_opt) {
        none { return; }
        some(query) {
            if (len(query) == 0) { return; }
            ui.last_search = bytes.clone(query);
            ui.last_search_forward = forward;
            var pos = model.cursor(ui.editor);
            var found: ?u64 = none;
            if (forward) {
                var start = pos;
                if (start < text.byte_len(ui.editor.doc)) { start = nav.next_atom(ui.editor.doc, start); }
                found = model.find_forward(ui.editor, query, start);
                if (found is none) { found = model.find_forward(ui.editor, query, 0); }
            } else {
                found = model.find_backward(ui.editor, query, pos);
                if (found is none) { found = model.find_backward(ui.editor, query, text.byte_len(ui.editor.doc)); }
            }
            match (found) {
                none { set_message(ui, "pattern not found"); }
                some(value) { model.set_cursor(ui.editor, value); }
            }
        }
    }
}

fn repeat_search(ui: ref Ui, same_direction: bool) {
    if (len(ui.last_search) == 0) { return; }
    var forward = ui.last_search_forward;
    if (!same_direction) { forward = !forward; }
    var pos = model.cursor(ui.editor);
    var found: ?u64 = none;
    if (forward) {
        var start = pos;
        if (start < text.byte_len(ui.editor.doc)) { start = nav.next_atom(ui.editor.doc, start); }
        found = model.find_forward(ui.editor, ui.last_search, start);
        if (found is none) { found = model.find_forward(ui.editor, ui.last_search, 0); }
    } else {
        found = model.find_backward(ui.editor, ui.last_search, pos);
        if (found is none) { found = model.find_backward(ui.editor, ui.last_search, text.byte_len(ui.editor.doc)); }
    }
    match (found) {
        none { set_message(ui, "pattern not found"); }
        some(value) { model.set_cursor(ui.editor, value); }
    }
}

fn recenter(ui: ref Ui) {
    reset_top_to_cursor(ui);
    var half: u64 = 0;
    if (term.rows() > 2) { half = (term.rows() - 2) / 2; }
    var n: u64 = 0;
    while (n < half) {
        var previous = nav.previous_line_start(ui.editor.doc, ui.top_start);
        match (previous) {
            none { break; }
            some(value) {
                ui.top_start = value;
                if (ui.top_line_number > 1) { ui.top_line_number -= 1; }
            }
        }
        n += 1;
    }
}

fn do_motion(ui: ref Ui, key: []u8, count: u64) -> bool {
    if (key_is(key, 'h') || key_left(key)) { model.move_left(ui.editor, count); return true; }
    if (key_is(key, 'l') || key_right(key)) { model.move_right(ui.editor, count); return true; }
    if (key_is(key, 'j') || key_down(key)) { model.move_vertical(ui.editor, true, count); return true; }
    if (key_is(key, 'k') || key_up(key)) { model.move_vertical(ui.editor, false, count); return true; }
    if (key_is(key, 'w')) { model.move_word_forward(ui.editor, count); return true; }
    if (key_is(key, 'b')) { model.move_word_backward(ui.editor, count); return true; }
    if (key_is(key, 'e')) { model.move_word_end(ui.editor, count); return true; }
    if (key_is(key, '0') || key_home(key)) { model.move_line_start(ui.editor, false); return true; }
    if (key_is(key, '^')) { model.move_line_start(ui.editor, true); return true; }
    if (key_is(key, '$') || key_end(key)) { model.move_line_end(ui.editor); return true; }
    if (key_is(key, 'G')) { model.move_document_end(ui.editor); return true; }
    return false;
}

fn operator_command(ui: ref Ui, op: u8) {
    var second_opt = term.read_key();
    match (second_opt) {
        none { return; }
        some(second) {
            var span_opt: ?model.Span = none;
            var is_linewise = false;
            if (key_is(second, op)) {
                span_opt = some(model.current_line_span(ui.editor));
                is_linewise = true;
            } else if (len(second) == 1) {
                span_opt = model.motion_span(ui.editor, second[0]);
            }
            match (span_opt) {
                none { return; }
                some(span) {
                    if (op == 'y') {
                        model.yank_span(ui.editor, span, is_linewise);
                        model.set_cursor(ui.editor, span.start);
                        set_message(ui, "yanked");
                    } else if (op == 'c' && is_linewise) {
                        linewise.change_current_line(ui.editor);
                    } else if (op == 'c') {
                        model.delete_span(ui.editor, span, false, true);
                    } else {
                        model.delete_span(ui.editor, span, is_linewise, false);
                    }
                }
            }
        }
    }
}

fn visual_command(ui: ref Ui, key: []u8, count: u64) {
    if (do_motion(ui, key, count)) { return; }
    if (key_is(key, 0x1b) || key_is(key, 0x03) || key_is(key, 'v')) {
        model.leave_visual(ui.editor);
        return;
    }
    if (key_is(key, 'V')) {
        if (ui.editor.mode is model.Mode.visual_line) { model.leave_visual(ui.editor); }
        else { ui.editor.mode = model.Mode.visual_line; }
        return;
    }
    if (key_is(key, 'o')) {
        var old = ui.editor.visual_anchor;
        ui.editor.visual_anchor = model.cursor(ui.editor);
        model.set_cursor(ui.editor, old);
        return;
    }
    if (key_is(key, 'd') || key_is(key, 'x') || key_is(key, 'c') || key_is(key, 'y')) {
        var span_opt = model.visual_span(ui.editor);
        match (span_opt) {
            none { return; }
            some(span) {
                var is_linewise = ui.editor.mode is model.Mode.visual_line;
                if (key_is(key, 'y')) {
                    model.yank_span(ui.editor, span, is_linewise);
                    model.set_cursor(ui.editor, span.start);
                    model.leave_visual(ui.editor);
                    set_message(ui, "yanked");
                } else {
                    var change = key_is(key, 'c');
                    model.delete_span(ui.editor, span, is_linewise, change);
                }
            }
        }
    }
}

fn read_utf8_tail(first: u8) -> []u8 {
    var wanted: u64 = 1;
    if (first >= 0xc2 && first <= 0xdf) { wanted = 2; }
    else if (first >= 0xe0 && first <= 0xef) { wanted = 3; }
    else if (first >= 0xf0 && first <= 0xf4) { wanted = 4; }
    var out: []u8 = [first];
    while (len(out) < wanted) {
        var next_opt = term.read_key_timeout(10);
        match (next_opt) {
            none { break; }
            some(next) { bytes.append(out, next); }
        }
    }
    return out;
}

fn literal_insert(ui: ref Ui) {
    var next_opt = term.read_key();
    match (next_opt) {
        none { return; }
        some(next) {
            if (key_is(next, 'x')) {
                var a_opt = term.read_key();
                var b_opt = term.read_key();
                match (a_opt) {
                    none { return; }
                    some(a) {
                        match (b_opt) {
                            none { return; }
                            some(b) {
                                if (len(a) != 1 || len(b) != 1) { return; }
                                var hex: []u8 = [a[0], b[0]];
                                var parsed = display.parse_byte_hex(hex);
                                match (parsed) {
                                    none { set_message(ui, "invalid byte literal"); }
                                    some(value) { model.insert_byte(ui.editor, value); }
                                }
                            }
                        }
                    }
                }
            } else if (len(next) > 0 && next[0] != 0x1b) {
                model.insert_bytes(ui.editor, next);
            }
        }
    }
}

fn insert_command(ui: ref Ui, key: []u8) {
    if (key_is(key, 0x1b) || key_is(key, 0x03)) {
        model.leave_insert(ui.editor);
        return;
    }
    if (key_left(key)) { model.move_left(ui.editor, 1); return; }
    if (key_right(key)) { model.move_right(ui.editor, 1); return; }
    if (key_up(key)) { model.move_vertical(ui.editor, false, 1); return; }
    if (key_down(key)) { model.move_vertical(ui.editor, true, 1); return; }
    if (key_home(key)) { model.move_line_start(ui.editor, false); return; }
    if (key_end(key)) { model.move_line_end(ui.editor); return; }
    if (key_delete(key)) { model.delete_forward(ui.editor, 1); return; }
    if (key_is(key, 0x7f) || key_is(key, 0x08)) { model.backspace(ui.editor); return; }
    if (key_is(key, '\r') || key_is(key, '\n')) { model.insert_newline(ui.editor); return; }
    if (key_is(key, '\t')) { model.insert_byte(ui.editor, '\t'); return; }
    if (key_is(key, 0x16)) { literal_insert(ui); return; }
    if (len(key) > 1 && key[0] != 0x1b) {
        model.insert_bytes(ui.editor, key);
        return;
    }
    if (len(key) == 1 && key[0] >= 0x20) {
        model.insert_bytes(ui.editor, read_utf8_tail(key[0]));
    }
}

fn colon_command(ui: ref Ui) {
    var command_opt = prompt(ui, ":");
    match (command_opt) {
        none { return; }
        some(raw) {
            var command = bytes.trim_ascii(raw);
            if (bytes.equal(command, "w") || bytes.equal(command, "write")) { save(ui); return; }
            if (bytes.equal(command, "wq") || bytes.equal(command, "x")) {
                if (save(ui)) { ui.running = false; }
                return;
            }
            if (bytes.equal(command, "q!")) { ui.running = false; return; }
            if (bytes.equal(command, "q") || bytes.equal(command, "quit")) {
                if (model.dirty(ui.editor)) { set_message(ui, "unsaved changes; use :q!"); }
                else { ui.running = false; }
                return;
            }
            if (bytes.equal(command, "unicode all")) {
                ui.editor.unicode_guard = model.UnicodeGuard.all_non_ascii;
                set_message(ui, "Unicode guard: all non-ASCII");
                return;
            }
            if (bytes.equal(command, "unicode suspicious")) {
                ui.editor.unicode_guard = model.UnicodeGuard.suspicious;
                set_message(ui, "Unicode guard: suspicious");
                return;
            }
            if (bytes.equal(command, "unicode off")) {
                ui.editor.unicode_guard = model.UnicodeGuard.off;
                set_message(ui, "Unicode guard: off");
                return;
            }
            if (bytes.starts_with(command, "byte ")) {
                var literal = bytes.trim_ascii(bytes.slice(command, 5, len(command)));
                var parsed = display.parse_byte_hex(literal);
                match (parsed) {
                    none { set_message(ui, "usage: :byte FF"); }
                    some(value) {
                        var pos = model.cursor(ui.editor);
                        model.insert_byte(ui.editor, value);
                        model.commit_change(ui.editor, "raw byte");
                        model.set_cursor(ui.editor, pos);
                        set_message(ui, "inserted raw byte");
                    }
                }
                return;
            }
            if (bytes.equal(command, "help")) {
                set_message(ui, "i/a/o edit · hjkl/arrows/wbe move · d/y/c ops · v/V select · / search · :w :q · ^VxFF raw byte");
                return;
            }
            set_message(ui, "unknown command");
        }
    }
}

fn normal_command(ui: ref Ui, first: []u8) {
    var parsed = read_count(first);
    var count = parsed.count;
    var key = parsed.key;
    if (len(key) == 0) { return; }
    if (do_motion(ui, key, count)) { return; }
    if (key_is(key, 0x03) || key_is(key, 0x1b)) { set_message(ui, ""); return; }

    if (key_is(key, 'g')) {
        var second_opt = term.read_key();
        match (second_opt) {
            none { return; }
            some(second) { if (key_is(second, 'g')) { model.move_document_start(ui.editor); } }
        }
        return;
    }
    if (key_is(key, 'z')) {
        var second_opt = term.read_key();
        match (second_opt) { none { } some(second) { if (key_is(second, 'z')) { recenter(ui); } } }
        return;
    }
    if (key_is(key, 'i')) { model.enter_insert(ui.editor, model.cursor(ui.editor)); return; }
    if (key_is(key, 'a')) {
        var pos = model.cursor(ui.editor);
        var end = nav.line_end(ui.editor.doc, pos);
        if (pos < end) { pos = nav.next_atom(ui.editor.doc, pos); }
        model.enter_insert(ui.editor, pos);
        return;
    }
    if (key_is(key, 'I')) {
        model.enter_insert(ui.editor, nav.first_nonblank(ui.editor.doc, model.cursor(ui.editor)));
        return;
    }
    if (key_is(key, 'A')) {
        model.enter_insert(ui.editor, nav.line_end(ui.editor.doc, model.cursor(ui.editor)));
        return;
    }
    if (key_is(key, 'o')) { model.open_line(ui.editor, true); return; }
    if (key_is(key, 'O')) { model.open_line(ui.editor, false); return; }
    if (key_is(key, 'x') || key_delete(key)) { model.delete_forward(ui.editor, count); return; }
    if (key_is(key, 's')) {
        var pos = model.cursor(ui.editor);
        var end = pos;
        var n: u64 = 0;
        var line_end = nav.line_end(ui.editor.doc, pos);
        while (n < count && end < line_end) { end = nav.next_atom(ui.editor.doc, end); n += 1; }
        if (end > pos) { model.delete_span(ui.editor, model.Span { start: pos, end: end }, false, true); }
        else { model.enter_insert(ui.editor, pos); }
        return;
    }
    if (key_is(key, 'S')) { linewise.change_current_line(ui.editor); return; }
    if (key_is(key, 'X')) {
        var pos = model.cursor(ui.editor);
        var start = pos;
        var n: u64 = 0;
        while (n < count && start > nav.line_start(ui.editor.doc, pos)) { start = nav.previous_atom(ui.editor.doc, start); n += 1; }
        if (start < pos) { model.delete_span(ui.editor, model.Span { start: start, end: pos }, false, false); }
        return;
    }
    if (key_is(key, 'D') || key_is(key, 'C')) {
        var pos = model.cursor(ui.editor);
        var end = nav.line_end(ui.editor.doc, pos);
        if (end > pos) { model.delete_span(ui.editor, model.Span { start: pos, end: end }, false, key_is(key, 'C')); }
        else if (key_is(key, 'C')) { model.enter_insert(ui.editor, pos); }
        return;
    }
    if (key_is(key, 'd') || key_is(key, 'y') || key_is(key, 'c')) { operator_command(ui, key[0]); return; }
    if (key_is(key, 'Y')) {
        var span = model.current_line_span(ui.editor);
        model.yank_span(ui.editor, span, true);
        set_message(ui, "yanked line");
        return;
    }
    if (key_is(key, 'p')) { linewise.paste(ui.editor, true); return; }
    if (key_is(key, 'P')) { linewise.paste(ui.editor, false); return; }
    if (key_is(key, 'u')) { model.undo(ui.editor); return; }
    if (key_is(key, 0x12)) { model.redo(ui.editor); return; }
    if (key_is(key, 'r')) {
        var replacement_opt = term.read_key();
        match (replacement_opt) { none { } some(value) { model.replace_atom(ui.editor, value); } }
        return;
    }
    if (key_is(key, 'v')) { model.enter_visual(ui.editor, false); return; }
    if (key_is(key, 'V')) { model.enter_visual(ui.editor, true); return; }
    if (key_is(key, '/')) { run_search(ui, true); return; }
    if (key_is(key, '?')) { run_search(ui, false); return; }
    if (key_is(key, 'n')) { repeat_search(ui, true); return; }
    if (key_is(key, 'N')) { repeat_search(ui, false); return; }
    if (key_is(key, ':')) { colon_command(ui); return; }
}

fn run(path: []u8) {
    var content: []u8 = [];
    var content_opt = fs.read(path);
    match (content_opt) { none { } some(value) { content = value; } }
    var editor = model.create(content);
    var ui = new Ui {
        editor: editor,
        path: bytes.clone(path),
        top_start: 0,
        top_line_number: 1,
        hscroll: 0,
        message: "",
        last_search: [],
        last_search_forward: true,
        running: true,
    };

    term.enter_ui();
    while (ui.running) {
        redraw(ui);
        var key_opt = term.read_key();
        match (key_opt) {
            none { ui.running = false; }
            some(key) {
                if (ui.editor.mode is model.Mode.insert) {
                    insert_command(ui, key);
                } else if (ui.editor.mode is model.Mode.visual || ui.editor.mode is model.Mode.visual_line) {
                    var parsed = read_count(key);
                    visual_command(ui, parsed.key, parsed.count);
                } else {
                    normal_command(ui, key);
                }
            }
        }
    }
    term.leave_ui();
}

pub fn main() {
    var args = sys.args();
    if (len(args) == 0) {
        return;
    }
    run(args[0]);
}
