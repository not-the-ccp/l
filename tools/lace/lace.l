import arrays;
import bytes;
import fs;
import json;
import lsp;
import lsp_client as client;
import proc;
import strconv;
import sys;
import term;
import utf8;

enum Mode { normal, insert, visual, visual_line }
enum Theme { graphite, paper, mono }

struct Highlight {
    line: u64,
    start: u64,
    length: u64,
    token_type: u64,
}

struct Diagnostic {
    line: u64,
    message: []u8,
}

struct Edit {
    start: u64,
    removed: []u8,
    inserted: []u8,
}

struct Range {
    start: u64,
    end: u64,
}

struct Change {
    edits: []Edit,
    before: u64,
    after: u64,
}

struct Editor {
    path: []u8,
    uri: []u8,
    text: []u8,
    lines: []u64,
    cursor: u64,
    goal_col: u64,
    version: i64,
    mode: Mode,
    lsp: ref client.Client,
    lsp_active: bool,
    lsp_dirty: bool,
    pending_lsp: []client.TextChange,
    semantic_request: i64,
    semantic_request_start: u64,
    semantic_request_end: u64,
    semantic_request_revision: u64,
    semantic_start: u64,
    semantic_end: u64,
    revision: u64,
    highlights: []Highlight,
    diagnostics: []Diagnostic,
    diagnostic_count: u64,
    status: []u8,
    theme: Theme,
    relative_numbers: bool,
    top_line: u64,
    hscroll: u64,
    yank: []u8,
    yank_linewise: bool,
    undo: []Change,
    redo: []Change,
    current_edits: []Edit,
    current_before: u64,
    recording: bool,
    state_id: u64,
    next_state_id: u64,
    saved_state_id: u64,
    last_search: []u8,
    last_search_forward: bool,
    last_find: []u8,
    last_find_forward: bool,
    last_find_till: bool,
    visual_anchor: u64,
    tab_width: u64,
    scrolloff: u64,
}

const AUTO_LSP_LIMIT: u64 = 131072;
const GUTTER: u64 = 8;

fn make_uri(path: []u8) -> []u8 {
    var out: []u8 = "file://";
    bytes.append(out, path);
    return out;
}

fn set_status(editor: ref Editor, value: []u8) { editor.status = bytes.clone(value); }
fn dirty(editor: ref Editor) -> bool { return editor.state_id != editor.saved_state_id; }

fn visual_active(editor: ref Editor) -> bool {
    return (editor.mode is Mode.visual) || (editor.mode is Mode.visual_line);
}

fn visual_range(editor: ref Editor) -> ?Range {
    if (!visual_active(editor)) { return none; }
    if (editor.mode is Mode.visual_line) {
        var a = line_of_offset(editor, editor.visual_anchor);
        var b = line_of_offset(editor, editor.cursor);
        if (b < a) { var t = a; a = b; b = t; }
        var end = len(editor.text);
        if (b + 1 < len(editor.lines)) { end = line_start(editor, b + 1); }
        return some(Range { start: line_start(editor, a), end: end });
    }
    var a = editor.visual_anchor; var b = editor.cursor;
    if (b < a) { var t = a; a = b; b = t; }
    var end = b;
    if (end < len(editor.text)) { end = next_char(editor.text, end); }
    return some(Range { start: a, end: end });
}

fn leave_visual(editor: ref Editor) {
    editor.mode = Mode.normal;
    set_status(editor, "");
}

fn syntax_color(editor: ref Editor, token_type: u64) -> []u8 {
    if (editor.theme is Theme.mono) { if (token_type == 8) { return "\x1b[2m"; } return "\x1b[0m"; }
    if (editor.theme is Theme.paper) {
        if (token_type == 1) { return "\x1b[38;5;24m"; }
        if (token_type == 2) { return "\x1b[38;5;25m"; }
        if (token_type == 4) { return "\x1b[38;5;90m"; }
        if (token_type == 5) { return "\x1b[38;5;130m"; }
        if (token_type == 6) { return "\x1b[38;5;28m"; }
        if (token_type == 7) { return "\x1b[38;5;124m"; }
        if (token_type == 8) { return "\x1b[38;5;244m"; }
        if (token_type == 9) { return "\x1b[38;5;238m"; }
        return "\x1b[38;5;30m";
    }
    if (token_type == 1) { return "\x1b[38;5;81m"; }
    if (token_type == 2) { return "\x1b[38;5;75m"; }
    if (token_type == 4) { return "\x1b[38;5;176m"; }
    if (token_type == 5) { return "\x1b[38;5;215m"; }
    if (token_type == 6) { return "\x1b[38;5;114m"; }
    if (token_type == 7) { return "\x1b[38;5;203m"; }
    if (token_type == 8) { return "\x1b[38;5;244m"; }
    if (token_type == 9) { return "\x1b[38;5;252m"; }
    if (token_type == 10) { return "\x1b[38;5;117m"; }
    return "\x1b[0m";
}

struct Config {
    theme: Theme,
    relative_numbers: bool,
    tab_width: u64,
    scrolloff: u64,
}

fn default_config() -> Config { return Config { theme: Theme.graphite, relative_numbers: false, tab_width: 4, scrolloff: 3 }; }

fn config_path() -> ?[]u8 {
    var explicit = sys.getenv("LACE_CONFIG");
    match (explicit) { some(path) { if (len(path) > 0) { return some(path); } } none { } }
    var base: ?[]u8 = sys.getenv("XDG_CONFIG_HOME");
    match (base) {
        some(dir) { var out = bytes.clone(dir); if (len(out) > 0 && out[len(out)-1] != '/') { push(out, '/'); } bytes.append(out, "lace/config.ini"); return some(out); }
        none { }
    }
    var home = sys.getenv("HOME");
    match (home) { some(dir) { var out = bytes.clone(dir); if (len(out) > 0 && out[len(out)-1] != '/') { push(out, '/'); } bytes.append(out, ".config/lace/config.ini"); return some(out); } none { } }
    return none;
}

fn load_config() -> Config {
    var cfg = default_config();
    var path_opt = config_path();
    match (path_opt) {
        none { return cfg; }
        some(path) {
            var data_opt = fs.read(path); match (data_opt) {
                none { return cfg; }
                some(data) {
                    var off: u64 = 0;
                    while (off <= len(data)) {
                        var end = off; while (end < len(data) && data[end] != '\n') { end += 1; }
                        var line = bytes.trim_ascii(bytes.slice(data, off, end));
                        if (len(line) > 0 && line[0] != '#' && line[0] != ';') {
                            var eq = bytes.find_byte(line, '=', 0); match (eq) { none { } some(i) {
                                var key = bytes.trim_ascii(bytes.slice(line, 0, i)); var value = bytes.trim_ascii(bytes.slice(line, i + 1, len(line)));
                                if (bytes.equal(key, "theme")) {
                                    if (bytes.equal(value, "graphite")) { cfg.theme = Theme.graphite; }
                                    else if (bytes.equal(value, "paper") || bytes.equal(value, "linen")) { cfg.theme = Theme.paper; }
                                    else if (bytes.equal(value, "mono")) { cfg.theme = Theme.mono; }
                                } else if (bytes.equal(key, "relative_numbers")) { cfg.relative_numbers = bytes.equal(value, "true") || bytes.equal(value, "yes") || bytes.equal(value, "1"); }
                                else if (bytes.equal(key, "tab_width")) { var n = strconv.parse_u64(value); match (n) { some(v) { if (v >= 1 && v <= 16) { cfg.tab_width = v; } } none { } } }
                                else if (bytes.equal(key, "scrolloff")) { var n = strconv.parse_u64(value); match (n) { some(v) { if (v <= 20) { cfg.scrolloff = v; } } none { } } }
                            } }
                        }
                        if (end >= len(data)) { break; } off = end + 1;
                    }
                }
            }
        }
    }
    return cfg;
}

fn rebuild_lines(editor: ref Editor) {
    arrays.clear(editor.lines);
    push(editor.lines, 0);
    for (var i: u64 = 0; i < len(editor.text); i += 1) {
        if (editor.text[i] == '\n' && i + 1 <= len(editor.text)) { push(editor.lines, i + 1); }
    }
}

fn line_of_offset(editor: ref Editor, offset: u64) -> u64 {
    if (len(editor.lines) == 0) { return 0; }
    var lo: u64 = 0; var hi = len(editor.lines);
    while (lo + 1 < hi) {
        var mid = lo + (hi - lo) / 2;
        if (editor.lines[mid] <= offset) { lo = mid; } else { hi = mid; }
    }
    return lo;
}

fn line_start(editor: ref Editor, line: u64) -> u64 {
    if (line >= len(editor.lines)) { return len(editor.text); }
    return editor.lines[line];
}

fn line_end(editor: ref Editor, line: u64) -> u64 {
    if (line + 1 < len(editor.lines)) {
        var value = editor.lines[line + 1];
        if (value > 0 && editor.text[value - 1] == '\n') { return value - 1; }
        return value;
    }
    return len(editor.text);
}

fn line_bytes(editor: ref Editor, line: u64) -> []u8 {
    return bytes.slice(editor.text, line_start(editor, line), line_end(editor, line));
}

fn position_from_offset(editor: ref Editor, offset: u64) -> lsp.Position {
    if (offset > len(editor.text)) { offset = len(editor.text); }
    var line = line_of_offset(editor, offset);
    var start = line_start(editor, line);
    return lsp.Position { line: line, character: utf8.utf16_len(bytes.slice(editor.text, start, offset)) };
}

fn offset_from_position(editor: ref Editor, pos: lsp.Position) -> u64 {
    if (pos.line >= len(editor.lines)) { return len(editor.text); }
    var start = line_start(editor, pos.line);
    var line = bytes.slice(editor.text, start, line_end(editor, pos.line));
    return start + utf8.utf16_to_byte(line, pos.character);
}

fn next_codepoint(text: []u8, pos: u64) -> u64 {
    if (pos >= len(text)) { return len(text); }
    return pos + utf8.valid_width(text, pos);
}

fn variation_or_modifier(cp: u32) -> bool {
    return (cp >= 0xfe00 && cp <= 0xfe0f) || (cp >= 0x1f3fb && cp <= 0x1f3ff);
}

fn regional_indicator(cp: u32) -> bool { return cp >= 0x1f1e6 && cp <= 0x1f1ff; }

fn next_char(text: []u8, pos: u64) -> u64 {
    if (pos >= len(text)) { return len(text); }
    var first = utf8.decode_at(text, pos); var q = next_codepoint(text, pos);
    if (regional_indicator(first) && q < len(text) && regional_indicator(utf8.decode_at(text, q))) { q = next_codepoint(text, q); }
    while (q < len(text)) {
        var cp = utf8.decode_at(text, q); var r = next_codepoint(text, q);
        if (cp == 0x200d) {
            q = r;
            if (q < len(text)) { q = next_codepoint(text, q); }
            continue;
        }
        if (variation_or_modifier(cp) || term.text_width(bytes.slice(text, q, r)) == 0) { q = r; continue; }
        break;
    }
    return q;
}

