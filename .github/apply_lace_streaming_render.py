from pathlib import Path


def once(path: str, old: str, new: str, label: str) -> None:
    p = Path(path)
    s = p.read_text()
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"{label}: expected one match, got {n}")
    p.write_text(s.replace(old, new, 1))


# The piece tree already stores newline counts in every piece and subtree. Use
# those aggregates for line lookup instead of repeatedly descending the tree for
# one byte at a time.
once(
    "tools/lace2/piece_tree.l",
    "pub fn from_bytes(data: const []u8) -> ref Text {\n",
    '''fn find_next_newline(text: ref Text, node_opt: ?ref Node, start: u64) -> ?u64 {
    match (node_opt) {
        none { return none; }
        some(root) {
            if (start >= root.byte_len || root.newline_count == 0) { return none; }
            var left_len = node_bytes(root.left);
            var piece_end = left_len + root.piece.length;

            if (start < left_len && node_newlines(root.left) > 0) {
                match (find_next_newline(text, root.left, start)) {
                    none {}
                    some(offset) { return some(offset); }
                }
            }

            var piece_start: u64 = 0;
            if (start > left_len) { piece_start = start - left_len; }
            if (piece_start < root.piece.length && root.piece.newlines > 0) {
                var src = piece_source(text, root.piece.source);
                var i = piece_start;
                while (i < root.piece.length) {
                    if (src[root.piece.start + i] == '\n') { return some(left_len + i); }
                    i += 1;
                }
            }

            if (node_newlines(root.right) > 0) {
                var right_start: u64 = 0;
                if (start > piece_end) { right_start = start - piece_end; }
                match (find_next_newline(text, root.right, right_start)) {
                    none {}
                    some(offset) { return some(piece_end + offset); }
                }
            }
            return none;
        }
    }
}

fn find_previous_newline(text: ref Text, node_opt: ?ref Node, before: u64) -> ?u64 {
    match (node_opt) {
        none { return none; }
        some(root) {
            if (before == 0 || root.newline_count == 0) { return none; }
            if (before > root.byte_len) { trap; }
            var left_len = node_bytes(root.left);
            var piece_end = left_len + root.piece.length;

            if (before > piece_end && node_newlines(root.right) > 0) {
                match (find_previous_newline(text, root.right, before - piece_end)) {
                    none {}
                    some(offset) { return some(piece_end + offset); }
                }
            }

            if (before > left_len && root.piece.newlines > 0) {
                var piece_before = before - left_len;
                if (piece_before > root.piece.length) { piece_before = root.piece.length; }
                var src = piece_source(text, root.piece.source);
                var i = piece_before;
                while (i > 0) {
                    i -= 1;
                    if (src[root.piece.start + i] == '\n') { return some(left_len + i); }
                }
            }

            if (node_newlines(root.left) > 0) {
                var left_before = before;
                if (left_before > left_len) { left_before = left_len; }
                match (find_previous_newline(text, root.left, left_before)) {
                    none {}
                    some(offset) { return some(offset); }
                }
            }
            return none;
        }
    }
}

pub fn next_newline(text: ref Text, start: u64) -> ?u64 {
    if (start > byte_len(text)) { trap; }
    return find_next_newline(text, text.root, start);
}

pub fn previous_newline(text: ref Text, before: u64) -> ?u64 {
    if (before > byte_len(text)) { trap; }
    return find_previous_newline(text, text.root, before);
}

pub fn from_bytes(data: const []u8) -> ref Text {
''',
    "piece-tree newline index",
)

# Line start/end become logarithmic tree navigation plus at most one piece scan.
once(
    "tools/lace2/navigation.l",
    '''pub fn line_start(doc: ref text.Text, pos: u64) -> u64 {
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
''',
    '''pub fn line_start(doc: ref text.Text, pos: u64) -> u64 {
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
''',
    "indexed line boundaries",
)

# Avoid allocating the whole line prefix for every redraw/vertical motion. A
# 4KiB primary chunk gets up to three lookahead bytes so UTF-8 atoms crossing a
# piece/window boundary are still decoded once as a unit.
once(
    "tools/lace2/navigation.l",
    '''pub fn screen_column(doc: ref text.Text, line: u64, pos: u64, tab_width: u64) -> u64 {
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
''',
    '''const STREAM_CHUNK_BYTES: u64 = 4096;

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
''',
    "bounded display-column traversal",
)

