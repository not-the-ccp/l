import arrays;
import bytes;
import tools.lace2.history as history;
import tools.lace2.navigation as nav;
import tools.lace2.piece_tree as text;
import tools.lace2.selection as selection;
import tools.lace2.transaction as transaction;

pub enum Mode { normal, insert, visual, visual_line }
pub enum UnicodeGuard { suspicious, all_non_ascii, off }

pub struct Editor {
    pub doc: ref text.Text,
    pub selections: selection.Set,
    pub history: ref history.History,
    pub mode: Mode,
    pub visual_anchor: u64,
    pub yank: const []u8,
    pub yank_linewise: bool,
    pub goal_column: u64,
    pub goal_valid: bool,
    pub pending_change: bool,
    pub saved_history_id: u64,
    pub unicode_guard: UnicodeGuard,
    pub tab_width: u64,
}

pub struct Span {
    pub start: u64,
    pub end: u64,
}

pub fn create(data: const []u8) -> ref Editor {
    var doc = text.from_bytes(data);
    var selections = selection.single(0);
    var h = history.start(doc, selections);
    return new Editor {
        doc: doc,
        selections: selections,
        history: h,
        mode: Mode.normal,
        visual_anchor: 0,
        yank: [],
        yank_linewise: false,
        goal_column: 0,
        goal_valid: false,
        pending_change: false,
        saved_history_id: history.current_id(h),
        unicode_guard: UnicodeGuard.suspicious,
        tab_width: 4,
    };
}

pub fn cursor(editor: ref Editor) -> u64 {
    return editor.selections.ranges[editor.selections.primary].head.offset;
}

pub fn set_cursor(editor: ref Editor, pos: u64) {
    if (pos > text.byte_len(editor.doc)) { trap; }
    editor.selections = selection.single(pos);
}

// Insert mode uses byte boundaries between atoms. Command and visual modes use
// atoms themselves. In particular, a newline that terminates a non-empty line
// is not an extra character cell the modal cursor can sit on.
fn command_position(editor: ref Editor, pos: u64) -> u64 {
    if (pos > text.byte_len(editor.doc)) { trap; }
    var start = nav.line_start(editor.doc, pos);
    var end = nav.line_end(editor.doc, pos);
    if (pos == end && end > start) { return nav.cursor_end(editor.doc, pos); }
    return pos;
}

fn set_motion_cursor(editor: ref Editor, pos: u64) {
    if (editor.mode is Mode.insert) { set_cursor(editor, pos); }
    else { set_cursor(editor, command_position(editor, pos)); }
}

fn normalize_command_cursor(editor: ref Editor) {
    set_cursor(editor, command_position(editor, cursor(editor)));
}

pub fn dirty(editor: ref Editor) -> bool {
    return editor.pending_change || history.current_id(editor.history) != editor.saved_history_id;
}

pub fn mark_saved(editor: ref Editor) {
    if (editor.pending_change) { commit_change(editor, "edit"); }
    editor.saved_history_id = history.current_id(editor.history);
}

pub fn commit_change(editor: ref Editor, label: const []u8) {
    if (!editor.pending_change) { return; }
    history.commit(editor.history, editor.doc, editor.selections, label);
    editor.pending_change = false;
}

fn apply_replace(editor: ref Editor, start: u64, end: u64, inserted: const []u8, cursor_after: u64) {
    transaction.apply(editor.doc, [transaction.EditSpec {
        start: start,
        end: end,
        inserted: inserted,
    }]);
    set_cursor(editor, cursor_after);
    editor.pending_change = true;
    editor.goal_valid = false;
}

fn finish_normal_change(editor: ref Editor, label: const []u8) {
    // History snapshots must contain the same cursor position the user sees.
    // Committing first used to preserve a one-past-EOL insertion boundary in
    // history, so redo could resurrect an invalid Normal-mode cursor.
    editor.mode = Mode.normal;
    normalize_command_cursor(editor);
    commit_change(editor, label);
}

fn line_span(editor: ref Editor, pos: u64) -> Span {
    var start = nav.line_start(editor.doc, pos);
    var end = nav.line_end(editor.doc, pos);
    if (end < text.byte_len(editor.doc)) { end += 1; }
    return Span { start: start, end: end };
}

fn leading_indent(editor: ref Editor, pos: u64) -> const []u8 {
    var start = nav.line_start(editor.doc, pos);
    var end = nav.line_end(editor.doc, pos);
    var cursor_pos = start;
    while (cursor_pos < end) {
        var value = text.byte_at(editor.doc, cursor_pos);
        if (value != ' ' && value != '\t') { break; }
        cursor_pos += 1;
    }
    return text.slice(editor.doc, start, cursor_pos);
}