fn previous_char(text: []u8, pos: u64) -> u64 {
    if (pos == 0) { return 0; }
    var line = pos;
    while (line > 0 && text[line - 1] != '\n') { line -= 1; }
    var p = line; var last = line;
    while (p < pos) { last = p; var q = next_char(text, p); if (q <= p || q >= pos) { return last; } p = q; }
    return last;
}


fn display_col(line: []u8, byte_end: u64, tab_width: u64) -> u64 {
    if (byte_end > len(line)) { byte_end = len(line); }
    var col: u64 = 0; var seg: u64 = 0; var p: u64 = 0;
    while (p < byte_end) {
        if (line[p] == '\t') {
            if (seg < p) { col += term.text_width(bytes.slice(line, seg, p)); }
            var width = tab_width; if (width == 0) { width = 4; }
            col += width - (col % width); p += 1; seg = p;
        } else { p = next_char(line, p); }
    }
    if (seg < byte_end) { col += term.text_width(bytes.slice(line, seg, byte_end)); }
    return col;
}

fn byte_at_display_col(line: []u8, target: u64, tab_width: u64) -> u64 {
    var col: u64 = 0; var p: u64 = 0;
    while (p < len(line) && col < target) {
        if (line[p] == '\t') {
            var width = tab_width; if (width == 0) { width = 4; }
            var add = width - (col % width); if (col + add > target) { break; }
            col += add; p += 1;
        } else {
            var q = next_char(line, p); var add = term.text_width(bytes.slice(line, p, q));
            if (col + add > target) { break; }
            col += add; p = q;
        }
    }
    return p;
}

fn append_display_text(out: []u8, data: []u8, start: u64, end: u64, col: u64, tab_width: u64) -> u64 {
    var p = start; var seg = start;
    while (p < end) {
        if (data[p] == '\t') {
            if (seg < p) { var part = bytes.slice(data, seg, p); bytes.append(out, part); col += term.text_width(part); }
            var width = tab_width; if (width == 0) { width = 4; }
            var count = width - (col % width); append_spaces(out, count); col += count; p += 1; seg = p;
        } else { p = next_char(data, p); }
    }
    if (seg < end) { var part = bytes.slice(data, seg, end); bytes.append(out, part); col += term.text_width(part); }
    return col;
}

fn is_word(value: u8) -> bool {
    return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') ||
        (value >= '0' && value <= '9') || value == '_' || value >= 0x80;
}
fn is_space(value: u8) -> bool { return value == ' ' || value == '\t' || value == '\r' || value == '\n'; }

fn word_class(value: u8) -> u8 {
    if (is_space(value)) { return 0; }
    if (is_word(value)) { return 1; }
    return 2;
}

fn word_next(editor: ref Editor, pos: u64) -> u64 {
    if (pos >= len(editor.text)) { return len(editor.text); }
    var p = pos; var cls = word_class(editor.text[p]);
    while (p < len(editor.text) && word_class(editor.text[p]) == cls) { p = next_char(editor.text, p); }
    while (p < len(editor.text) && is_space(editor.text[p])) { p = next_char(editor.text, p); }
    return p;
}

fn word_prev(editor: ref Editor, pos: u64) -> u64 {
    if (pos == 0) { return 0; }
    var p = previous_char(editor.text, pos);
    while (p > 0 && is_space(editor.text[p])) { p = previous_char(editor.text, p); }
    var cls = word_class(editor.text[p]);
    while (p > 0) {
        var q = previous_char(editor.text, p);
        if (word_class(editor.text[q]) != cls) { break; }
        p = q;
    }
    return p;
}

fn word_end(editor: ref Editor, pos: u64) -> u64 {
    if (pos >= len(editor.text)) { return len(editor.text); }
    var p = pos;
    while (p < len(editor.text) && is_space(editor.text[p])) { p = next_char(editor.text, p); }
    if (p >= len(editor.text)) { return p; }
    var cls = word_class(editor.text[p]);
    var last = p;
    while (p < len(editor.text) && word_class(editor.text[p]) == cls) { last = p; p = next_char(editor.text, p); }
    return last;
}

fn first_nonblank(editor: ref Editor, line: u64) -> u64 {
    var p = line_start(editor, line); var end = line_end(editor, line);
    while (p < end && (editor.text[p] == ' ' || editor.text[p] == '\t')) { p += 1; }
    return p;
}

fn move_vertical(editor: ref Editor, down: bool, count: u64) {
    var pos = position_from_offset(editor, editor.cursor);
    if (editor.goal_col == 0) { editor.goal_col = pos.character + 1; }
    var goal = editor.goal_col - 1;
    var line = pos.line;
    if (down) {
        if (line + count >= len(editor.lines)) { line = len(editor.lines) - 1; } else { line += count; }
    } else {
        if (count > line) { line = 0; } else { line -= count; }
    }
    editor.cursor = offset_from_position(editor, lsp.Position { line: line, character: goal });
}

fn reset_goal(editor: ref Editor) { editor.goal_col = 0; }

fn normal_left(editor: ref Editor, count: u64) {
    for (var i: u64 = 0; i < count; i += 1) {
        var start = line_start(editor, line_of_offset(editor, editor.cursor));
        if (editor.cursor <= start) { break; }
        editor.cursor = previous_char(editor.text, editor.cursor);
    }
    reset_goal(editor);
}

fn normal_right(editor: ref Editor, count: u64) {
    for (var i: u64 = 0; i < count; i += 1) {
        var end = line_end(editor, line_of_offset(editor, editor.cursor));
        if (editor.cursor >= end) { break; }
        var p = next_char(editor.text, editor.cursor);
        if (p > end) { p = end; }
        editor.cursor = p;
    }
    reset_goal(editor);
}

fn contains_newline(data: []u8) -> bool {
    return bytes.find_byte(data, '\n', 0) is some(_);
}

fn same_position(a: lsp.Position, b: lsp.Position) -> bool {
    return a.line == b.line && a.character == b.character;
}

fn position_after(start: lsp.Position, text: []u8) -> lsp.Position {
    var line = start.line;
    var character = start.character;
    var segment: u64 = 0;
    for (var i: u64 = 0; i < len(text); i += 1) {
        if (text[i] == '\n') {
            line += 1;
            segment = i + 1;
            character = 0;
        }
    }
    if (segment < len(text)) { character += utf8.utf16_len(bytes.slice(text, segment, len(text))); }
    return lsp.Position { line: line, character: character };
}

fn position_before(a: lsp.Position, b: lsp.Position) -> bool {
    return a.line < b.line || (a.line == b.line && a.character < b.character);
}

fn position_before_or_equal(a: lsp.Position, b: lsp.Position) -> bool {
    return same_position(a, b) || position_before(a, b);
}

fn adjust_highlights(editor: ref Editor, start: u64, end: u64, replacement: []u8) {
    if (len(editor.highlights) == 0) { return; }
    var edit_start = position_from_offset(editor, start);
    var edit_end = position_from_offset(editor, end);
    var new_end = position_after(edit_start, replacement);
    var out: []Highlight = [];
    for (h in editor.highlights) {
        var hs = lsp.Position { line: h.line, character: h.start };
        var he = lsp.Position { line: h.line, character: h.start + h.length };
        if (position_before_or_equal(he, edit_start)) { push(out, h); continue; }
        if (position_before_or_equal(edit_end, hs)) {
            var nh = h;
            if (h.line == edit_end.line) {
                nh.line = new_end.line;
                nh.start = new_end.character + (h.start - edit_end.character);
            } else if (h.line > edit_end.line) {
                if (new_end.line >= edit_end.line) { nh.line += new_end.line - edit_end.line; }
                else { nh.line -= edit_end.line - new_end.line; }
            }
            push(out, nh); continue;
        }
        // Keep the color of a token while the user edits *inside* it on one
        // line. The LSP will correct the classification asynchronously.
        if (edit_start.line == edit_end.line && new_end.line == edit_start.line && h.line == edit_start.line &&
            h.start <= edit_start.character && h.start + h.length >= edit_end.character) {
            var nh = h;
            var removed = edit_end.character - edit_start.character;
            var inserted = new_end.character - edit_start.character;
            if (nh.length + inserted >= removed) { nh.length = nh.length + inserted - removed; if (nh.length > 0) { push(out, nh); } }
        }
    }
    editor.highlights = out;
}

fn adjust_diagnostics(editor: ref Editor, start: u64, end: u64, replacement: []u8) {
    if (len(editor.diagnostics) == 0) { return; }
    var a = position_from_offset(editor, start); var b = position_from_offset(editor, end); var n = position_after(a, replacement);
    var out: []Diagnostic = [];
    for (d in editor.diagnostics) {
        if (d.line < a.line) { push(out, d); continue; }
        if (d.line > b.line) {
            var nd = d;
            if (n.line >= b.line) { nd.line += n.line - b.line; } else { nd.line -= b.line - n.line; }
            push(out, nd);
        }
        // Diagnostics touching the edited line/range are intentionally hidden
        // until the server republishes them. Showing a known-stale marker is
        // worse than briefly showing none.
    }
    editor.diagnostics = out; editor.diagnostic_count = len(out);
}

fn queue_lsp_change(editor: ref Editor, start: u64, end: u64, replacement: []u8) {
    if (!editor.lsp_active) { return; }
    var range = lsp.Range { start: position_from_offset(editor, start), end: position_from_offset(editor, end) };
    // The overwhelmingly common edit burst is insertion-mode typing. Merge
    // adjacent insertions into one LSP change while retaining the original
    // pre-edit range. This keeps protocol traffic and server work bounded by
    // edit groups rather than keystrokes.
    if (start == end && len(editor.pending_lsp) > 0) {
        var i = len(editor.pending_lsp) - 1;
        var last = editor.pending_lsp[i];
        if (same_position(last.range.start, last.range.end) &&
            same_position(range.start, range.end) &&
            same_position(range.start, position_after(last.range.start, last.text))) {
            bytes.append(editor.pending_lsp[i].text, replacement);
            return;
        }
    }
    push(editor.pending_lsp, client.TextChange { range: range, text: bytes.clone(replacement) });
}

