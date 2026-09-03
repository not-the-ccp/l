import bytes;
import tools.lace2.editor_model as model;
import tools.lace2.piece_tree as text;

fn expect(ok: bool) {
    if (!ok) { trap; }
}

fn expect_bytes(actual: []u8, expected: []u8) {
    if (!bytes.equal(actual, expected)) { trap; }
}

fn test_insert_undo_group() {
    var editor = model.create("abc\n");
    model.enter_insert(editor, 1);
    model.insert_bytes(editor, "XY");
    model.insert_byte(editor, 0xff);
    model.backspace(editor);
    model.leave_insert(editor);
    expect_bytes(text.to_bytes(editor.doc), "aXYbc\n");
    expect(model.dirty(editor));

    model.undo(editor);
    expect_bytes(text.to_bytes(editor.doc), "abc\n");
    expect(!model.dirty(editor));
    model.redo(editor);
    expect_bytes(text.to_bytes(editor.doc), "aXYbc\n");
}

fn test_unicode_atomic_delete() {
    var editor = model.create(['a', 0xe2, 0x82, 0xac, 0xff, 'b']);
    model.set_cursor(editor, 1);
    model.delete_forward(editor, 1);
    expect_bytes(text.to_bytes(editor.doc), ['a', 0xff, 'b']);
    model.delete_forward(editor, 1);
    expect_bytes(text.to_bytes(editor.doc), "ab");
}

fn test_linewise_delete_paste() {
    var editor = model.create("one\ntwo\nthree\n");
    model.set_cursor(editor, 5);
    var span = model.current_line_span(editor);
    model.delete_span(editor, span, true, false);
    expect_bytes(text.to_bytes(editor.doc), "one\nthree\n");
    expect(editor.yank_linewise);
    expect_bytes(editor.yank, "two\n");
    model.paste(editor, true);
    expect_bytes(text.to_bytes(editor.doc), "one\nthree\ntwo\n");
}

fn test_visual_ranges() {
    var editor = model.create("alpha beta\ngamma\n");
    model.set_cursor(editor, 1);
    model.enter_visual(editor, false);
    model.set_cursor(editor, 4);
    var span_opt = model.visual_span(editor);
    match (span_opt) {
        none { trap; }
        some(span) { expect_bytes(text.slice(editor.doc, span.start, span.end), "lpha"); }
    }

    model.leave_visual(editor);
    model.set_cursor(editor, 7);
    model.enter_visual(editor, true);
    model.set_cursor(editor, 13);
    span_opt = model.visual_span(editor);
    match (span_opt) {
        none { trap; }
        some(span) { expect_bytes(text.slice(editor.doc, span.start, span.end), "alpha beta\ngamma\n"); }
    }
}

fn test_open_line_indent() {
    var editor = model.create("    first\n    second\n");
    model.set_cursor(editor, 5);
    model.open_line(editor, true);
    model.insert_bytes(editor, "middle");
    model.leave_insert(editor);
    expect_bytes(text.to_bytes(editor.doc), "    first\n    middle\n    second\n");
}

fn test_motion_spans_and_search() {
    var editor = model.create("alpha + beta alpha\n");
    model.set_cursor(editor, 0);
    var span_opt = model.motion_span(editor, 'w');
    match (span_opt) { none { trap; } some(span) { expect(span.start == 0 && span.end == 6); } }

    var found = model.find_forward(editor, "alpha", 1);
    match (found) { none { trap; } some(pos) { expect(pos == 13); } }
    var previous = model.find_backward(editor, "alpha", 13);
    match (previous) { none { trap; } some(pos) { expect(pos == 0); } }
}

fn test_saved_state() {
    var editor = model.create("x");
    expect(!model.dirty(editor));
    model.enter_insert(editor, 1);
    model.insert_bytes(editor, "y");
    expect(model.dirty(editor));
    model.leave_insert(editor);
    model.mark_saved(editor);
    expect(!model.dirty(editor));
    model.undo(editor);
    expect(model.dirty(editor));
}

fn main() {
    test_insert_undo_group();
    test_unicode_atomic_delete();
    test_linewise_delete_paste();
    test_visual_ranges();
    test_open_line_indent();
    test_motion_spans_and_search();
    test_saved_state();
}
