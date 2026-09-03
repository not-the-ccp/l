import bytes;
import tools.lace2.editor_model as model;
import tools.lace2.navigation as nav;
import tools.lace2.piece_tree as text;
import tools.lace2.selection as selection;
import tools.lace2.transaction as transaction;

fn line_indent(editor: ref model.Editor, pos: u64) -> []u8 {
    var start = nav.line_start(editor.doc, pos);
    var end = nav.line_end(editor.doc, pos);
    var cursor = start;
    while (cursor < end) {
        var value = text.byte_at(editor.doc, cursor);
        if (value != ' ' && value != '\t') { break; }
        cursor += 1;
    }
    return text.slice(editor.doc, start, cursor);
}

fn apply(editor: ref model.Editor, start: u64, end: u64, inserted: []u8, cursor: u64) {
    transaction.apply(editor.doc, [transaction.EditSpec {
        start: start,
        end: end,
        inserted: inserted,
    }]);
    editor.selections = selection.single(cursor);
    editor.pending_change = true;
    editor.goal_valid = false;
}

pub fn span(editor: ref model.Editor, count: u64) -> model.Span {
    var wanted = count;
    if (wanted == 0) { wanted = 1; }
    var start = nav.line_start(editor.doc, model.cursor(editor));
    var line = start;
    var end = start;
    var n: u64 = 0;
    var length = text.byte_len(editor.doc);
    while (n < wanted) {
        end = nav.line_end(editor.doc, line);
        if (end < length) { end += 1; }
        n += 1;
        if (n >= wanted || end >= length) { break; }
        line = end;
    }
    return model.Span { start: start, end: end };
}

pub fn change_lines(editor: ref model.Editor, count: u64) {
    var pos = model.cursor(editor);
    var whole = span(editor, count);
    var indent = line_indent(editor, pos);
    var replacement = bytes.clone(indent);

    editor.yank = text.slice(editor.doc, whole.start, whole.end);
    editor.yank_linewise = true;

    // A counted line change collapses the selected lines into exactly one
    // editable line. Preserve one terminating newline only when the selected
    // range had one, and preserve indentation from the first line.
    if (whole.end > whole.start && text.byte_at(editor.doc, whole.end - 1) == '\n') {
        push(replacement, '\n');
    }
    apply(editor, whole.start, whole.end, replacement, whole.start + len(indent));
    editor.mode = model.Mode.insert;
}

pub fn change_current_line(editor: ref model.Editor) {
    change_lines(editor, 1);
}

pub fn paste(editor: ref model.Editor, after: bool) {
    if (!editor.yank_linewise) {
        model.paste(editor, after);
        return;
    }
    if (len(editor.yank) == 0) { return; }

    var pos = model.cursor(editor);
    var line_start = nav.line_start(editor.doc, pos);
    var line_end = nav.line_end(editor.doc, pos);
    var document_end = text.byte_len(editor.doc);
    var inserted = bytes.clone(editor.yank);
    var insert_at = line_start;
    var cursor_after = line_start;

    if (after) {
        if (line_end < document_end) {
            insert_at = line_end + 1;
            cursor_after = insert_at;
        } else {
            insert_at = document_end;
            var with_boundary: []u8 = ['\n'];
            bytes.append(with_boundary, inserted);
            inserted = with_boundary;
            cursor_after = insert_at + 1;
        }
    } else {
        insert_at = line_start;
        cursor_after = insert_at;
        if (inserted[len(inserted) - 1] != '\n') { push(inserted, '\n'); }
    }

    apply(editor, insert_at, insert_at, inserted, cursor_after);
    model.commit_change(editor, "paste");
    editor.mode = model.Mode.normal;
}