fn apply_raw(editor: ref Editor, start: u64, end: u64, replacement: []u8) {
    if (start > end || end > len(editor.text)) { trap; }
    adjust_highlights(editor, start, end, replacement);
    adjust_diagnostics(editor, start, end, replacement);
    queue_lsp_change(editor, start, end, replacement);
    var start_line = line_of_offset(editor, start);
    var old_len = end - start;
    var new_len = len(replacement);

    // Remove old line starts made invalid by replacing [start,end).  A line
    // starting exactly at end is removed too: if the preceding newline was
    // deleted it is no longer a line boundary.  If the replacement introduces
    // one at the same logical location, it is added back below.
    var remove_from = start_line + 1;
    var remove_to = remove_from;
    while (remove_to < len(editor.lines) && editor.lines[remove_to] <= end) { remove_to += 1; }

    var inserted_lines: []u64 = [];
    for (var i: u64 = 0; i < new_len; i += 1) {
        if (replacement[i] == '\n') { push(inserted_lines, start + i + 1); }
    }

    splice(editor.text, start, end, replacement);
    splice(editor.lines, remove_from, remove_to, inserted_lines);

    // Existing line starts after the replaced range shift by the byte delta.
    var first_shift = remove_from + len(inserted_lines);
    if (new_len >= old_len) {
        var delta = new_len - old_len;
        while (first_shift < len(editor.lines)) { editor.lines[first_shift] += delta; first_shift += 1; }
    } else {
        var delta = old_len - new_len;
        while (first_shift < len(editor.lines)) { editor.lines[first_shift] -= delta; first_shift += 1; }
    }

    if (editor.cursor > len(editor.text)) { editor.cursor = len(editor.text); }
    editor.revision += 1;
    editor.semantic_start = 0; editor.semantic_end = 0;
    editor.lsp_dirty = true;
}

fn begin_change(editor: ref Editor) {
    if (editor.recording) { return; }
    arrays.clear(editor.redo);
    arrays.clear(editor.current_edits);
    editor.current_before = editor.state_id;
    editor.recording = true;
}

fn edit(editor: ref Editor, start: u64, end: u64, replacement: []u8) {
    if (!editor.recording) { begin_change(editor); }
    var removed = bytes.slice(editor.text, start, end);
    var inserted = bytes.clone(replacement);
    apply_raw(editor, start, end, replacement);
    push(editor.current_edits, Edit { start: start, removed: removed, inserted: inserted });
}

fn commit_change(editor: ref Editor) {
    if (!editor.recording) { return; }
    editor.recording = false;
    if (len(editor.current_edits) == 0) { return; }
    var after = editor.next_state_id; editor.next_state_id += 1;
    push(editor.undo, Change { edits: arrays.clone(editor.current_edits), before: editor.current_before, after: after });
    editor.state_id = after;
    arrays.clear(editor.current_edits);
}

fn undo(editor: ref Editor) {
    if (editor.recording) { commit_change(editor); }
    if (len(editor.undo) == 0) { set_status(editor, "already at oldest change"); return; }
    var change = pop(editor.undo);
    var i = len(change.edits);
    while (i > 0) {
        i -= 1;
        var e = change.edits[i];
        apply_raw(editor, e.start, e.start + len(e.inserted), e.removed);
        editor.cursor = e.start;
    }
    editor.state_id = change.before;
    push(editor.redo, change);
    set_status(editor, "undo");
}

fn redo(editor: ref Editor) {
    if (len(editor.redo) == 0) { set_status(editor, "already at newest change"); return; }
    var change = pop(editor.redo);
    for (e in change.edits) {
        apply_raw(editor, e.start, e.start + len(e.removed), e.inserted);
        editor.cursor = e.start + len(e.inserted);
    }
    editor.state_id = change.after;
    push(editor.undo, change);
    set_status(editor, "redo");
}

fn delete_range(editor: ref Editor, start: u64, end: u64) {
    if (start > end) { var t = start; start = end; end = t; }
    if (start == end) { return; }
    begin_change(editor); edit(editor, start, end, []); commit_change(editor); editor.cursor = start;
    if (editor.cursor > len(editor.text)) { editor.cursor = len(editor.text); }
}

fn yank_range(editor: ref Editor, start: u64, end: u64, linewise: bool) {
    if (start > end) { var t = start; start = end; end = t; }
    editor.yank = bytes.slice(editor.text, start, end); editor.yank_linewise = linewise; set_status(editor, "yanked");
}

fn insert_one(editor: ref Editor, value: []u8) {
    edit(editor, editor.cursor, editor.cursor, value);
    editor.cursor += len(value);
}

fn backspace(editor: ref Editor) {
    if (editor.cursor == 0) { return; }
    var p = previous_char(editor.text, editor.cursor);
    edit(editor, p, editor.cursor, []); editor.cursor = p;
}

fn delete_insert_at(editor: ref Editor) {
    if (editor.cursor >= len(editor.text)) { return; }
    var end = next_char(editor.text, editor.cursor);
    edit(editor, editor.cursor, end, []);
}

fn save(editor: ref Editor) {
    if (editor.recording) { commit_change(editor); }
    if (fs.write(editor.path, editor.text)) { editor.saved_state_id = editor.state_id; set_status(editor, "saved"); }
    else { set_status(editor, "write failed"); }
}

fn shell_quote(value: []u8) -> []u8 {
    var out: []u8 = []; push(out, '\'');
    for (ch in value) {
        if (ch == '\'') { push(out, '\''); push(out, '\\'); push(out, '\''); push(out, '\''); }
        else { push(out, ch); }
    }
    push(out, '\''); return out;
}

fn expand_shell_command(editor: ref Editor, command: []u8) -> []u8 {
    var out: []u8 = []; var quoted = shell_quote(editor.path); var i: u64 = 0;
    while (i < len(command)) {
        if (command[i] == '\\' && i + 1 < len(command) && command[i + 1] == '%') { push(out, '%'); i += 2; }
        else { if (command[i] == '%') { bytes.append(out, quoted); } else { push(out, command[i]); } i += 1; }
    }
    return out;
}

fn wait_return_to_editor() {
    term.write("\n\x1b[2mpress Enter to return to Lace\x1b[0m");
    while (true) {
        var key = term.read_key(); match (key) { none { break; } some(k) { if (bytes.equal(k, "\n") || bytes.equal(k, "\r")) { break; } } }
    }
}

fn show_help_screen() {
    term.leave_ui();
    term.write("\n\x1b[1mLace\x1b[0m — quiet modal editing, LSP-native\n\n");
    term.write("  move     h j k l   0 ^ $   w b e   gg G   H M L   C-u/C-d C-b/C-f\n");
    term.write("  find     f/F t/T ;   %   / ? n N   * #\n");
    term.write("  insert   i a I A   o O   Tab   C-w word-back   C-u line-back\n");
    term.write("  select   v / V     then motion; y d c > <\n");
    term.write("  edit     d/c/y + motion   dd/cc/yy   x X D C   p P   r   J   >> <<\n");
    term.write("  history  u / C-r\n");
    term.write("  LSP      gd definition   K hover   C-Space completion   = format   [d ]d diagnostics\n");
    term.write("  command  :w :q :q! :wq   :!command   :theme ...   :set ...   :help\n\n");
    term.write("Configuration: $XDG_CONFIG_HOME/lace/config.ini or ~/.config/lace/config.ini\n");
    wait_return_to_editor();
    term.enter_ui();
}

fn shell_escape(editor: ref Editor, command: []u8) {
    if (editor.recording) { commit_change(editor); }
    if (editor.lsp_dirty) { sync_lsp(editor); }
    var expanded = expand_shell_command(editor, command);
    term.leave_ui();
    term.write("\n\x1b[1m[lace]\x1b[0m $ "); term.write(expanded); term.write("\n");
    var code = proc.shell(expanded);
    var msg: []u8 = "\n\x1b[2m[lace] exited "; strconv.append_i64(msg, code); bytes.append(msg, "\x1b[0m\n"); term.write(msg);
    wait_return_to_editor();
    term.enter_ui();
    var status: []u8 = "command exited "; strconv.append_i64(status, code); set_status(editor, status);
}

fn json_number(value: json.Json) -> ?u64 { return json.as_u64(value); }

fn decode_semantic(result: json.Json) -> []Highlight {
    var out: []Highlight = [];
    var data_opt = json.get(result, "data");
    match (data_opt) {
        none { return out; }
        some(data_json) {
            var arr_opt = json.as_array(data_json);
            match (arr_opt) {
                none { return out; }
                some(values) {
                    var line: u64 = 0; var start: u64 = 0; var i: u64 = 0;
                    while (i + 4 < len(values)) {
                        var dl: u64 = 0; var ds: u64 = 0; var length: u64 = 0; var token_type: u64 = 0;
                        var a = json_number(values[i]); match (a) { none { return out; } some(v) { dl = v; } }
                        var b = json_number(values[i + 1]); match (b) { none { return out; } some(v) { ds = v; } }
                        var c = json_number(values[i + 2]); match (c) { none { return out; } some(v) { length = v; } }
                        var d = json_number(values[i + 3]); match (d) { none { return out; } some(v) { token_type = v; } }
                        if (dl == 0) { start += ds; } else { line += dl; start = ds; }
                        push(out, Highlight { line: line, start: start, length: length, token_type: token_type });
                        i += 5;
                    }
                }
            }
        }
    }
    return out;
}

fn consume_diagnostics(editor: ref Editor) {
    var params_opt = client.take_notification(editor.lsp, "textDocument/publishDiagnostics");
    match (params_opt) {
        none { }
        some(params) {
            var items_opt = json.get(params, "diagnostics");
            match (items_opt) {
                none { }
                some(items_json) {
                    var arr_opt = json.as_array(items_json);
                    match (arr_opt) {
                        none { }
                        some(items) {
                            arrays.clear(editor.diagnostics); editor.diagnostic_count = len(items);
                            for (item in items) {
                                var line: u64 = 0; var message: []u8 = "diagnostic";
                                var range_opt = json.get(item, "range"); match (range_opt) { none { } some(range) {
                                    var start_opt = json.get(range, "start"); match (start_opt) { none { } some(pos) { var lo = json.get_u64(pos, "line"); match (lo) { none { } some(v) { line = v; } } } }
                                } }
                                var message_opt = json.get_string(item, "message"); match (message_opt) { none { } some(v) { message = v; } }
                                push(editor.diagnostics, Diagnostic { line: line, message: bytes.clone(message) });
                            }
                        }
                    }
                }
            }
        }
    }
}

fn poll_lsp(editor: ref Editor) {
    if (!editor.lsp_active) { return; }
    if (!client.is_alive(editor.lsp)) { editor.lsp_active = false; editor.semantic_request = 0; set_status(editor, "LSP offline · editing continues"); return; }
    client.poll(editor.lsp, 0);
    if (!client.is_alive(editor.lsp)) { editor.lsp_active = false; editor.semantic_request = 0; set_status(editor, "LSP offline · editing continues"); return; }
    consume_diagnostics(editor);
    if (editor.semantic_request != 0) {
        var result_opt = client.take_response(editor.lsp, editor.semantic_request);
        match (result_opt) {
            none { }
            some(result) {
                if (editor.semantic_request_revision == editor.revision) {
                    editor.highlights = decode_semantic(result);
                    editor.semantic_start = editor.semantic_request_start;
                    editor.semantic_end = editor.semantic_request_end;
                }
                editor.semantic_request = 0;
            }
        }
    }
}