pub fn enter_insert(editor: ref Editor, pos: u64) {
    set_cursor(editor, pos);
    editor.mode = Mode.insert;
    editor.pending_change = false;
}

pub fn leave_insert(editor: ref Editor) {
    editor.mode = Mode.normal;
    var pos = cursor(editor);
    var start = nav.line_start(editor.doc, pos);
    if (pos > start) { set_cursor(editor, nav.previous_atom(editor.doc, pos)); }
    normalize_command_cursor(editor);
    commit_change(editor, "insert");
}

pub fn insert_bytes(editor: ref Editor, value: const []u8) {
    var pos = cursor(editor);
    apply_replace(editor, pos, pos, value, pos + len(value));
}

pub fn insert_byte(editor: ref Editor, value: u8) {
    insert_bytes(editor, [value]);
}

pub fn insert_newline(editor: ref Editor) {
    var pos = cursor(editor);
    var indent = leading_indent(editor, pos);
    var inserted: []u8 = ['\n'];
    bytes.append(inserted, indent);
    apply_replace(editor, pos, pos, inserted, pos + len(inserted));
}

pub fn backspace(editor: ref Editor) {
    var pos = cursor(editor);
    if (pos == 0) { return; }
    var start = nav.previous_atom(editor.doc, pos);
    apply_replace(editor, start, pos, [], start);
}

pub fn delete_forward(editor: ref Editor, count: u64) {
    var pos = cursor(editor);
    var end = pos;
    var n: u64 = 0;
    while (n < count && end < text.byte_len(editor.doc) && text.byte_at(editor.doc, end) != '\n') {
        end = nav.next_atom(editor.doc, end);
        n += 1;
    }
    if (end == pos) { return; }
    editor.yank = text.slice(editor.doc, pos, end);
    editor.yank_linewise = false;
    apply_replace(editor, pos, end, [], pos);
    finish_normal_change(editor, "delete");
}

pub fn delete_span(editor: ref Editor, span: Span, linewise: bool, enter_insert_after: bool) {
    if (span.start > span.end || span.end > text.byte_len(editor.doc)) { trap; }
    if (span.start == span.end) { return; }
    editor.yank = text.slice(editor.doc, span.start, span.end);
    editor.yank_linewise = linewise;
    apply_replace(editor, span.start, span.end, [], span.start);
    if (enter_insert_after) {
        editor.mode = Mode.insert;
    } else {
        finish_normal_change(editor, "delete");
    }
}

pub fn yank_span(editor: ref Editor, span: Span, linewise: bool) {
    if (span.start > span.end || span.end > text.byte_len(editor.doc)) { trap; }
    editor.yank = text.slice(editor.doc, span.start, span.end);
    editor.yank_linewise = linewise;
}

pub fn line_count_span(editor: ref Editor, count: u64) -> Span {
    var span = line_span(editor, cursor(editor));
    var end = span.end;
    var n: u64 = 1;
    while (n < count && end < text.byte_len(editor.doc)) {
        var next = line_span(editor, end);
        if (next.end <= end) { break; }
        end = next.end;
        n += 1;
    }
    return Span { start: span.start, end: end };
}

pub fn current_line_span(editor: ref Editor) -> Span {
    return line_count_span(editor, 1);
}

pub fn motion_span_count(editor: ref Editor, motion: u8, count: u64) -> ?Span {
    var pos = cursor(editor);
    var target = pos;
    var n: u64 = 0;
    if (motion == 'w') {
        while (n < count) {
            var next = nav.word_forward(editor.doc, target);
            if (next == target) { break; }
            target = next;
            n += 1;
        }
    }
    else if (motion == 'b') {
        while (n < count) {
            var next = nav.word_backward(editor.doc, target);
            if (next == target) { break; }
            target = next;
            n += 1;
        }
    }
    else if (motion == 'e') {
        while (n < count) {
            if (target >= text.byte_len(editor.doc)) { break; }
            var end = nav.word_end(editor.doc, target);
            var next = end;
            if (next < text.byte_len(editor.doc)) { next = nav.next_atom(editor.doc, next); }
            if (next == target) { break; }
            target = next;
            n += 1;
        }
    }
    else if (motion == '0') { target = nav.line_start(editor.doc, pos); }
    else if (motion == '^') { target = nav.first_nonblank(editor.doc, pos); }
    else if (motion == '$') {
        n = 1;
        while (n < count) {
            var next_line = nav.next_line_start(editor.doc, target);
            match (next_line) {
                none { break; }
                some(value) { target = value; n += 1; }
            }
        }
        target = nav.line_end(editor.doc, target);
    }
    else { return none; }

    if (target < pos) { return some(Span { start: target, end: pos }); }
    return some(Span { start: pos, end: target });
}

