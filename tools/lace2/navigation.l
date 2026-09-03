import term;
import tools.lace2.display_bytes as display;
import tools.lace2.piece_tree as text;

fn continuation(value: u8) -> bool {
    return (value & 0xc0) == 0x80;
}

fn valid_utf8_width(doc: ref text.Text, pos: u64) -> u64 {
    var length = text.byte_len(doc);
    if (pos >= length) { return 0; }
    var b0 = text.byte_at(doc, pos);
    if (b0 < 0x80) { return 1; }

    if (b0 >= 0xc2 && b0 <= 0xdf) {
        if (pos + 2 > length) { return 0; }
        if (!continuation(text.byte_at(doc, pos + 1))) { return 0; }
        return 2;
    }
    if (b0 == 0xe0) {
        if (pos + 3 > length) { return 0; }
        var b1 = text.byte_at(doc, pos + 1);
        if (b1 < 0xa0 || b1 > 0xbf || !continuation(text.byte_at(doc, pos + 2))) { return 0; }
        return 3;
    }
    if ((b0 >= 0xe1 && b0 <= 0xec) || (b0 >= 0xee && b0 <= 0xef)) {
        if (pos + 3 > length) { return 0; }
        if (!continuation(text.byte_at(doc, pos + 1)) || !continuation(text.byte_at(doc, pos + 2))) { return 0; }
        return 3;
    }
    if (b0 == 0xed) {
        if (pos + 3 > length) { return 0; }
        var b1 = text.byte_at(doc, pos + 1);
        if (b1 < 0x80 || b1 > 0x9f || !continuation(text.byte_at(doc, pos + 2))) { return 0; }
        return 3;
    }
    if (b0 == 0xf0) {
        if (pos + 4 > length) { return 0; }
        var b1 = text.byte_at(doc, pos + 1);
        if (b1 < 0x90 || b1 > 0xbf) { return 0; }
        if (!continuation(text.byte_at(doc, pos + 2)) || !continuation(text.byte_at(doc, pos + 3))) { return 0; }
        return 4;
    }
    if (b0 >= 0xf1 && b0 <= 0xf3) {
        if (pos + 4 > length) { return 0; }
        if (!continuation(text.byte_at(doc, pos + 1)) || !continuation(text.byte_at(doc, pos + 2)) || !continuation(text.byte_at(doc, pos + 3))) { return 0; }
        return 4;
    }
    if (b0 == 0xf4) {
        if (pos + 4 > length) { return 0; }
        var b1 = text.byte_at(doc, pos + 1);
        if (b1 < 0x80 || b1 > 0x8f) { return 0; }
        if (!continuation(text.byte_at(doc, pos + 2)) || !continuation(text.byte_at(doc, pos + 3))) { return 0; }
        return 4;
    }
    return 0;
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
    while (candidate > 0 && continuation(text.byte_at(doc, candidate)) && steps < 3) {
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
    while (cursor > 0 && text.byte_at(doc, cursor - 1) != '\n') { cursor -= 1; }
    return cursor;
}

pub fn line_end(doc: ref text.Text, pos: u64) -> u64 {
    var length = text.byte_len(doc);
    if (pos > length) { trap; }
    var cursor = pos;
    while (cursor < length && text.byte_at(doc, cursor) != '\n') { cursor += 1; }
    return cursor;
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

pub fn screen_column(doc: ref text.Text, line: u64, pos: u64, tab_width: u64) -> u64 {
    if (line > pos || pos > text.byte_len(doc)) { trap; }
    var bytes = text.slice(doc, line, pos);
    var offset: u64 = 0;
    var column: u64 = 0;
    while (offset < len(bytes)) {
        var unit = display.next_unit(bytes, offset);
        if (unit.kind is display.UnitKind.tab) {
            column += tab_advance(column, tab_width);
        } else {
            var shown = display.representation(bytes, unit);
            column += term.text_width(shown);
        }
        offset = unit.end;
    }
    return column;
}

pub fn offset_for_column(doc: ref text.Text, line: u64, target: u64, tab_width: u64) -> u64 {
    var end = line_end(doc, line);
    var bytes = text.slice(doc, line, end);
    var offset: u64 = 0;
    var column: u64 = 0;
    while (offset < len(bytes)) {
        var unit = display.next_unit(bytes, offset);
        var advance: u64 = 0;
        if (unit.kind is display.UnitKind.tab) { advance = tab_advance(column, tab_width); }
        else { advance = term.text_width(display.representation(bytes, unit)); }
        if (column + advance > target) { break; }
        column += advance;
        offset = unit.end;
    }
    return line + offset;
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