fn sync_lsp(editor: ref Editor) {
    if (!editor.lsp_active || !editor.lsp_dirty) { return; }
    if (len(editor.pending_lsp) == 0) { editor.lsp_dirty = false; return; }
    editor.version += 1;
    client.did_change(editor.lsp, editor.uri, editor.pending_lsp, editor.version);
    if (!client.is_alive(editor.lsp)) { editor.lsp_active = false; editor.semantic_request = 0; set_status(editor, "LSP offline · editing continues"); }
    arrays.clear(editor.pending_lsp);
    editor.lsp_dirty = false;
    editor.semantic_start = 0;
    editor.semantic_end = 0;
}

fn request_visible_semantic(editor: ref Editor) {
    if (!editor.lsp_active || editor.lsp_dirty || editor.semantic_request != 0) { return; }
    var rows = term.rows(); var visible: u64 = 1; if (rows > 1) { visible = rows - 1; }
    var start = editor.top_line;
    var end = start + visible + 8;
    if (end > len(editor.lines)) { end = len(editor.lines); }
    if (editor.semantic_end > editor.semantic_start && start >= editor.semantic_start && end <= editor.semantic_end) { return; }
    var margin: u64 = 32;
    if (start > margin) { start -= margin; } else { start = 0; }
    end += margin; if (end > len(editor.lines)) { end = len(editor.lines); }
    editor.semantic_request_start = start;
    editor.semantic_request_end = end;
    editor.semantic_request_revision = editor.revision;
    editor.semantic_request = client.semantic_range_async(editor.lsp, editor.uri, start, end);
}

fn explicit_lsp_ready(editor: ref Editor) -> bool {
    if (!editor.lsp_active) { set_status(editor, "LSP disabled for large file"); return false; }
    if (editor.lsp_dirty) { sync_lsp(editor); }
    return true;
}

fn parse_position(value: json.Json) -> ?lsp.Position {
    var line_opt = json.get_u64(value, "line"); var char_opt = json.get_u64(value, "character");
    var line: u64 = 0; var character: u64 = 0;
    match (line_opt) { none { return none; } some(v) { line = v; } }
    match (char_opt) { none { return none; } some(v) { character = v; } }
    return some(lsp.Position { line: line, character: character });
}

fn goto_definition(editor: ref Editor) {
    if (!explicit_lsp_ready(editor)) { return; }
    var result_opt = client.definition(editor.lsp, editor.uri, position_from_offset(editor, editor.cursor));
    match (result_opt) {
        none { set_status(editor, "definition request failed"); }
        some(result) {
            var range_opt = json.get(result, "range");
            match (range_opt) {
                none { set_status(editor, "no definition"); }
                some(range_json) {
                    var start_opt = json.get(range_json, "start");
                    match (start_opt) {
                        none { set_status(editor, "bad definition response"); }
                        some(start_json) {
                            var p_opt = parse_position(start_json);
                            match (p_opt) { none { set_status(editor, "bad definition position"); } some(p) { editor.cursor = offset_from_position(editor, p); set_status(editor, "definition"); } }
                        }
                    }
                }
            }
        }
    }
}

fn show_hover(editor: ref Editor) {
    if (!explicit_lsp_ready(editor)) { return; }
    var result_opt = client.hover(editor.lsp, editor.uri, position_from_offset(editor, editor.cursor));
    match (result_opt) {
        none { set_status(editor, "hover failed"); }
        some(result) {
            var contents_opt = json.get(result, "contents");
            match (contents_opt) {
                none { set_status(editor, "no hover"); }
                some(contents) {
                    var value_opt = json.get_string(contents, "value");
                    match (value_opt) { none { set_status(editor, "no hover"); } some(value) { set_status(editor, value); } }
                }
            }
        }
    }
}

fn completion_prefix_start(editor: ref Editor) -> u64 {
    var p = editor.cursor;
    while (p > 0) {
        var q = previous_char(editor.text, p);
        if (!is_word(editor.text[q])) { break; }
        p = q;
    }
    return p;
}

fn show_completion(editor: ref Editor) {
    if (!explicit_lsp_ready(editor)) { return; }
    var result_opt = client.completion(editor.lsp, editor.uri, position_from_offset(editor, editor.cursor));
    match (result_opt) {
        none { set_status(editor, "completion failed"); }
        some(result) {
            var arr_opt = json.as_array(result);
            match (arr_opt) {
                none { set_status(editor, "no completions"); }
                some(items) {
                    var labels: [][]u8 = [];
                    var out: []u8 = "completion · "; var limit = len(items); if (limit > 7) { limit = 7; }
                    for (var i: u64 = 0; i < limit; i += 1) {
                        var label_opt = json.get_string(items[i], "label");
                        match (label_opt) { none { } some(label) {
                            push(labels, bytes.clone(label));
                            strconv.append_u64(out, len(labels)); bytes.append(out, ":"); bytes.append(out, label); bytes.append(out, "  ");
                        } }
                    }
                    if (len(labels) == 0) { set_status(editor, "no completions"); return; }
                    if (!(editor.mode is Mode.insert)) { set_status(editor, out); return; }
                    bytes.append(out, "· choose 1-"); strconv.append_u64(out, len(labels)); bytes.append(out, " · Esc cancel"); set_status(editor, out); render(editor);
                    var choice = term.read_key(); match (choice) { none { } some(key) {
                        if (len(key) == 1 && key[0] >= '1' && key[0] <= '7') {
                            var index = (key[0] - '1') as u64;
                            if (index < len(labels)) {
                                var start = completion_prefix_start(editor);
                                edit(editor, start, editor.cursor, labels[index]); editor.cursor = start + len(labels[index]); set_status(editor, "");
                            }
                        }
                    } }
                }
            }
        }
    }
}

fn format_document(editor: ref Editor) {
    if (!explicit_lsp_ready(editor)) { return; }
    var result_opt = client.formatting(editor.lsp, editor.uri);
    match (result_opt) {
        none { set_status(editor, "format failed"); }
        some(result) {
            var arr_opt = json.as_array(result);
            match (arr_opt) {
                none { set_status(editor, "format response invalid"); }
                some(edits) {
                    if (len(edits) == 0) { set_status(editor, "no format changes"); return; }
                    var text_opt = json.get_string(edits[0], "newText");
                    match (text_opt) {
                        none { set_status(editor, "format response missing text"); }
                        some(text) {
                            begin_change(editor); edit(editor, 0, len(editor.text), text); commit_change(editor);
                            if (editor.cursor > len(editor.text)) { editor.cursor = len(editor.text); }
                            set_status(editor, "formatted");
                        }
                    }
                }
            }
        }
    }
}

fn append_cursor(out: []u8, row: u64, col: u64) {
    bytes.append(out, "\x1b["); strconv.append_u64(out, row); push(out, ';'); strconv.append_u64(out, col); push(out, 'H');
}

fn append_spaces(out: []u8, count: u64) { for (var i: u64 = 0; i < count; i += 1) { push(out, ' '); } }

fn diagnostic_on_line(editor: ref Editor, line: u64) -> bool {
    for (d in editor.diagnostics) { if (d.line == line) { return true; } }
    return false;
}

fn diagnostic_message(editor: ref Editor, line: u64) -> ?[]u8 {
    for (d in editor.diagnostics) { if (d.line == line) { return some(d.message); } }
    return none;
}

fn goto_diagnostic(editor: ref Editor, forward: bool) {
    if (len(editor.diagnostics) == 0) { set_status(editor, "no diagnostics"); return; }
    var here = line_of_offset(editor, editor.cursor); var found: ?u64 = none;
    if (forward) {
        for (d in editor.diagnostics) { if (d.line > here) { found = some(d.line); break; } }
        match (found) { none { found = some(editor.diagnostics[0].line); } some(_) { } }
    } else {
        var i = len(editor.diagnostics); while (i > 0) { i -= 1; if (editor.diagnostics[i].line < here) { found = some(editor.diagnostics[i].line); break; } }
        match (found) { none { found = some(editor.diagnostics[len(editor.diagnostics)-1].line); } some(_) { } }
    }
    match (found) { none { } some(line) { editor.cursor = first_nonblank(editor, line); reset_goal(editor); set_status(editor, ""); } }
}

fn append_gutter(out: []u8, editor: ref Editor, line: u64, current: u64) {
    if (editor.theme is Theme.paper) { bytes.append(out, "\x1b[38;5;245m"); }
    else { bytes.append(out, "\x1b[38;5;240m"); }
    if (diagnostic_on_line(editor, line)) { if (editor.theme is Theme.mono) { bytes.append(out, "!"); } else { bytes.append(out, "\x1b[38;5;203m!\x1b[0m"); } } else { push(out, ' '); }
    var shown = line + 1;
    if (editor.relative_numbers && line != current) { if (line > current) { shown = line - current; } else { shown = current - line; } }
    var num: []u8 = []; strconv.append_u64(num, shown);
    var spaces: u64 = 4; if (len(num) < spaces) { spaces -= len(num); } else { spaces = 0; }
    append_spaces(out, spaces);
    if (line == current && !(editor.theme is Theme.mono)) { bytes.append(out, "\x1b[1;38;5;81m"); }
    bytes.append(out, num);
    if (editor.theme is Theme.mono) { bytes.append(out, " | \x1b[0m"); } else { bytes.append(out, " \x1b[38;5;238m│\x1b[0m "); }
}


fn append_piece(out: []u8, editor: ref Editor, data: []u8, start: u64, end: u64, token_type: u64, selected: bool, col: u64) -> u64 {
    if (end <= start) { return col; }
    if (token_type != 0) { bytes.append(out, syntax_color(editor, token_type)); }
    if (selected) {
        if (editor.theme is Theme.mono) { bytes.append(out, "\x1b[7m"); }
        else if (editor.theme is Theme.paper) { bytes.append(out, "\x1b[48;5;252m"); }
        else { bytes.append(out, "\x1b[48;5;238m"); }
    }
    col = append_display_text(out, data, start, end, col, editor.tab_width);
    if (token_type != 0 || selected) { bytes.append(out, "\x1b[0m"); }
    return col;
}

fn append_piece_with_selection(out: []u8, editor: ref Editor, line: []u8, start: u64, end: u64, token_type: u64, sel: ?Range, col: u64) -> u64 {
    match (sel) {
        none { return append_piece(out, editor, line, start, end, token_type, false, col); }
        some(r) {
            if (end <= r.start || start >= r.end) { return append_piece(out, editor, line, start, end, token_type, false, col); }
            if (start < r.start) { col = append_piece(out, editor, line, start, r.start, token_type, false, col); start = r.start; }
            var selected_end = end; if (selected_end > r.end) { selected_end = r.end; }
            col = append_piece(out, editor, line, start, selected_end, token_type, true, col);
            if (selected_end < end) { col = append_piece(out, editor, line, selected_end, end, token_type, false, col); }
            return col;
        }
    }
}

