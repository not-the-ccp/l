import bytes;
import tools.lace2.editor_model as model;
import tools.lace2.linewise as linewise;
import tools.lace2.piece_tree as text;

fn expect(ok: bool) {
    if (!ok) { trap; }
}

fn expect_bytes(actual: const []u8, expected: const []u8) {
    if (!bytes.equal(actual, expected)) { trap; }
}

fn main() {
    // cc preserves the line boundary and indentation instead of pulling the
    // following line upward.
    var changed = model.create("    alpha\n    beta\n");
    model.set_cursor(changed, 6);
    linewise.change_current_line(changed);
    expect(changed.mode is model.Mode.insert);
    expect_bytes(text.to_bytes(changed.doc), "    \n    beta\n");
    expect(model.cursor(changed) == 4);
    expect_bytes(changed.yank, "    alpha\n");
    model.insert_bytes(changed, "gamma");
    model.leave_insert(changed);
    expect_bytes(text.to_bytes(changed.doc), "    gamma\n    beta\n");
    model.undo(changed);
    expect_bytes(text.to_bytes(changed.doc), "    alpha\n    beta\n");

    // A linewise register from an unterminated final line remains a line when
    // pasted before another line.
    var before = model.create("one\ntwo");
    model.set_cursor(before, 5);
    model.yank_span(before, model.current_line_span(before), true);
    model.set_cursor(before, 0);
    linewise.paste(before, false);
    expect_bytes(text.to_bytes(before.doc), "two\none\ntwo");

    // Pasting after an unterminated final line introduces a boundary before
    // the linewise register rather than concatenating it with the current line.
    var after = model.create("one\ntwo");
    model.set_cursor(after, 0);
    model.yank_span(after, model.current_line_span(after), true);
    model.set_cursor(after, 5);
    linewise.paste(after, true);
    expect_bytes(text.to_bytes(after.doc), "one\ntwo\none\n");
}
