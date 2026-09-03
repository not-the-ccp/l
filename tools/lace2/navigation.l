import term;
import utf8;
import byte_display as display;
import tools.lace2.piece_tree as text;

fn valid_utf8_width(doc: ref text.Text, pos: u64) -> u64 {
    var length = text.byte_len(doc);
    if (pos >= length) { return 0; }
    var available = length - pos;
    if (available > 4) { available = 4; }
    var b0 = text.byte_at(doc, pos);
    var b1: u8 = 0;
    var b2: u8 = 0;
    var b3: u8 = 0;
    if (available > 1) { b1 = text.byte_at(doc, pos + 1); }
    if (available > 2) { b2 = text.byte_at(doc, pos + 2); }
    if (available > 3) { b3 = text.byte_at(doc, pos + 3); }
    return utf8.valid_scalar_width(b0, b1, b2, b3, available);
}

pub fn next_atom(doc: ref text.Text, pos: u64) -> u64 {
    var length = text.byte_len(doc);
    if (pos >= length) { return length; }
    var width = valid_utf8_width(doc, pos);
    if (width == 0) { return pos + 1; }
    return pos + width;
}

pub fn previous_atom(doc: ref text.Text, pos: u64) -> u64 {
    if (pos == 0) { return 0; }
    if (pos > text.byte_len(doc)) { trap; }

    var candidate = pos - 1;
    var steps: u64 = 0;
    while (candidate > 0 && utf8.continuation(text.byte_at(doc, candidate)) && steps < 3) {
        candidate -= 1;
        steps += 1;
    }
    if (next_atom(doc, candidate) == pos) { return candidate; }
    return pos - 1;
}

pub fn line_start(doc: ref text.Text, pos: u64) -> u64 {
    var length = text.byte_len(doc);
    if (pos > length) { trap; }
    var cursor = pos;
    // A terminating newline closes the final logical line; EOF after it is an
    // insertion boundary, not the start of another phantom line.
    if (cursor == length && length > 0 && text.byte_at(doc, length - 1) == '\n') {
        cursor -= 1;
    }
    match (text.previous_newline(doc, cursor)) {
        none { return 0; }
        some(offset) { return offset + 1; }
    }
}

pub fn line_end(doc: ref text.Text, pos: u64) -> u64 {
    var length = text.byte_len(doc);
    if (pos > length) { trap; }
    match (text.next_newline(doc, pos)) {
        none { return length; }
        some(offset) { return offset; }
    }
}

// Last addressable atom for command/selection modes on this line. `line_end`
// is deliberately an insertion boundary, whereas a modal command cursor
// belongs on the last atom of a non-empty line. If EOF follows a terminating
// newline, skip that newline as well.
pub fn cursor_end(doc: ref text.Text, pos: u64) -> u64 {
    var start = line_start(doc, pos);
    var end = line_end(doc, pos);
    var boundary = end;
    var length = text.byte_len(doc);
    if (boundary == length && boundary > 0 && text.byte_at(doc, boundary - 1) == '\n') {
        boundary -= 1;
    }
    if (boundary > start) { return previous_atom(doc, boundary); }
    return start;
}

pub fn previous_line_start(doc: ref text.Text, pos: u64) -> ?u64 {
    var start = line_start(doc, pos);
    if (start == 0) { return none; }
    return some(line_start(doc, start - 1));
}

pub fn next_line_start(doc: ref text.Text, pos: u64) -> ?u64 {
    var end = line_end(doc, pos);
    var length = text.byte_len(doc);
    if (end >= length) { return none; }
    var next = end + 1;
    if (next >= length) { return none; }
    return some(next);
}

pub fn first_nonblank(doc: ref text.Text, pos: u64) -> u64 {
    var cursor = line_start(doc, pos);
    var end = line_end(doc, pos);
    while (cursor < end) {
        var value = text.byte_at(doc, cursor);
        if (value != ' ' && value != '\t') { break; }
        cursor += 1;
    }
    return cursor;
}

fn tab_advance(column: u64, tab_width: u64) -> u64 {
    var width = tab_width;
    if (width == 0) { width = 4; }
    return width - (column % width);
}

const STREAM_CHUNK_BYTES: u64 = 4096;

fn window_end(primary_start: u64, limit: u64) -> u64 {
    var remaining = limit - primary_start;
    var primary = remaining;
    if (primary > STREAM_CHUNK_BYTES) { primary = STREAM_CHUNK_BYTES; }
    var lookahead = remaining - primary;
    if (lookahead > 3) { lookahead = 3; }
    return primary_start + primary + lookahead;
}