fn local_selection(editor: ref Editor, line_no: u64) -> ?Range {
    var global = visual_range(editor);
    match (global) {
        none { return none; }
        some(r) {
            var start = line_start(editor, line_no); var end = line_end(editor, line_no);
            if (r.end <= start || r.start >= end) { return none; }
            var a = r.start; if (a < start) { a = start; }
            var b = r.end; if (b > end) { b = end; }
            return some(Range { start: a - start, end: b - start });
        }
    }
}

fn append_render_line(out: []u8, editor: ref Editor, line_no: u64, line: []u8, hi: u64) -> u64 {
    var view_start = byte_at_display_col(line, editor.hscroll, editor.tab_width);
    var byte_pos = view_start; var col = display_col(line, view_start, editor.tab_width);
    var sel = local_selection(editor, line_no);
    while (hi < len(editor.highlights) && editor.highlights[hi].line < line_no) { hi += 1; }
    var i = hi;
    while (i < len(editor.highlights) && editor.highlights[i].line == line_no) {
        var token = editor.highlights[i];
        var start_byte = utf8.utf16_to_byte(line, token.start);
        var end_byte = utf8.utf16_to_byte(line, token.start + token.length);
        if (end_byte > view_start && start_byte >= byte_pos && start_byte <= len(line)) {
            col = append_piece_with_selection(out, editor, line, byte_pos, start_byte, 0, sel, col);
            col = append_piece_with_selection(out, editor, line, start_byte, end_byte, token.token_type, sel, col);
            byte_pos = end_byte;
        }
        i += 1;
    }
    if (byte_pos < len(line)) { col = append_piece_with_selection(out, editor, line, byte_pos, len(line), 0, sel, col); }
    return i;
}

fn ensure_view(editor: ref Editor, rows: u64, cols: u64) {
    var pos = position_from_offset(editor, editor.cursor);
    var current_line = line_bytes(editor, pos.line); var byte_in_line = editor.cursor - line_start(editor, pos.line); var cell = display_col(current_line, byte_in_line, editor.tab_width);
    var text_rows: u64 = 1; if (rows > 2) { text_rows = rows - 2; }
    var margin = editor.scrolloff; if (margin * 2 >= text_rows) { margin = text_rows / 2; }
    if (pos.line < editor.top_line + margin) {
        if (pos.line > margin) { editor.top_line = pos.line - margin; } else { editor.top_line = 0; }
    }
    if (pos.line + margin >= editor.top_line + text_rows) {
        editor.top_line = pos.line + margin + 1 - text_rows;
    }
    var avail: u64 = 1;
    if (cols > GUTTER + 1) { avail = cols - GUTTER - 1; }
    if (cell < editor.hscroll) { editor.hscroll = cell; }
    else if (cell >= editor.hscroll + avail) { editor.hscroll = cell - avail + 1; }
}

fn render(editor: ref Editor) {
    var rows = term.rows(); var cols = term.cols(); ensure_view(editor, rows, cols);
    var out: []u8 = "\x1b[?2026h\x1b[?25l\x1b[H";
    var screen_lines: u64 = 0; if (rows > 2) { screen_lines = rows - 2; }
    var line_no = editor.top_line; var hi: u64 = 0;
    var current = line_of_offset(editor, editor.cursor);
    while (hi < len(editor.highlights) && editor.highlights[hi].line < line_no) { hi += 1; }
    for (var row: u64 = 0; row < screen_lines; row += 1) {
        bytes.append(out, "\x1b[0m"); append_gutter(out, editor, line_no, current);
        if (line_no < len(editor.lines)) { hi = append_render_line(out, editor, line_no, line_bytes(editor, line_no), hi); }
        else { bytes.append(out, "\x1b[38;5;238m~"); }
        bytes.append(out, "\x1b[0m\x1b[0K");
        if (row + 1 < rows) { bytes.append(out, "\r\n"); }
        line_no += 1;
    }

    var left: []u8 = [];
    if (editor.mode is Mode.insert) {
        if (editor.theme is Theme.mono) { bytes.append(left, "\x1b[7m INSERT \x1b[0m "); }
        else { bytes.append(left, "\x1b[1;48;5;29;38;5;231m INSERT \x1b[0m "); }
    } else if ((editor.mode is Mode.visual) || (editor.mode is Mode.visual_line)) {
        if (editor.theme is Theme.mono) { bytes.append(left, "\x1b[7m VISUAL \x1b[0m "); }
        else { bytes.append(left, "\x1b[1;48;5;96;38;5;231m VISUAL \x1b[0m "); }
    } else {
        if (editor.theme is Theme.mono) { bytes.append(left, "\x1b[7m NORMAL \x1b[0m "); }
        else { bytes.append(left, "\x1b[1;48;5;24;38;5;231m NORMAL \x1b[0m "); }
    }
    bytes.append(left, editor.path); if (dirty(editor)) { bytes.append(left, "  ●"); }
    var right: []u8 = [];
    if (editor.lsp_active) { if (editor.lsp_dirty || editor.semantic_request != 0) { bytes.append(right, "lsp…  "); } else { bytes.append(right, "lsp  "); } }
    if (editor.diagnostic_count > 0) { bytes.append(right, "!"); strconv.append_u64(right, editor.diagnostic_count); bytes.append(right, "  "); }
    var p = position_from_offset(editor, editor.cursor); strconv.append_u64(right, p.line + 1); push(right, ':'); strconv.append_u64(right, p.character + 1);

    if (editor.theme is Theme.paper) { bytes.append(out, "\x1b[48;5;254;38;5;238m"); }
    else if (editor.theme is Theme.mono) { bytes.append(out, "\x1b[7m"); }
    else { bytes.append(out, "\x1b[48;5;236;38;5;252m"); }
    bytes.append(out, left);
    var plain_left = len(editor.path) + 11; if (dirty(editor)) { plain_left += 3; }
    var plain_right = len(right);
    var pad: u64 = 1; if (cols > plain_left + plain_right) { pad = cols - plain_left - plain_right; }
    append_spaces(out, pad); bytes.append(out, right); bytes.append(out, "\x1b[0m\x1b[0K\r\n");

    bytes.append(out, "\x1b[2m");
    if (len(editor.status) > 0) { bytes.append(out, editor.status); }
    else {
        var diag = diagnostic_message(editor, p.line);
        match (diag) { some(message) { bytes.append(out, "! "); bytes.append(out, message); } none { bytes.append(out, "lace · quiet, modal, LSP-native · :help"); } }
    }
    bytes.append(out, "\x1b[0m\x1b[0K");

    var screen_row = p.line - editor.top_line + 1;
    var screen_col = GUTTER + 1;
    var cursor_line = line_bytes(editor, p.line); var cursor_byte = editor.cursor - line_start(editor, p.line); var cursor_cell = display_col(cursor_line, cursor_byte, editor.tab_width);
    if (cursor_cell >= editor.hscroll) { screen_col += cursor_cell - editor.hscroll; }
    if (screen_col > cols) { screen_col = cols; }
    append_cursor(out, screen_row, screen_col);
    bytes.append(out, "\x1b[?25h\x1b[?2026l");
    term.write(out);
}

fn prompt(editor: ref Editor, prefix: []u8) -> ?[]u8 {
    var input: []u8 = [];
    while (true) {
        render(editor);
        var out: []u8 = []; append_cursor(out, term.rows(), 1); bytes.append(out, "\x1b[0m\x1b[0K"); bytes.append(out, prefix); bytes.append(out, input); term.write(out);
        var key_opt = term.read_key();
        match (key_opt) {
            none { return none; }
            some(key) {
                if (bytes.equal(key, "\x1b") || bytes.equal(key, "\x03")) { return none; }
                if (bytes.equal(key, "\r") || bytes.equal(key, "\n")) { return some(input); }
                if (bytes.equal(key, "\x7f") || bytes.equal(key, "\x08")) {
                    if (len(input) > 0) { splice(input, previous_char(input, len(input)), len(input), []); }
                } else if (len(key) == 1 && key[0] >= 0x20) { bytes.append(input, key); }
            }
        }
    }
}

fn search_forward(editor: ref Editor, needle: []u8, from: u64) -> ?u64 {
    var found = bytes.find(editor.text, needle, from);
    match (found) { some(_) { return found; } none { if (from > 0) { return bytes.find(editor.text, needle, 0); } return none; } }
}

fn search_backward(editor: ref Editor, needle: []u8, from: u64) -> ?u64 {
    if (len(needle) == 0) { return none; }
    var best: ?u64 = none; var pos: u64 = 0;
    while (pos < from) {
        var f = bytes.find(editor.text, needle, pos);
        match (f) {
            none { break; }
            some(v) { if (v >= from) { break; } best = some(v); pos = v + 1; }
        }
    }
    match (best) { some(_) { return best; } none { }
    }
    pos = from; best = none;
    while (pos < len(editor.text)) {
        var f = bytes.find(editor.text, needle, pos);
        match (f) { none { break; } some(v) { best = some(v); pos = v + 1; } }
    }
    return best;
}

fn word_under_cursor(editor: ref Editor) -> ?[]u8 {
    if (editor.cursor >= len(editor.text) || !is_word(editor.text[editor.cursor])) { return none; }
    var start = editor.cursor; var end = next_char(editor.text, editor.cursor);
    while (start > 0) { var p = previous_char(editor.text, start); if (!is_word(editor.text[p])) { break; } start = p; }
    while (end < len(editor.text) && is_word(editor.text[end])) { end = next_char(editor.text, end); }
    return some(bytes.slice(editor.text, start, end));
}

fn search_word(editor: ref Editor, forward: bool) {
    var w = word_under_cursor(editor); match (w) { none { set_status(editor, "no word under cursor"); } some(needle) {
        editor.last_search = bytes.clone(needle); editor.last_search_forward = forward;
        var found: ?u64 = none;
        if (forward) { found = search_forward(editor, needle, next_char(editor.text, editor.cursor)); }
        else { found = search_backward(editor, needle, editor.cursor); }
        match (found) { none { set_status(editor, "pattern not found"); } some(v) { editor.cursor = v; reset_goal(editor); } }
    } }
}

fn run_search(editor: ref Editor, forward: bool) {
    var prefix: []u8 = "?"; if (forward) { prefix = "/"; }
    var p = prompt(editor, prefix);
    match (p) {
        none { }
        some(needle) {
            if (len(needle) == 0) { return; }
            editor.last_search = bytes.clone(needle); editor.last_search_forward = forward;
            var found: ?u64 = none;
            if (forward) { found = search_forward(editor, needle, next_char(editor.text, editor.cursor)); } else { found = search_backward(editor, needle, editor.cursor); }
            match (found) { none { set_status(editor, "pattern not found"); } some(v) { editor.cursor = v; reset_goal(editor); } }
        }
    }
}