pub fn motion_span(editor: ref Editor, motion: u8) -> ?Span {
    return motion_span_count(editor, motion, 1);
}

pub fn change_motion_span(editor: ref Editor, motion: u8, count: u64) -> ?Span {
    if (motion == 'w') {
        var pos = cursor(editor);
        if (pos < text.byte_len(editor.doc)) {
            var value = text.byte_at(editor.doc, pos);
            if (value != ' ' && value != '\t' && value != '\r' && value != '\n') {
                return motion_span_count(editor, 'e', count);
            }
        }
    }
    return motion_span_count(editor, motion, count);
}

pub fn open_line(editor: ref Editor, below: bool) {
    var pos = cursor(editor);
    var indent = leading_indent(editor, pos);
    if (below) {
        var end = nav.line_end(editor.doc, pos);
        if (end < text.byte_len(editor.doc)) {
            var inserted = bytes.clone(indent);
            push(inserted, '\n');
            apply_replace(editor, end + 1, end + 1, inserted, end + 1 + len(indent));
        } else {
            var inserted: []u8 = ['\n'];
            bytes.append(inserted, indent);
            apply_replace(editor, end, end, inserted, end + 1 + len(indent));
        }
    } else {
        var start = nav.line_start(editor.doc, pos);
        var inserted = bytes.clone(indent);
        push(inserted, '\n');
        apply_replace(editor, start, start, inserted, start + len(indent));
    }
    editor.mode = Mode.insert;
}

pub fn paste(editor: ref Editor, after: bool) {
    if (len(editor.yank) == 0) { return; }
    var pos = cursor(editor);
    var insert_at = pos;
    if (editor.yank_linewise) {
        var end = nav.line_end(editor.doc, pos);
        if (after) {
            if (end < text.byte_len(editor.doc)) { insert_at = end + 1; }
            else { insert_at = end; }
        } else {
            insert_at = nav.line_start(editor.doc, pos);
        }
    } else if (after && pos < text.byte_len(editor.doc)) {
        insert_at = nav.next_atom(editor.doc, pos);
    }
    apply_replace(editor, insert_at, insert_at, editor.yank, insert_at);
    finish_normal_change(editor, "paste");
}

pub fn replace_atom(editor: ref Editor, value: const []u8) {
    var pos = cursor(editor);
    if (pos >= text.byte_len(editor.doc) || text.byte_at(editor.doc, pos) == '\n') { return; }
    var end = nav.next_atom(editor.doc, pos);
    apply_replace(editor, pos, end, value, pos);
    finish_normal_change(editor, "replace");
}

pub fn undo(editor: ref Editor) {
    if (editor.pending_change) { commit_change(editor, "edit"); }
    var restored = history.undo(editor.history, editor.doc);
    match (restored) {
        none { }
        some(value) { editor.selections = value; }
    }
    editor.mode = Mode.normal;
    normalize_command_cursor(editor);
    editor.goal_valid = false;
}

pub fn redo(editor: ref Editor) {
    if (editor.pending_change) { commit_change(editor, "edit"); }
    var count = history.child_count(editor.history);
    if (count == 0) { return; }
    var restored = history.redo(editor.history, editor.doc, count - 1);
    match (restored) {
        none { }
        some(value) { editor.selections = value; }
    }
    editor.mode = Mode.normal;
    normalize_command_cursor(editor);
    editor.goal_valid = false;
}

pub fn enter_visual(editor: ref Editor, linewise: bool) {
    editor.visual_anchor = cursor(editor);
    if (linewise) { editor.mode = Mode.visual_line; }
    else { editor.mode = Mode.visual; }
}

pub fn leave_visual(editor: ref Editor) {
    editor.mode = Mode.normal;
    normalize_command_cursor(editor);
}

pub fn visual_span(editor: ref Editor) -> ?Span {
    if (!(editor.mode is Mode.visual) && !(editor.mode is Mode.visual_line)) { return none; }
    var anchor = editor.visual_anchor;
    var head = cursor(editor);
    if (editor.mode is Mode.visual_line) {
        var first = anchor;
        var last = head;
        if (last < first) { var swap = first; first = last; last = swap; }
        var start = nav.line_start(editor.doc, first);
        var end = nav.line_end(editor.doc, last);
        if (end < text.byte_len(editor.doc)) { end += 1; }
        return some(Span { start: start, end: end });
    }

    var start = anchor;
    var end_pos = head;
    if (end_pos < start) { var swap = start; start = end_pos; end_pos = swap; }
    var end = end_pos;
    if (end < text.byte_len(editor.doc)) { end = nav.next_atom(editor.doc, end); }
    return some(Span { start: start, end: end });
}