pub fn screen_column(doc: ref text.Text, line: u64, pos: u64, tab_width: u64) -> u64 {
    if (line > pos || pos > text.byte_len(doc)) { trap; }
    var absolute = line;
    var column: u64 = 0;
    while (absolute < pos) {
        var remaining = pos - absolute;
        var primary = remaining;
        if (primary > STREAM_CHUNK_BYTES) { primary = STREAM_CHUNK_BYTES; }
        var chunk = text.slice(doc, absolute, window_end(absolute, pos));
        var offset: u64 = 0;
        while (offset < primary) {
            var unit = display.next_unit(chunk, offset);
            if (unit.kind is display.UnitKind.tab) {
                column += tab_advance(column, tab_width);
            } else {
                column += term.text_width(display.representation(chunk, unit));
            }
            offset = unit.end;
        }
        absolute += offset;
    }
    return column;
}

pub fn offset_for_column(doc: ref text.Text, line: u64, target: u64, tab_width: u64) -> u64 {
    var end = line_end(doc, line);
    var absolute = line;
    var column: u64 = 0;
    while (absolute < end) {
        var remaining = end - absolute;
        var primary = remaining;
        if (primary > STREAM_CHUNK_BYTES) { primary = STREAM_CHUNK_BYTES; }
        var chunk = text.slice(doc, absolute, window_end(absolute, end));
        var offset: u64 = 0;
        while (offset < primary) {
            var unit = display.next_unit(chunk, offset);
            var advance: u64 = 0;
            if (unit.kind is display.UnitKind.tab) { advance = tab_advance(column, tab_width); }
            else { advance = term.text_width(display.representation(chunk, unit)); }
            if (column + advance > target) { return absolute + unit.start; }
            column += advance;
            offset = unit.end;
        }
        absolute += offset;
    }
    return end;
}

pub fn move_vertical(doc: ref text.Text, pos: u64, down: bool, goal_column: u64, tab_width: u64) -> u64 {
    var target_line: ?u64 = none;
    if (down) { target_line = next_line_start(doc, pos); }
    else { target_line = previous_line_start(doc, pos); }
    match (target_line) {
        none { return pos; }
        some(start) { return offset_for_column(doc, start, goal_column, tab_width); }
    }
}

fn byte_class(value: u8) -> u8 {
    if (value == ' ' || value == '\t' || value == '\r' || value == '\n') { return 0; }
    if ((value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') || (value >= '0' && value <= '9') || value == '_' || value >= 0x80) { return 1; }
    return 2;
}

pub fn word_forward(doc: ref text.Text, pos: u64) -> u64 {
    var length = text.byte_len(doc);
    if (pos >= length) { return length; }
    var cursor = pos;
    var cls = byte_class(text.byte_at(doc, cursor));
    if (cls != 0) {
        while (cursor < length && byte_class(text.byte_at(doc, cursor)) == cls) {
            cursor = next_atom(doc, cursor);
        }
    }
    while (cursor < length && byte_class(text.byte_at(doc, cursor)) == 0) {
        cursor = next_atom(doc, cursor);
    }
    return cursor;
}

pub fn word_backward(doc: ref text.Text, pos: u64) -> u64 {
    if (pos == 0) { return 0; }
    var cursor = previous_atom(doc, pos);
    while (cursor > 0 && byte_class(text.byte_at(doc, cursor)) == 0) {
        cursor = previous_atom(doc, cursor);
    }
    var cls = byte_class(text.byte_at(doc, cursor));
    while (cursor > 0) {
        var previous = previous_atom(doc, cursor);
        if (byte_class(text.byte_at(doc, previous)) != cls) { break; }
        cursor = previous;
    }
    return cursor;
}

pub fn word_end(doc: ref text.Text, pos: u64) -> u64 {
    var length = text.byte_len(doc);
    if (pos >= length) { return length; }
    var cursor = pos;
    while (cursor < length && byte_class(text.byte_at(doc, cursor)) == 0) {
        cursor = next_atom(doc, cursor);
    }
    if (cursor >= length) { return length; }
    var cls = byte_class(text.byte_at(doc, cursor));
    var last = cursor;
    while (cursor < length && byte_class(text.byte_at(doc, cursor)) == cls) {
        last = cursor;
        cursor = next_atom(doc, cursor);
    }
    return last;
}