fn repeat_search(editor: ref Editor, same_direction: bool) {
    if (len(editor.last_search) == 0) { return; }
    var forward = editor.last_search_forward;
    if (!same_direction) { forward = !forward; }
    var found: ?u64 = none;
    if (forward) { found = search_forward(editor, editor.last_search, next_char(editor.text, editor.cursor)); } else { found = search_backward(editor, editor.last_search, editor.cursor); }
    match (found) { none { set_status(editor, "pattern not found"); } some(v) { editor.cursor = v; } }
}

fn matching_bracket(editor: ref Editor) -> ?u64 {
    if (editor.cursor >= len(editor.text)) { return none; }
    var ch = editor.text[editor.cursor]; var open: u8 = 0; var close: u8 = 0; var forward = true;
    if (ch == '(') { open = '('; close = ')'; }
    else if (ch == '[') { open = '['; close = ']'; }
    else if (ch == '{') { open = '{'; close = '}'; }
    else if (ch == ')') { open = '('; close = ')'; forward = false; }
    else if (ch == ']') { open = '['; close = ']'; forward = false; }
    else if (ch == '}') { open = '{'; close = '}'; forward = false; }
    else { return none; }
    var depth: u64 = 0;
    if (forward) {
        var p = editor.cursor;
        while (p < len(editor.text)) { if (editor.text[p] == open) { depth += 1; } else if (editor.text[p] == close) { depth -= 1; if (depth == 0) { return some(p); } } p += 1; }
    } else {
        var p = editor.cursor + 1;
        while (p > 0) { p -= 1; if (editor.text[p] == close) { depth += 1; } else if (editor.text[p] == open) { depth -= 1; if (depth == 0) { return some(p); } } }
    }
    return none;
}

fn find_char(editor: ref Editor, target: []u8, forward: bool, till: bool, count: u64) -> ?u64 {
    if (len(target) == 0) { return none; }
    var line = line_of_offset(editor, editor.cursor); var start = line_start(editor, line); var end = line_end(editor, line); var p = editor.cursor;
    for (var hit: u64 = 0; hit < count; hit += 1) {
        if (forward) {
            p = next_char(editor.text, p); var found = false;
            while (p < end) { if (editor.text[p] == target[0]) { found = true; break; } p = next_char(editor.text, p); }
            if (!found) { return none; }
        } else {
            if (p <= start) { return none; } p = previous_char(editor.text, p); var found = false;
            while (true) { if (editor.text[p] == target[0]) { found = true; break; } if (p <= start) { break; } p = previous_char(editor.text, p); }
            if (!found) { return none; }
        }
    }
    if (till) { if (forward) { p = previous_char(editor.text, p); } else { p = next_char(editor.text, p); } }
    return some(p);
}

fn line_range(editor: ref Editor, line: u64, count: u64) -> Edit {
    var start = line_start(editor, line); var last = line + count;
    var end = len(editor.text); if (last < len(editor.lines)) { end = line_start(editor, last); }
    return Edit { start: start, removed: [], inserted: bytes.slice(editor.text, start, end) };
}

fn operator_motion(editor: ref Editor, key: []u8, count: u64) -> ?Edit {
    var start = editor.cursor; var target = start; var inclusive = false;
    if (bytes.equal(key, "w")) { for (var i: u64 = 0; i < count; i += 1) { target = word_next(editor, target); } }
    else if (bytes.equal(key, "e")) { for (var i: u64 = 0; i < count; i += 1) { target = word_end(editor, target); } inclusive = true; }
    else if (bytes.equal(key, "b")) { for (var i: u64 = 0; i < count; i += 1) { target = word_prev(editor, target); } }
    else if (bytes.equal(key, "$")) { target = line_end(editor, line_of_offset(editor, start)); }
    else if (bytes.equal(key, "0")) { target = line_start(editor, line_of_offset(editor, start)); }
    else if (bytes.equal(key, "h")) { target = start; for (var i: u64 = 0; i < count; i += 1) { target = previous_char(editor.text, target); } }
    else if (bytes.equal(key, "l")) { target = start; for (var i: u64 = 0; i < count; i += 1) { target = next_char(editor.text, target); } }
    else if (bytes.equal(key, "G")) { return some(line_range(editor, line_of_offset(editor, start), len(editor.lines))); }
    else { return none; }
    var a = start; var b = target;
    if (a > b) { var t = a; a = b; b = t; }
    if (inclusive && b < len(editor.text)) { b = next_char(editor.text, b); }
    return some(Edit { start: a, removed: [], inserted: bytes.slice(editor.text, a, b) });
}

fn handle_operator(editor: ref Editor, op: []u8, count: u64) {
    var key_opt = term.read_key(); match (key_opt) { none { return; } some(key) {
        if (bytes.equal(key, op)) {
            var r = line_range(editor, line_of_offset(editor, editor.cursor), count);
            if (bytes.equal(op, "y")) { yank_range(editor, r.start, r.start + len(r.inserted), true); }
            else {
                if (bytes.equal(op, "c")) {
                    var end = r.start + len(r.inserted); if (end > r.start && editor.text[end - 1] == '\n') { end -= 1; }
                    yank_range(editor, r.start, end, false); delete_range(editor, r.start, end); begin_change(editor); editor.mode = Mode.insert;
                } else { yank_range(editor, r.start, r.start + len(r.inserted), true); delete_range(editor, r.start, r.start + len(r.inserted)); }
            }
            return;
        }
        var range_opt = operator_motion(editor, key, count);
        match (range_opt) {
            none { set_status(editor, "unsupported operator motion"); }
            some(r) {
                var end = r.start + len(r.inserted);
                if (bytes.equal(op, "y")) { yank_range(editor, r.start, end, false); }
                else {
                    yank_range(editor, r.start, end, false); delete_range(editor, r.start, end);
                    if (bytes.equal(op, "c")) { begin_change(editor); editor.mode = Mode.insert; }
                }
            }
        }
    } }
}

fn paste(editor: ref Editor, after: bool) {
    if (len(editor.yank) == 0) { return; }
    var pos = editor.cursor;
    if (editor.yank_linewise) {
        var line = line_of_offset(editor, editor.cursor);
        if (after) { if (line + 1 < len(editor.lines)) { pos = line_start(editor, line + 1); } else { pos = len(editor.text); } }
        else { pos = line_start(editor, line); }
    } else if (after && pos < len(editor.text)) { pos = next_char(editor.text, pos); }
    begin_change(editor); edit(editor, pos, pos, editor.yank); commit_change(editor); editor.cursor = pos;
}

fn open_line(editor: ref Editor, below: bool) {
    var line = line_of_offset(editor, editor.cursor); var indent_end = first_nonblank(editor, line);
    var indent = bytes.slice(editor.text, line_start(editor, line), indent_end);
    var pos = line_start(editor, line);
    var value: []u8 = [];
    if (below) { pos = line_end(editor, line); bytes.append(value, "\n"); bytes.append(value, indent); }
    else { bytes.append(value, indent); bytes.append(value, "\n"); }
    begin_change(editor); edit(editor, pos, pos, value);
    if (below) { editor.cursor = pos + len(value); } else { editor.cursor = pos + len(indent); }
    editor.mode = Mode.insert;
}

fn join_line(editor: ref Editor) {
    var line = line_of_offset(editor, editor.cursor); if (line + 1 >= len(editor.lines)) { return; }
    var end = line_end(editor, line); var next = line_start(editor, line + 1); var trim = first_nonblank(editor, line + 1);
    begin_change(editor); edit(editor, end, trim, " "); commit_change(editor); editor.cursor = end;
}

fn replace_char(editor: ref Editor) {
    var k = term.read_key(); match (k) { none { } some(key) { if (len(key) == 0 || editor.cursor >= len(editor.text)) { return; } begin_change(editor); edit(editor, editor.cursor, next_char(editor.text, editor.cursor), key); commit_change(editor); } }
}

fn normal_motion(editor: ref Editor, key: []u8, count: u64, count_given: bool) -> bool {
    if (bytes.equal(key, "h") || bytes.equal(key, "\x1b[D")) { normal_left(editor, count); return true; }
    if (bytes.equal(key, "l") || bytes.equal(key, "\x1b[C")) { normal_right(editor, count); return true; }
    if (bytes.equal(key, "j") || bytes.equal(key, "\x1b[B")) { move_vertical(editor, true, count); return true; }
    if (bytes.equal(key, "k") || bytes.equal(key, "\x1b[A")) { move_vertical(editor, false, count); return true; }
    if (bytes.equal(key, "0")) { editor.cursor = line_start(editor, line_of_offset(editor, editor.cursor)); reset_goal(editor); return true; }
    if (bytes.equal(key, "^")) { editor.cursor = first_nonblank(editor, line_of_offset(editor, editor.cursor)); reset_goal(editor); return true; }
    if (bytes.equal(key, "$")) { editor.cursor = line_end(editor, line_of_offset(editor, editor.cursor)); reset_goal(editor); return true; }
    if (bytes.equal(key, "w")) { for (var i: u64 = 0; i < count; i += 1) { editor.cursor = word_next(editor, editor.cursor); } reset_goal(editor); return true; }
    if (bytes.equal(key, "b")) { for (var i: u64 = 0; i < count; i += 1) { editor.cursor = word_prev(editor, editor.cursor); } reset_goal(editor); return true; }
    if (bytes.equal(key, "e")) { for (var i: u64 = 0; i < count; i += 1) { editor.cursor = word_end(editor, editor.cursor); if (i + 1 < count) { editor.cursor = word_next(editor, editor.cursor); } } reset_goal(editor); return true; }
    if (bytes.equal(key, "G")) {
        var line = len(editor.lines) - 1; if (count_given) { line = 0; if (count > 0) { line = count - 1; } if (line >= len(editor.lines)) { line = len(editor.lines) - 1; } }
        editor.cursor = first_nonblank(editor, line); reset_goal(editor); return true;
    }
    if (bytes.equal(key, "%")) { var p = matching_bracket(editor); match (p) { none { } some(v) { editor.cursor = v; } } return true; }
    if (bytes.equal(key, "\x04")) { var half: u64 = 1; if (term.rows() > 4) { half = term.rows() / 2; } move_vertical(editor, true, half * count); return true; }
    if (bytes.equal(key, "\x15")) { var half: u64 = 1; if (term.rows() > 4) { half = term.rows() / 2; } move_vertical(editor, false, half * count); return true; }
    if (bytes.equal(key, "\x06") || bytes.equal(key, "\x1b[6~")) { var page: u64 = 1; if (term.rows() > 3) { page = term.rows() - 3; } move_vertical(editor, true, page * count); return true; }
    if (bytes.equal(key, "\x02") || bytes.equal(key, "\x1b[5~")) { var page: u64 = 1; if (term.rows() > 3) { page = term.rows() - 3; } move_vertical(editor, false, page * count); return true; }
    if (bytes.equal(key, "\x1b[H") || bytes.equal(key, "\x1b[1~")) { editor.cursor = line_start(editor, line_of_offset(editor, editor.cursor)); reset_goal(editor); return true; }
    if (bytes.equal(key, "\x1b[F") || bytes.equal(key, "\x1b[4~")) { editor.cursor = line_end(editor, line_of_offset(editor, editor.cursor)); reset_goal(editor); return true; }
    if (bytes.equal(key, "H") || bytes.equal(key, "M") || bytes.equal(key, "L")) {
        var target = editor.top_line; var visible: u64 = 1; if (term.rows() > 2) { visible = term.rows() - 2; }
        if (bytes.equal(key, "M")) { target += visible / 2; }
        else if (bytes.equal(key, "L")) { target += visible - 1; }
        if (target >= len(editor.lines)) { target = len(editor.lines) - 1; }
        editor.cursor = first_nonblank(editor, target); reset_goal(editor); return true;
    }
    return false;
}