pub fn move_left(editor: ref Editor, count: u64) {
    var pos = cursor(editor);
    var start = nav.line_start(editor.doc, pos);
    var n: u64 = 0;
    while (n < count && pos > start) { pos = nav.previous_atom(editor.doc, pos); n += 1; }
    set_motion_cursor(editor, pos);
    editor.goal_valid = false;
}

pub fn move_right(editor: ref Editor, count: u64) {
    var pos = cursor(editor);
    var end = nav.line_end(editor.doc, pos);
    var n: u64 = 0;
    while (n < count && pos < end) { pos = nav.next_atom(editor.doc, pos); n += 1; }
    set_motion_cursor(editor, pos);
    editor.goal_valid = false;
}

pub fn move_word_forward(editor: ref Editor, count: u64) {
    var pos = cursor(editor);
    var n: u64 = 0;
    while (n < count) {
        var next = nav.word_forward(editor.doc, pos);
        if (next == pos) { break; }
        pos = next;
        n += 1;
    }
    set_motion_cursor(editor, pos);
    editor.goal_valid = false;
}

pub fn move_word_backward(editor: ref Editor, count: u64) {
    var pos = cursor(editor);
    var n: u64 = 0;
    while (n < count) {
        var next = nav.word_backward(editor.doc, pos);
        if (next == pos) { break; }
        pos = next;
        n += 1;
    }
    set_motion_cursor(editor, pos);
    editor.goal_valid = false;
}

pub fn move_word_end(editor: ref Editor, count: u64) {
    var pos = cursor(editor);
    var length = text.byte_len(editor.doc);
    var n: u64 = 0;
    while (n < count) {
        if (pos >= length) { break; }
        pos = nav.word_end(editor.doc, pos);
        if (n + 1 < count && pos < length) { pos = nav.next_atom(editor.doc, pos); }
        n += 1;
    }
    set_motion_cursor(editor, pos);
    editor.goal_valid = false;
}

pub fn move_line_start(editor: ref Editor, first_nonblank: bool) {
    var pos = cursor(editor);
    if (first_nonblank) { set_motion_cursor(editor, nav.first_nonblank(editor.doc, pos)); }
    else { set_motion_cursor(editor, nav.line_start(editor.doc, pos)); }
    editor.goal_valid = false;
}

pub fn move_line_end(editor: ref Editor) {
    if (editor.mode is Mode.insert) { set_cursor(editor, nav.line_end(editor.doc, cursor(editor))); }
    else { set_cursor(editor, nav.cursor_end(editor.doc, cursor(editor))); }
    editor.goal_valid = false;
}

pub fn move_vertical(editor: ref Editor, down: bool, count: u64) {
    var pos = cursor(editor);
    if (!editor.goal_valid) {
        var start = nav.line_start(editor.doc, pos);
        editor.goal_column = nav.screen_column(editor.doc, start, pos, editor.tab_width);
        editor.goal_valid = true;
    }
    var n: u64 = 0;
    while (n < count) {
        var next = nav.move_vertical(editor.doc, pos, down, editor.goal_column, editor.tab_width);
        if (next == pos) { break; }
        pos = next;
        n += 1;
    }
    set_motion_cursor(editor, pos);
}

pub fn move_document_start(editor: ref Editor) {
    set_motion_cursor(editor, 0);
    editor.goal_valid = false;
}

pub fn move_document_end(editor: ref Editor) {
    var length = text.byte_len(editor.doc);
    if (length == 0) { set_cursor(editor, 0); }
    else {
        var end = nav.line_end(editor.doc, length);
        if (end == length && end > nav.line_start(editor.doc, end)) { set_motion_cursor(editor, nav.previous_atom(editor.doc, end)); }
        else { set_motion_cursor(editor, end); }
    }
    editor.goal_valid = false;
}

pub fn find_forward(editor: ref Editor, needle: const []u8, start: u64) -> ?u64 {
    if (len(needle) == 0) { return none; }
    var haystack = text.to_bytes(editor.doc);
    return bytes.find(haystack, needle, start);
}

pub fn find_backward(editor: ref Editor, needle: const []u8, before: u64) -> ?u64 {
    if (len(needle) == 0) { return none; }
    var haystack = text.to_bytes(editor.doc);
    if (len(needle) > len(haystack)) { return none; }
    var limit = before;
    if (limit > len(haystack)) { limit = len(haystack); }
    var found: ?u64 = none;
    var pos: u64 = 0;
    while (pos + len(needle) <= limit) {
        var next = bytes.find(haystack, needle, pos);
        match (next) {
            none { return found; }
            some(value) {
                if (value + len(needle) > limit) { return found; }
                found = some(value);
                pos = value + 1;
            }
        }
    }
    return found;
}