# Selection bounds are stable for a frame; do not recompute visual-line spans
# for every display atom.
once(
    "tools/lace2/render.l",
    '''fn selected(editor: ref model.Editor, pos: u64) -> bool {
    var span_opt = model.visual_span(editor);
    match (span_opt) {
        none { return false; }
        some(span) { return pos >= span.start && pos < span.end; }
    }
}
''',
    '''fn selected(span_opt: ?model.Span, pos: u64) -> bool {
    match (span_opt) {
        none { return false; }
        some(span) { return pos >= span.start && pos < span.end; }
    }
}
''',
    "frame-stable visual span",
)

old_render = '''fn render_line(
    out: []u8,
    editor: ref model.Editor,
    line_start: u64,
    line_number: u64,
    row: u64,
    cols: u64,
    hscroll: u64,
    frame: ref Frame
) {
    bytes.append(out, "\\x1b[2K");
    append_gutter(out, line_number);
    if (cols <= GUTTER_WIDTH) { return; }
    var content_cols = cols - GUTTER_WIDTH;
    var end = nav.line_end(editor.doc, line_start);
    var line = text.slice(editor.doc, line_start, end);
    var offset: u64 = 0;
    var logical_column: u64 = 0;
    var painted: u64 = 0;
    var cursor_pos = model.cursor(editor);

    while (offset < len(line)) {
        var unit = display.next_unit(line, offset);
        var shown: []u8 = [];
        var width: u64 = 0;
        if (unit.kind is display.UnitKind.tab) {
            var tab = editor.tab_width;
            if (tab == 0) { tab = 4; }
            width = tab - (logical_column % tab);
        } else {
            shown = display.representation(line, unit);
            width = term.text_width(shown);
        }

        var document_pos = line_start + unit.start;
        if (cursor_pos == document_pos && logical_column >= hscroll && logical_column - hscroll <= content_cols) {
            frame.cursor_row = row;
            frame.cursor_col = GUTTER_WIDTH + 1 + (logical_column - hscroll);
            frame.cursor_visible = true;
        }

        if (logical_column + width > hscroll) {
            var left_clip: u64 = 0;
            if (logical_column < hscroll) { left_clip = hscroll - logical_column; }
            var visible_width = width - left_clip;
            if (painted + visible_width > content_cols) { break; }
            append_unit_style(out, editor, unit, selected(editor, document_pos));
            if (unit.kind is display.UnitKind.tab) {
                if (left_clip == 0) { painted += append_tab(out, logical_column, editor.tab_width); }
                else { append_spaces(out, visible_width); painted += visible_width; }
            } else if (left_clip == 0) {
                bytes.append(out, shown);
                painted += width;
            } else {
                painted += append_left_clipped(out, shown, left_clip);
            }
            bytes.append(out, "\\x1b[0m");
        }
        logical_column += width;
        offset = unit.end;
    }

    if (cursor_pos == end && logical_column >= hscroll && logical_column - hscroll <= content_cols) {
        frame.cursor_row = row;
        frame.cursor_col = GUTTER_WIDTH + 1 + (logical_column - hscroll);
        frame.cursor_visible = true;
    }
}
'''
new_render = '''const RENDER_CHUNK_BYTES: u64 = 4096;

fn render_window_end(start: u64, end: u64) -> u64 {
    var remaining = end - start;
    var primary = remaining;
    if (primary > RENDER_CHUNK_BYTES) { primary = RENDER_CHUNK_BYTES; }
    var lookahead = remaining - primary;
    if (lookahead > 3) { lookahead = 3; }
    return start + primary + lookahead;
}

fn render_line(
    out: []u8,
    editor: ref model.Editor,
    line_start: u64,
    line_number: u64,
    row: u64,
    cols: u64,
    hscroll: u64,
    frame: ref Frame
) {
    bytes.append(out, "\\x1b[2K");
    append_gutter(out, line_number);
    if (cols <= GUTTER_WIDTH) { return; }
    var content_cols = cols - GUTTER_WIDTH;
    var end = nav.line_end(editor.doc, line_start);
    var absolute = line_start;
    var logical_column: u64 = 0;
    var painted: u64 = 0;
    var cursor_pos = model.cursor(editor);
    var visual = model.visual_span(editor);
    var finished = false;

    while (absolute < end && !finished) {
        var remaining = end - absolute;
        var primary = remaining;
        if (primary > RENDER_CHUNK_BYTES) { primary = RENDER_CHUNK_BYTES; }
        var chunk = text.slice(editor.doc, absolute, render_window_end(absolute, end));
        var offset: u64 = 0;
        while (offset < primary) {
            var unit = display.next_unit(chunk, offset);
            var shown: []u8 = [];
            var width: u64 = 0;
            if (unit.kind is display.UnitKind.tab) {
                var tab = editor.tab_width;
                if (tab == 0) { tab = 4; }
                width = tab - (logical_column % tab);
            } else {
                shown = display.representation(chunk, unit);
                width = term.text_width(shown);
            }

            var document_pos = absolute + unit.start;
            if (cursor_pos == document_pos && logical_column >= hscroll && logical_column - hscroll <= content_cols) {
                frame.cursor_row = row;
                frame.cursor_col = GUTTER_WIDTH + 1 + (logical_column - hscroll);
                frame.cursor_visible = true;
            }

            if (logical_column + width > hscroll) {
                var left_clip: u64 = 0;
                if (logical_column < hscroll) { left_clip = hscroll - logical_column; }
                var visible_width = width - left_clip;
                if (painted + visible_width > content_cols) {
                    finished = true;
                    break;
                }
                append_unit_style(out, editor, unit, selected(visual, document_pos));
                if (unit.kind is display.UnitKind.tab) {
                    if (left_clip == 0) { painted += append_tab(out, logical_column, editor.tab_width); }
                    else { append_spaces(out, visible_width); painted += visible_width; }
                } else if (left_clip == 0) {
                    bytes.append(out, shown);
                    painted += width;
                } else {
                    painted += append_left_clipped(out, shown, left_clip);
                }
                bytes.append(out, "\\x1b[0m");
            }
            logical_column += width;
            offset = unit.end;
        }
        absolute += offset;
    }

    if (!finished && cursor_pos == end && logical_column >= hscroll && logical_column - hscroll <= content_cols) {
        frame.cursor_row = row;
        frame.cursor_col = GUTTER_WIDTH + 1 + (logical_column - hscroll);
        frame.cursor_visible = true;
    }
}
'''
once("tools/lace2/render.l", old_render, new_render, "streaming render line")