fn read_count(first: []u8) -> Edit {
    var count: u64 = 0; var key = bytes.clone(first); var given = false;
    while (len(key) == 1 && key[0] >= '1' && key[0] <= '9') {
        given = true; count = count * 10 + ((key[0] - '0') as u64);
        var next = term.read_key(); match (next) { none { return Edit { start: count, removed: [], inserted: [] }; } some(v) { key = v; } }
    }
    if (!given) { count = 1; }
    var marker: []u8 = []; if (given) { marker = "1"; }
    return Edit { start: count, removed: key, inserted: marker };
}

fn handle_colon(editor: ref Editor) -> bool {
    var cmd_opt = prompt(editor, ":");
    match (cmd_opt) {
        none { return true; }
        some(cmd) {
            if (len(cmd) > 0 && cmd[0] == '!') { shell_escape(editor, bytes.slice(cmd, 1, len(cmd))); return true; }
            if (bytes.equal(cmd, "w")) { save(editor); return true; }
            if (bytes.equal(cmd, "q")) { if (dirty(editor)) { set_status(editor, "unsaved changes · use :q!"); return true; } return false; }
            if (bytes.equal(cmd, "q!")) { return false; }
            if (bytes.equal(cmd, "wq") || bytes.equal(cmd, "x")) { save(editor); return dirty(editor); }
            if (bytes.equal(cmd, "format")) { format_document(editor); return true; }
            if (bytes.equal(cmd, "theme graphite")) { editor.theme = Theme.graphite; set_status(editor, "theme: graphite"); return true; }
            if (bytes.equal(cmd, "theme paper") || bytes.equal(cmd, "theme linen")) { editor.theme = Theme.paper; set_status(editor, "theme: linen"); return true; }
            if (bytes.equal(cmd, "theme mono")) { editor.theme = Theme.mono; set_status(editor, "theme: mono"); return true; }
            if (bytes.equal(cmd, "set relativenumber")) { editor.relative_numbers = true; return true; }
            if (bytes.equal(cmd, "set norelativenumber")) { editor.relative_numbers = false; return true; }
            if (bytes.equal(cmd, "version")) { set_status(editor, "Lace 0.8 · written in L · native VM"); return true; }
            if (bytes.equal(cmd, "help")) { show_help_screen(); set_status(editor, ""); return true; }
            if (bytes.equal(cmd, "theme")) { set_status(editor, "themes: graphite · linen · mono"); return true; }
            if (bytes.equal(cmd, "set")) { var st: []u8 = "relative_numbers="; if (editor.relative_numbers) { bytes.append(st, "true"); } else { bytes.append(st, "false"); } bytes.append(st, " · tab_width="); strconv.append_u64(st, editor.tab_width); bytes.append(st, " · scrolloff="); strconv.append_u64(st, editor.scrolloff); set_status(editor, st); return true; }
            if (bytes.starts_with(cmd, "set tabwidth=")) { var v = strconv.parse_u64(bytes.slice(cmd, 13, len(cmd))); match (v) { some(n) { if (n >= 1 && n <= 16) { editor.tab_width = n; set_status(editor, "tab width updated"); } else { set_status(editor, "tab width must be 1..16"); } } none { set_status(editor, "bad tab width"); } } return true; }
            if (bytes.starts_with(cmd, "set scrolloff=")) { var v = strconv.parse_u64(bytes.slice(cmd, 14, len(cmd))); match (v) { some(n) { if (n <= 20) { editor.scrolloff = n; set_status(editor, "scrolloff updated"); } else { set_status(editor, "scrolloff must be 0..20"); } } none { set_status(editor, "bad scrolloff"); } } return true; }
            set_status(editor, "unknown command · :help"); return true;
        }
    }
}

fn make_spaces(count: u64) -> []u8 {
    var out: []u8 = []; for (var i: u64 = 0; i < count; i += 1) { push(out, ' '); } return out;
}

fn insert_tab(editor: ref Editor) {
    var pos = position_from_offset(editor, editor.cursor);
    var width = editor.tab_width; if (width == 0) { width = 4; }
    var count = width - (pos.character % width); if (count == 0) { count = width; }
    insert_one(editor, make_spaces(count));
}

fn insert_newline(editor: ref Editor) {
    var line = line_of_offset(editor, editor.cursor);
    var start = line_start(editor, line); var first = first_nonblank(editor, line);
    var indent = bytes.slice(editor.text, start, first);
    var extra = false;
    var p = editor.cursor;
    while (p > start) {
        var q = previous_char(editor.text, p);
        if (editor.text[q] == ' ' || editor.text[q] == '\t') { p = q; continue; }
        if (editor.text[q] == '{' || editor.text[q] == '[' || editor.text[q] == '(') { extra = true; }
        break;
    }
    var value: []u8 = "\n"; bytes.append(value, indent);
    if (extra) { bytes.append(value, make_spaces(editor.tab_width)); }
    insert_one(editor, value);
}

fn insert_delete_word(editor: ref Editor) {
    if (editor.cursor == 0) { return; }
    var p = word_prev(editor, editor.cursor);
    if (p < editor.cursor) { edit(editor, p, editor.cursor, []); editor.cursor = p; }
}

fn insert_delete_line_prefix(editor: ref Editor) {
    var start = line_start(editor, line_of_offset(editor, editor.cursor));
    if (start < editor.cursor) { edit(editor, start, editor.cursor, []); editor.cursor = start; }
}

fn indent_lines(editor: ref Editor, first_line: u64, last_line: u64, add: bool) {
    if (first_line > last_line) { var t = first_line; first_line = last_line; last_line = t; }
    begin_change(editor);
    var line = first_line;
    while (line <= last_line && line < len(editor.lines)) {
        var start = line_start(editor, line);
        if (add) { edit(editor, start, start, make_spaces(editor.tab_width)); }
        else {
            var end = start; var removed: u64 = 0;
            while (end < len(editor.text) && removed < editor.tab_width && editor.text[end] == ' ') { end += 1; removed += 1; }
            if (end == start && end < len(editor.text) && editor.text[end] == '\t') { end += 1; }
            if (end > start) { edit(editor, start, end, []); }
        }
        line += 1;
    }
    commit_change(editor);
}

fn handle_visual(editor: ref Editor, first: []u8) -> bool {
    if (bytes.equal(first, "\x1b") || bytes.equal(first, "\x03")) { leave_visual(editor); return true; }
    var parsed = read_count(first); var count = parsed.start; var key = parsed.removed; var count_given = len(parsed.inserted) > 0;
    if (normal_motion(editor, key, count, count_given)) { return true; }
    if (bytes.equal(key, "v")) { leave_visual(editor); return true; }
    if (bytes.equal(key, "V")) { if (editor.mode is Mode.visual_line) { leave_visual(editor); } else { editor.mode = Mode.visual_line; } return true; }
    if (bytes.equal(key, "y") || bytes.equal(key, "d") || bytes.equal(key, "x") || bytes.equal(key, "c")) {
        var r_opt = visual_range(editor);
        match (r_opt) {
            none { leave_visual(editor); }
            some(r) {
                var linewise = editor.mode is Mode.visual_line;
                yank_range(editor, r.start, r.end, linewise);
                if (bytes.equal(key, "y")) { editor.cursor = r.start; leave_visual(editor); set_status(editor, "yanked selection"); }
                else {
                    delete_range(editor, r.start, r.end); editor.cursor = r.start; editor.mode = Mode.normal;
                    if (bytes.equal(key, "c")) { begin_change(editor); editor.mode = Mode.insert; }
                }
            }
        }
        return true;
    }
    if (bytes.equal(key, ">") || bytes.equal(key, "<")) {
        var r_opt = visual_range(editor); match (r_opt) { none { } some(r) {
            var first_line = line_of_offset(editor, r.start); var last_line = first_line;
            if (r.end > r.start) { last_line = line_of_offset(editor, r.end - 1); }
            indent_lines(editor, first_line, last_line, bytes.equal(key, ">")); editor.cursor = first_nonblank(editor, first_line); leave_visual(editor);
        } }
        return true;
    }
    return true;
}

fn handle_insert(editor: ref Editor, key: []u8) {
    if (bytes.equal(key, "\x1b") || bytes.equal(key, "\x03")) { commit_change(editor); editor.mode = Mode.normal; if (editor.cursor > line_start(editor, line_of_offset(editor, editor.cursor))) { editor.cursor = previous_char(editor.text, editor.cursor); } set_status(editor, ""); return; }
    if (bytes.equal(key, "\x7f") || bytes.equal(key, "\x08")) { backspace(editor); return; }
    if (bytes.equal(key, "\r") || bytes.equal(key, "\n")) { insert_newline(editor); return; }
    if (bytes.equal(key, "\x1b[D")) { normal_left(editor, 1); return; }
    if (bytes.equal(key, "\x1b[C")) { normal_right(editor, 1); return; }
    if (bytes.equal(key, "\x1b[A")) { move_vertical(editor, false, 1); return; }
    if (bytes.equal(key, "\x1b[B")) { move_vertical(editor, true, 1); return; }
    if (bytes.equal(key, "\x13")) { save(editor); return; }
    if (bytes.equal(key, "\x17")) { insert_delete_word(editor); return; }
    if (bytes.equal(key, "\x15")) { insert_delete_line_prefix(editor); return; }
    if (bytes.equal(key, "\t")) { insert_tab(editor); return; }
    if (bytes.equal(key, "\x00")) { show_completion(editor); return; }
    if (bytes.equal(key, "\x1b[H") || bytes.equal(key, "\x1b[1~")) { editor.cursor = line_start(editor, line_of_offset(editor, editor.cursor)); return; }
    if (bytes.equal(key, "\x1b[F") || bytes.equal(key, "\x1b[4~")) { editor.cursor = line_end(editor, line_of_offset(editor, editor.cursor)); return; }
    if (len(key) > 0 && key[0] >= 0x20) { insert_one(editor, key); }
}

