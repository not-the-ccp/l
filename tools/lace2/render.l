import bytes;
import strconv;
import term;
import byte_display as display;
import tools.lace2.editor_model as model;
import tools.lace2.navigation as nav;
import tools.lace2.piece_tree as text;

const GUTTER_WIDTH: u64 = 6;

pub struct Frame {
    pub bytes: []u8,
    pub cursor_row: u64,
    pub cursor_col: u64,
    pub cursor_visible: bool,
    pub last_line_start: u64,
}

fn append_spaces(out: []u8, count: u64) {
    for (var i: u64 = 0; i < count; i += 1) { push(out, ' '); }
}

fn safe_inline(value: []u8) -> []u8 {
    var out: []u8 = [];
    var offset: u64 = 0;
    while (offset < len(value)) {
        var unit = display.next_unit(value, offset);
        bytes.append(out, display.representation(value, unit));
        offset = unit.end;
    }
    return out;
}

// Append complete display atoms only while they fit on this terminal row.
// Status/message text used to be written unbounded, so a long path or :help
// wrapped into the buffer and visually corrupted the screen.
fn append_fitted(out: []u8, value: []u8, max_columns: u64) -> u64 {
    var offset: u64 = 0;
    var columns: u64 = 0;
    while (offset < len(value)) {
        var unit = display.next_unit(value, offset);
        var shown = display.representation(value, unit);
        var width = term.text_width(shown);
        if (columns + width > max_columns) { break; }
        bytes.append(out, shown);
        columns += width;
        offset = unit.end;
    }
    return columns;
}

fn append_move(out: []u8, row: u64, col: u64) {
    bytes.append(out, "\x1b[");
    strconv.append_u64(out, row);
    push(out, ';');
    strconv.append_u64(out, col);
    push(out, 'H');
}

fn append_gutter(out: []u8, line_number: u64) {
    var digits = strconv.format_u64(line_number);
    bytes.append(out, "\x1b[2m");
    if (len(digits) + 1 < GUTTER_WIDTH) { append_spaces(out, GUTTER_WIDTH - len(digits) - 1); }
    bytes.append(out, digits);
    push(out, ' ');
    bytes.append(out, "\x1b[0m");
}

fn mode_name(editor: ref model.Editor) -> []u8 {
    if (editor.mode is model.Mode.insert) { return "INSERT"; }
    if (editor.mode is model.Mode.visual) { return "VISUAL"; }
    if (editor.mode is model.Mode.visual_line) { return "V-LINE"; }
    return "NORMAL";
}

fn selected(span_opt: ?model.Span, pos: u64) -> bool {
    match (span_opt) {
        none { return false; }
        some(span) { return pos >= span.start && pos < span.end; }
    }
}

fn append_unit_style(out: []u8, editor: ref model.Editor, unit: display.Unit, is_selected: bool) {
    if (is_selected) { bytes.append(out, "\x1b[7m"); }
    if (unit.kind is display.UnitKind.invalid_byte || unit.kind is display.UnitKind.control || unit.kind is display.UnitKind.unicode_control) {
        bytes.append(out, "\x1b[48;5;52m\x1b[38;5;231m");
        return;
    }
    if (editor.unicode_guard is model.UnicodeGuard.all_non_ascii && unit.codepoint >= 0x80) {
        bytes.append(out, "\x1b[48;5;52m\x1b[38;5;231m");
    }
}

fn append_tab(out: []u8, column: u64, tab_width: u64) -> u64 {
    var width = tab_width;
    if (width == 0) { width = 4; }
    var advance = width - (column % width);
    append_spaces(out, advance);
    return advance;
}

// Render the visible suffix of a safe representation when horizontal
// scrolling begins inside one display atom. ASCII representations can
// be clipped exactly; if the cut lands inside a wide scalar, reserve
// its remaining cells with spaces because a terminal cannot draw half
// a glyph.
fn append_left_clipped(out: []u8, shown: const []u8, clip_columns: u64) -> u64 {
    var offset: u64 = 0;
    var skipped: u64 = 0;
    var painted: u64 = 0;
    while (offset < len(shown)) {
        var unit = display.next_unit(shown, offset);
        var representation = display.representation(shown, unit);
        var width = term.text_width(representation);
        if (skipped + width <= clip_columns) {
            skipped += width;
            offset = unit.end;
            continue;
        }
        if (skipped < clip_columns) {
            var clipped = clip_columns - skipped;
            append_spaces(out, width - clipped);
            painted += width - clipped;
        } else {
            bytes.append(out, representation);
            painted += width;
        }
        skipped += width;
        offset = unit.end;
    }
    return painted;
}

const RENDER_CHUNK_BYTES: u64 = 4096;

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
    bytes.append(out, "\x1b[2K");
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
                bytes.append(out, "\x1b[0m");
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

fn append_status(out: []u8, editor: ref model.Editor, path: []u8, cols: u64) {
    var status: []u8 = [' '];
    bytes.append(status, mode_name(editor));
    bytes.append(status, "  ");
    if (model.dirty(editor)) { bytes.append(status, "[+] "); }
    bytes.append(status, safe_inline(path));
    bytes.append(status, "  byte ");
    bytes.append(status, strconv.format_u64(model.cursor(editor)));

    bytes.append(out, "\x1b[2K\x1b[7m");
    var visible = append_fitted(out, status, cols);
    if (visible < cols) { append_spaces(out, cols - visible); }
    bytes.append(out, "\x1b[0m");
}

pub fn draw(
    editor: ref model.Editor,
    path: []u8,
    message: []u8,
    top_start: u64,
    top_line_number: u64,
    hscroll: u64,
    rows: u64,
    cols: u64
) -> Frame {
    var frame = new Frame {
        bytes: [],
        cursor_row: 1,
        cursor_col: 1,
        cursor_visible: false,
        last_line_start: top_start,
    };
    var out = frame.bytes;
    bytes.append(out, "\x1b[?25l\x1b[H");

    var content_rows: u64 = 0;
    if (rows > 2) { content_rows = rows - 2; }
    var line_start = top_start;
    var line_number = top_line_number;
    var row: u64 = 1;
    while (row <= content_rows) {
        render_line(out, editor, line_start, line_number, row, cols, hscroll, frame);
        frame.last_line_start = line_start;
        if (row < content_rows) { bytes.append(out, "\r\n"); }
        var next = nav.next_line_start(editor.doc, line_start);
        match (next) {
            none {
                row += 1;
                while (row <= content_rows) {
                    bytes.append(out, "\r\n\x1b[2K");
                    bytes.append(out, "\x1b[2m     ~\x1b[0m");
                    row += 1;
                }
                break;
            }
            some(value) {
                line_start = value;
                line_number += 1;
            }
        }
        row += 1;
    }

    if (rows >= 2) {
        append_move(out, rows - 1, 1);
        append_status(out, editor, path, cols);
        append_move(out, rows, 1);
        bytes.append(out, "\x1b[2K");
        var safe_message = safe_inline(message);
        append_fitted(out, safe_message, cols);
    }

    if (frame.cursor_visible) {
        append_move(out, frame.cursor_row, frame.cursor_col);
        bytes.append(out, "\x1b[?25h");
    }
    return *frame;
}