# Cross several 4KiB source pieces and streaming windows in normal navigation.
once(
    "tools/lace2/navigation_test.l",
    '''    // A terminating newline closes the final logical line. EOF after it must
''',
    '''    var long_data: []u8 = [];
    for (var i: u64 = 0; i < 10000; i += 1) { push(long_data, 'x'); }
    push(long_data, '\n');
    push(long_data, 'y');
    var long_doc = text.from_bytes(long_data);
    expect(nav.line_end(long_doc, 0) == 10000);
    expect(nav.line_start(long_doc, 9999) == 0);
    expect(nav.line_start(long_doc, 10001) == 10001);
    expect(nav.screen_column(long_doc, 0, 10000, 4) == 10000);
    expect(nav.offset_for_column(long_doc, 0, 8193, 4) == 8193);

    // A terminating newline closes the final logical line. EOF after it must
''',
    "long-line navigation regression",
)

# Rendering with a deep horizontal viewport must cross multiple bounded chunks
# while retaining cursor/cell geometry. The resulting frame remains terminal-
# sized even though the logical line is much larger.
once(
    "tools/lace2/render_test.l",
    '''    // Terminal chrome must never emit an unbounded status or message row.
''',
    '''    var long_line: []u8 = [];
    for (var i: u64 = 0; i < 20000; i += 1) { push(long_line, 'a'); }
    push(long_line, '\n');
    var long_editor = model.create(long_line);
    model.set_cursor(long_editor, 16384);
    var long_frame = render.draw(long_editor, "", "", 0, 1, 16380, 6, 20);
    expect(long_frame.cursor_visible);
    expect(long_frame.cursor_col == 11);
    expect(len(long_frame.bytes) < 1000);

    // Terminal chrome must never emit an unbounded status or message row.
''',
    "long-line rendering regression",
)