fn handle_normal(editor: ref Editor, first: []u8) -> bool {
    if (bytes.equal(first, "\x03")) { set_status(editor, ""); return true; }
    var parsed = read_count(first); var count = parsed.start; var key = parsed.removed; var count_given = len(parsed.inserted) > 0;
    if (normal_motion(editor, key, count, count_given)) { return true; }
    if (bytes.equal(key, "g")) {
        var k = term.read_key(); match (k) { some(v) { if (bytes.equal(v, "g")) { var line: u64 = 0; if (count_given && count > 0) { line = count - 1; if (line >= len(editor.lines)) { line = len(editor.lines) - 1; } } editor.cursor = first_nonblank(editor, line); } else if (bytes.equal(v, "d")) { goto_definition(editor); } } none { } }
    } else if (bytes.equal(key, "v")) { editor.visual_anchor = editor.cursor; editor.mode = Mode.visual; set_status(editor, "visual selection"); }
    else if (bytes.equal(key, "V")) { editor.visual_anchor = editor.cursor; editor.mode = Mode.visual_line; set_status(editor, "visual line selection"); }
    else if (bytes.equal(key, ">") || bytes.equal(key, "<")) {
        var second = term.read_key(); match (second) { some(v) { if (bytes.equal(v, key)) { var line = line_of_offset(editor, editor.cursor); var last = line + count - 1; if (last >= len(editor.lines)) { last = len(editor.lines) - 1; } indent_lines(editor, line, last, bytes.equal(key, ">")); editor.cursor = first_nonblank(editor, line); } } none { } }
    }
    else if (bytes.equal(key, "i")) { begin_change(editor); editor.mode = Mode.insert; }
    else if (bytes.equal(key, "a")) { if (editor.cursor < line_end(editor, line_of_offset(editor, editor.cursor))) { editor.cursor = next_char(editor.text, editor.cursor); } begin_change(editor); editor.mode = Mode.insert; }
    else if (bytes.equal(key, "I")) { editor.cursor = first_nonblank(editor, line_of_offset(editor, editor.cursor)); begin_change(editor); editor.mode = Mode.insert; }
    else if (bytes.equal(key, "A")) { editor.cursor = line_end(editor, line_of_offset(editor, editor.cursor)); begin_change(editor); editor.mode = Mode.insert; }
    else if (bytes.equal(key, "o")) { open_line(editor, true); }
    else if (bytes.equal(key, "O")) { open_line(editor, false); }
    else if (bytes.equal(key, "x")) { for (var i: u64 = 0; i < count; i += 1) { if (editor.cursor >= len(editor.text)) { break; } var end = next_char(editor.text, editor.cursor); yank_range(editor, editor.cursor, end, false); delete_range(editor, editor.cursor, end); } }
    else if (bytes.equal(key, "X")) { for (var i: u64 = 0; i < count; i += 1) { if (editor.cursor == 0) { break; } var start = previous_char(editor.text, editor.cursor); yank_range(editor, start, editor.cursor, false); delete_range(editor, start, editor.cursor); } }
    else if (bytes.equal(key, "D")) { var end = line_end(editor, line_of_offset(editor, editor.cursor)); yank_range(editor, editor.cursor, end, false); delete_range(editor, editor.cursor, end); }
    else if (bytes.equal(key, "C")) { var end = line_end(editor, line_of_offset(editor, editor.cursor)); yank_range(editor, editor.cursor, end, false); delete_range(editor, editor.cursor, end); begin_change(editor); editor.mode = Mode.insert; }
    else if (bytes.equal(key, "d") || bytes.equal(key, "y") || bytes.equal(key, "c")) { handle_operator(editor, key, count); }
    else if (bytes.equal(key, "p")) { paste(editor, true); }
    else if (bytes.equal(key, "P")) { paste(editor, false); }
    else if (bytes.equal(key, "u")) { undo(editor); }
    else if (bytes.equal(key, "\x12")) { redo(editor); }
    else if (bytes.equal(key, "r")) { replace_char(editor); }
    else if (bytes.equal(key, "J")) { join_line(editor); }
    else if (bytes.equal(key, "/")) { run_search(editor, true); }
    else if (bytes.equal(key, "?")) { run_search(editor, false); }
    else if (bytes.equal(key, "n")) { repeat_search(editor, true); }
    else if (bytes.equal(key, "N")) { repeat_search(editor, false); }
    else if (bytes.equal(key, "*")) { search_word(editor, true); }
    else if (bytes.equal(key, "#")) { search_word(editor, false); }
    else if (bytes.equal(key, "f") || bytes.equal(key, "F") || bytes.equal(key, "t") || bytes.equal(key, "T")) {
        var k = term.read_key(); match (k) { none { } some(target) { var forward = bytes.equal(key, "f") || bytes.equal(key, "t"); var till = bytes.equal(key, "t") || bytes.equal(key, "T"); var p = find_char(editor, target, forward, till, count); match (p) { none { } some(v) { editor.cursor = v; editor.last_find = bytes.clone(target); editor.last_find_forward = forward; editor.last_find_till = till; } } } }
    }
    else if (bytes.equal(key, ";")) { if (len(editor.last_find) > 0) { var p = find_char(editor, editor.last_find, editor.last_find_forward, editor.last_find_till, count); match (p) { none { } some(v) { editor.cursor = v; } } } }
    else if (bytes.equal(key, "]") || bytes.equal(key, "[")) { var k = term.read_key(); match (k) { some(v) { if (bytes.equal(v, "d")) { goto_diagnostic(editor, bytes.equal(key, "]")); } } none { } } }
    else if (bytes.equal(key, "=")) { format_document(editor); }
    else if (bytes.equal(key, "K")) { show_hover(editor); }
    else if (bytes.equal(key, "\x00")) { show_completion(editor); }
    else if (bytes.equal(key, ":")) { return handle_colon(editor); }
    else if (bytes.equal(key, "Z")) { var k = term.read_key(); match (k) { some(v) { if (bytes.equal(v, "Z")) { save(editor); return dirty(editor); } if (bytes.equal(v, "Q")) { return false; } } none { } } }
    else if (bytes.equal(key, "z")) { var k = term.read_key(); match (k) { some(v) { if (bytes.equal(v, "z")) { var pos = position_from_offset(editor, editor.cursor); var half = term.rows() / 2; if (pos.line > half) { editor.top_line = pos.line - half; } else { editor.top_line = 0; } } } none { } } }
    return true;
}

fn dirname(path: []u8) -> []u8 {
    var i = len(path); while (i > 0) { if (path[i - 1] == '/') { return bytes.slice(path, 0, i); } i -= 1; } return "./";
}

fn auto_server(path: []u8) -> []u8 {
    var name: []u8 = "l-lsp";
    if (bytes.ends_with(path, ".json")) { name = "json-lsp"; }
    else if (bytes.ends_with(path, ".ini") || bytes.ends_with(path, ".cfg")) { name = "ini-lsp"; }
    var out = dirname(sys.exe_path()); bytes.append(out, name); return out;
}

fn language_id(path: []u8) -> []u8 {
    if (bytes.ends_with(path, ".json")) { return "json"; }
    if (bytes.ends_with(path, ".ini") || bytes.ends_with(path, ".cfg")) { return "ini"; }
    return "simplec";
}

fn run_editor(path: []u8, server_argv: [][]u8) {
    var cfg = load_config();
    var content_opt = fs.read(path); var text: []u8 = [];
    match (content_opt) { none { } some(content) { text = content; } }
    var actual_server = arrays.clone(server_argv); if (len(actual_server) == 0) { push(actual_server, auto_server(path)); }
    var lsp_client = client.start(actual_server);
    var lsp_ok = client.initialize(lsp_client);
    var editor = new Editor {
        path: bytes.clone(path), uri: make_uri(path), text: text, lines: [], cursor: 0, goal_col: 0, version: 1,
        mode: Mode.normal, lsp: lsp_client, lsp_active: lsp_ok, lsp_dirty: false, pending_lsp: [], semantic_request: 0,
        semantic_request_start: 0, semantic_request_end: 0, semantic_request_revision: 0, semantic_start: 0, semantic_end: 0, revision: 1,
        highlights: [], diagnostics: [], diagnostic_count: 0, status: "", theme: cfg.theme, relative_numbers: cfg.relative_numbers, top_line: 0, hscroll: 0, yank: [], yank_linewise: false,
        undo: [], redo: [], current_edits: [], current_before: 0, recording: false,
        state_id: 0, next_state_id: 1, saved_state_id: 0, last_search: [], last_search_forward: true,
        last_find: [], last_find_forward: true, last_find_till: false, visual_anchor: 0, tab_width: cfg.tab_width, scrolloff: cfg.scrolloff,
    };
    rebuild_lines(editor);
    if (editor.lsp_active) { client.did_open(editor.lsp, editor.uri, editor.text, editor.version, language_id(path)); }
    else { set_status(editor, "LSP unavailable · editing continues"); }
    if (editor.lsp_active && len(editor.text) > AUTO_LSP_LIMIT) { set_status(editor, "large file · viewport highlighting active"); }
    term.enter_ui();
    var running = true;
    while (running) {
        poll_lsp(editor); render(editor); request_visible_semantic(editor);
        var key_opt = term.read_key_timeout(40);
        match (key_opt) {
            none { sync_lsp(editor); }
            some(key) { if (editor.mode is Mode.insert) { handle_insert(editor, key); } else if (visual_active(editor)) { running = handle_visual(editor, key); } else { running = handle_normal(editor, key); } }
        }
    }
    if (editor.recording) { commit_change(editor); }
    term.leave_ui(); client.stop(editor.lsp);
}

pub fn main() {
    var args = sys.args();
    if (len(args) == 0 || bytes.equal(args[0], "--help") || bytes.equal(args[0], "-h")) {
        term.write("Lace 0.8 — quiet modal editor written in L\n\nusage: lace FILE [LSP [ARGS...]]\n       lace --version\n\nLSP is selected from the file extension when omitted.\nConfig: $XDG_CONFIG_HOME/lace/config.ini or ~/.config/lace/config.ini\n"); return;
    }
    if (bytes.equal(args[0], "--version")) { term.write("lace 0.8\n"); return; }
    var path = args[0]; var server_argv: [][]u8 = [];
    for (var i: u64 = 1; i < len(args); i += 1) { push(server_argv, args[i]); }
    run_editor(path, server_argv);
}
