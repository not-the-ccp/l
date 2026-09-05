import bytes;
import strconv;
import terminal_ui;

fn csi_count(out: []u8, count: u64, final: u8) {
    if (count == 0) { return; }
    bytes.append(out, "\x1b[");
    bytes.append(out, strconv.format_u64(count));
    push(out, final);
}

// Style fragments are immutable protocol constants. Returning a const view
// avoids pretending callers may mutate a shared/static terminal sequence.
fn style(role: terminal_ui.Role) -> const []u8 {
    if (role == terminal_ui.Role.prompt_cwd) { return "\x1b[34m"; }
    if (role == terminal_ui.Role.prompt_status) { return "\x1b[31m"; }
    if (role == terminal_ui.Role.prompt_marker) { return "\x1b[2m"; }
    if (role == terminal_ui.Role.command) { return "\x1b[36m"; }
    if (role == terminal_ui.Role.quoted_argument) { return "\x1b[33m"; }
    if (role == terminal_ui.Role.pipe) { return "\x1b[35m"; }
    if (role == terminal_ui.Role.suggestion) { return "\x1b[2m"; }
    if (role == terminal_ui.Role.diagnostic) { return "\x1b[31m"; }
    return "\x1b[0m";
}

fn append_row(out: []u8, row: ref terminal_ui.Row, styled: bool) {
    for (atom in row.atoms) {
        if (styled) { bytes.append(out, style(atom.role)); }
        bytes.append(out, atom.text);
    }
    if (styled) { bytes.append(out, "\x1b[0m"); }
}

// Repaint only the shell-owned prompt block. We deliberately do not use the
// alternate screen so completed commands remain ordinary terminal scrollback.
pub fn repaint(view: terminal_ui.View, old_rows: u64, old_cursor_row: u64, styled: bool) -> []u8 {
    var out: []u8 = "\x1b[?25l\r";

    if (old_rows != 0) {
        csi_count(out, old_cursor_row, 'A');
        for (var i: u64 = 0; i < old_rows; i += 1) {
            bytes.append(out, "\x1b[2K");
            if (i + 1 < old_rows) { bytes.append(out, "\x1b[1B\r"); }
        }
        if (old_rows > 1) { csi_count(out, old_rows - 1, 'A'); }
        push(out, '\r');
    }

    for (var i: u64 = 0; i < len(view.rows); i += 1) {
        bytes.append(out, "\x1b[2K");
        append_row(out, view.rows[i], styled);
        if (i + 1 < len(view.rows)) { bytes.append(out, "\r\n"); }
    }

    if (len(view.rows) != 0) {
        var bottom = len(view.rows) - 1;
        if (bottom > view.cursor_row) { csi_count(out, bottom - view.cursor_row, 'A'); }
        push(out, '\r');
        csi_count(out, view.cursor_col, 'C');
    }
    bytes.append(out, "\x1b[?25h");
    return out;
}

// Move from the editing cursor to the end of the shell-owned block and commit
// it to scrollback before printing command output.
pub fn finish(rows: u64, cursor_row: u64) -> []u8 {
    var out: []u8 = "\x1b[0m";
    if (rows != 0 && rows - 1 > cursor_row) {
        csi_count(out, rows - 1 - cursor_row, 'B');
    }
    bytes.append(out, "\r\n");
    return out;
}

pub fn clear_screen() -> []u8 {
    return "\x1b[0m\x1b[2J\x1b[H";
}
