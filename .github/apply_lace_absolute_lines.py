from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    p = Path(path)
    source = p.read_text()
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, got {count}")
    p.write_text(source.replace(old, new, 1))


# Model: absolute line addressing is a distinct primitive from document-end
# movement. It clamps out-of-range line numbers to the last real line and
# always targets first-nonblank, matching G/gg semantics without changing the
# existing last-addressable-atom contract of move_document_end().
replace_once(
    "tools/lace2/editor_model.l",
    '''pub fn move_document_start(editor: ref Editor) {
    set_motion_cursor(editor, 0);
    editor.goal_valid = false;
}
''',
    '''fn absolute_line_start(editor: ref Editor, line_number: u64) -> u64 {
    var wanted = line_number;
    if (wanted == 0) { wanted = 1; }
    var start: u64 = 0;
    var line: u64 = 1;
    while (line < wanted) {
        match (nav.next_line_start(editor.doc, start)) {
            none { break; }
            some(value) {
                start = value;
                line += 1;
            }
        }
    }
    return start;
}

pub fn absolute_line_target(editor: ref Editor, line_number: u64) -> u64 {
    return nav.first_nonblank(editor.doc, absolute_line_start(editor, line_number));
}

pub fn move_absolute_line(editor: ref Editor, line_number: u64) {
    set_motion_cursor(editor, absolute_line_target(editor, line_number));
    editor.goal_valid = false;
}

pub fn line_span_to_absolute_line(editor: ref Editor, line_number: u64) -> Span {
    var current = nav.line_start(editor.doc, cursor(editor));
    var target = absolute_line_start(editor, line_number);
    var first = current;
    var last = target;
    if (last < first) {
        var swap = first;
        first = last;
        last = swap;
    }
    var end = nav.line_end(editor.doc, last);
    if (end < text.byte_len(editor.doc)) { end += 1; }
    return Span { start: first, end: end };
}

pub fn move_document_start(editor: ref Editor) {
    set_motion_cursor(editor, 0);
    editor.goal_valid = false;
}
''',
    "editor absolute-line primitives",
)

# Linewise change can now consume any already-resolved linewise span, including
# upward ranges from cgg. Counted cc/S keep using the same implementation.
replace_once(
    "tools/lace2/linewise.l",
    '''pub fn change_lines(editor: ref model.Editor, count: u64) {
    var pos = model.cursor(editor);
    var whole = model.line_count_span(editor, count);
    var indent = line_indent(editor, pos);
    var content_end = whole.end;
    if (content_end > whole.start && text.byte_at(editor.doc, content_end - 1) == '\\n') {
        content_end -= 1;
    }

    editor.yank = text.slice(editor.doc, whole.start, whole.end);
    editor.yank_linewise = true;

    // Preserve one line boundary for the insertion line, even when a
    // counted change consumes several source lines.
    apply(editor, whole.start, content_end, indent, whole.start + len(indent));
    editor.mode = model.Mode.insert;
}
''',
    '''pub fn change_span(editor: ref model.Editor, whole: model.Span) {
    if (whole.start > whole.end || whole.end > text.byte_len(editor.doc)) { trap; }
    var indent = line_indent(editor, whole.start);
    var content_end = whole.end;
    if (content_end > whole.start && text.byte_at(editor.doc, content_end - 1) == '\\n') {
        content_end -= 1;
    }

    editor.yank = text.slice(editor.doc, whole.start, whole.end);
    editor.yank_linewise = true;

    // Preserve one line boundary for the insertion line, even when the
    // resolved linewise motion spans upward or consumes several source lines.
    apply(editor, whole.start, content_end, indent, whole.start + len(indent));
    editor.mode = model.Mode.insert;
}

pub fn change_lines(editor: ref model.Editor, count: u64) {
    change_span(editor, model.line_count_span(editor, count));
}
''',
    "linewise arbitrary span change",
)

# Preserve whether a count was typed; plain G and 1G have different meanings.
replace_once(
    "tools/lace2/main.l",
    '''struct CountKey {
    count: u64,
    key: []u8,
}
''',
    '''struct CountKey {
    count: u64,
    key: []u8,
    explicit: bool,
}
''',
    "CountKey explicit flag",
)
replace_once(
    "tools/lace2/main.l",
    '''fn read_count(first: []u8) -> CountKey {
    if (len(first) != 1 || first[0] < '1' || first[0] > '9') {
        return CountKey { count: 1, key: first };
    }
''',
    '''fn read_count(first: []u8) -> CountKey {
    if (len(first) != 1 || first[0] < '1' || first[0] > '9') {
        return CountKey { count: 1, key: first, explicit: false };
    }
''',
    "read_count default explicit",
)
replace_once(
    "tools/lace2/main.l",
    '''            none { return CountKey { count: count, key: [] }; }
''',
    '''            none { return CountKey { count: count, key: [], explicit: true }; }
''',
    "read_count eof explicit",
)
replace_once(
    "tools/lace2/main.l",
    '''                    return CountKey { count: count, key: next };
''',
    '''                    return CountKey { count: count, key: next, explicit: true };
''',
    "read_count parsed explicit",
)

replace_once(
    "tools/lace2/main.l",
    '''fn do_motion(ui: ref Ui, key: []u8, count: u64) -> bool {
    if (key_is(key, 'h') || key_left(key)) { model.move_left(ui.editor, count); return true; }
    if (key_is(key, 'l') || key_right(key)) { model.move_right(ui.editor, count); return true; }
    if (key_is(key, 'j') || key_down(key)) { model.move_vertical(ui.editor, true, count); return true; }
    if (key_is(key, 'k') || key_up(key)) { model.move_vertical(ui.editor, false, count); return true; }
    if (key_is(key, 'w')) { model.move_word_forward(ui.editor, count); return true; }
    if (key_is(key, 'b')) { model.move_word_backward(ui.editor, count); return true; }
    if (key_is(key, 'e')) { model.move_word_end(ui.editor, count); return true; }
    if (key_is(key, '0') || key_home(key)) { model.move_line_start(ui.editor, false); return true; }
    if (key_is(key, '^')) { model.move_line_start(ui.editor, true); return true; }
    if (key_is(key, '$') || key_end(key)) { model.move_line_end(ui.editor); return true; }
    if (key_is(key, 'G')) { model.move_document_end(ui.editor); return true; }
    return false;
}
''',
    '''fn do_motion(ui: ref Ui, key: []u8, count: u64, count_explicit: bool) -> bool {
    if (key_is(key, 'h') || key_left(key)) { model.move_left(ui.editor, count); return true; }
    if (key_is(key, 'l') || key_right(key)) { model.move_right(ui.editor, count); return true; }
    if (key_is(key, 'j') || key_down(key)) { model.move_vertical(ui.editor, true, count); return true; }
    if (key_is(key, 'k') || key_up(key)) { model.move_vertical(ui.editor, false, count); return true; }
    if (key_is(key, 'w')) { model.move_word_forward(ui.editor, count); return true; }
    if (key_is(key, 'b')) { model.move_word_backward(ui.editor, count); return true; }
    if (key_is(key, 'e')) { model.move_word_end(ui.editor, count); return true; }
    if (key_is(key, '0') || key_home(key)) { model.move_line_start(ui.editor, false); return true; }
    if (key_is(key, '^')) { model.move_line_start(ui.editor, true); return true; }
    if (key_is(key, '$') || key_end(key)) { model.move_line_end(ui.editor); return true; }
    if (key_is(key, 'G')) {
        var target = count;
        if (!count_explicit) { target = 0xffffffffffffffff; }
        model.move_absolute_line(ui.editor, target);
        return true;
    }
    return false;
}

fn do_g_motion(ui: ref Ui, count: u64) -> bool {
    var second_opt = term.read_key();
    match (second_opt) {
        none { return false; }
        some(second) {
            if (!key_is(second, 'g')) { return false; }
            model.move_absolute_line(ui.editor, count);
            return true;
        }
    }
}
''',
    "absolute motion dispatch",
)

# Operator grammar: G and gg are linewise absolute motions. A count before the
# operator and a count before the motion multiply. Only G needs to distinguish
# an omitted count, because plain dG means through the last line.
replace_once(
    "tools/lace2/main.l",
    '''fn operator_command(ui: ref Ui, op: u8, prefix_count: u64) {
''',
    '''fn operator_command(ui: ref Ui, op: u8, prefix_count: u64, prefix_explicit: bool) {
''',
    "operator explicit prefix signature",
)
replace_once(
    "tools/lace2/main.l",
    '''            if (key_is(parsed.key, op)) {
                span_opt = some(model.line_count_span(ui.editor, count));
                is_linewise = true;
            } else if (len(parsed.key) == 1) {
                if (op == 'c') {
                    span_opt = model.change_motion_span(ui.editor, parsed.key[0], count);
                } else {
                    span_opt = model.motion_span_count(ui.editor, parsed.key[0], count);
                }
            }
''',
    '''            if (key_is(parsed.key, op)) {
                span_opt = some(model.line_count_span(ui.editor, count));
                is_linewise = true;
            } else if (key_is(parsed.key, 'G')) {
                var target = count;
                if (!prefix_explicit && !parsed.explicit) { target = 0xffffffffffffffff; }
                span_opt = some(model.line_span_to_absolute_line(ui.editor, target));
                is_linewise = true;
            } else if (key_is(parsed.key, 'g')) {
                var third_opt = term.read_key();
                match (third_opt) {
                    none {}
                    some(third) {
                        if (key_is(third, 'g')) {
                            span_opt = some(model.line_span_to_absolute_line(ui.editor, count));
                            is_linewise = true;
                        }
                    }
                }
            } else if (len(parsed.key) == 1) {
                if (op == 'c') {
                    span_opt = model.change_motion_span(ui.editor, parsed.key[0], count);
                } else {
                    span_opt = model.motion_span_count(ui.editor, parsed.key[0], count);
                }
            }
''',
    "operator absolute motions",
)
replace_once(
    "tools/lace2/main.l",
    '''                    } else if (op == 'c' && is_linewise) {
                        linewise.change_lines(ui.editor, count);
''',
    '''                    } else if (op == 'c' && is_linewise) {
                        linewise.change_span(ui.editor, span);
''',
    "operator arbitrary linewise change",
)

replace_once(
    "tools/lace2/main.l",
    '''fn visual_command(ui: ref Ui, key: []u8, count: u64) {
    if (do_motion(ui, key, count)) { return; }
''',
    '''fn visual_command(ui: ref Ui, key: []u8, count: u64, count_explicit: bool) {
    if (do_motion(ui, key, count, count_explicit)) { return; }
    if (key_is(key, 'g')) { do_g_motion(ui, count); return; }
''',
    "visual absolute motions",
)

replace_once(
    "tools/lace2/main.l",
    '''    if (do_motion(ui, key, count)) { return; }
''',
    '''    if (do_motion(ui, key, count, parsed.explicit)) { return; }
''',
    "normal do_motion explicit",
)
replace_once(
    "tools/lace2/main.l",
    '''    if (key_is(key, 'g')) {
        var second_opt = term.read_key();
        match (second_opt) {
            none { return; }
            some(second) { if (key_is(second, 'g')) { model.move_document_start(ui.editor); } }
        }
        return;
    }
''',
    '''    if (key_is(key, 'g')) { do_g_motion(ui, count); return; }
''',
    "normal gg dispatch",
)
replace_once(
    "tools/lace2/main.l",
    '''    if (key_is(key, 'd') || key_is(key, 'y') || key_is(key, 'c')) { operator_command(ui, key[0], count); return; }
''',
    '''    if (key_is(key, 'd') || key_is(key, 'y') || key_is(key, 'c')) { operator_command(ui, key[0], count, parsed.explicit); return; }
''',
    "normal operator explicit",
)
replace_once(
    "tools/lace2/main.l",
    '''                    visual_command(ui, parsed.key, parsed.count);
''',
    '''                    visual_command(ui, parsed.key, parsed.count, parsed.explicit);
''',
    "visual parsed explicit call",
)
replace_once(
    "tools/lace2/main.l",
    '''set_message(ui, "i/a/o edit · hjkl/arrows/wbe move · d/y/c ops · v/V select · / search · :w :q · ^VxFF raw byte");''',
    '''set_message(ui, "i/a/o edit · hjkl/arrows/wbe/G/gg move · d/y/c ops · v/V select · / search · :w :q · ^VxFF raw byte");''',
    "help absolute motions",
)

# Model-level tests pin clamping, first-nonblank destinations, linewise range
# construction in both directions, and the no-phantom-final-line invariant.
replace_once(
    "tools/lace2/editor_model_test.l",
    '''fn main() {
''',
    '''fn test_absolute_line_motions() {
    var editor = model.create("  one\\n\\ttwo\\nthree\\n");
    model.move_absolute_line(editor, 2);
    expect(model.cursor(editor) == 7);
    model.move_absolute_line(editor, 0xffffffffffffffff);
    expect(model.cursor(editor) == 11);
    model.move_absolute_line(editor, 1);
    expect(model.cursor(editor) == 2);

    model.move_absolute_line(editor, 2);
    var upward = model.line_span_to_absolute_line(editor, 1);
    expect(upward.start == 0 && upward.end == 11);
    var downward = model.line_span_to_absolute_line(editor, 3);
    expect(downward.start == 6 && downward.end == 17);

    var final_newline = model.create("one\\ntwo\\n");
    model.move_absolute_line(final_newline, 999);
    expect(model.cursor(final_newline) == 4);
}

fn main() {
''',
    "editor absolute motion tests",
)
replace_once(
    "tools/lace2/editor_model_test.l",
    '''    test_final_newline_is_not_a_phantom_line();
}''',
    '''    test_final_newline_is_not_a_phantom_line();
    test_absolute_line_motions();
}''',
    "editor absolute motion test call",
)

# PTY coverage tests the actual count parser/operator grammar, not just model
# helpers. It also guards characterwise Visual mode against accidental linewise
# conversion when G/gg move the selection head.
replace_once(
    "tests/lace_operator_pty.py",
    '''        # Counted yanks use the same range grammar.
''',
    '''        # Absolute line motions distinguish omitted counts from explicit
        # counts: G means last line, while 1G means line one. gg defaults to one.
        case(root, "G-dd.txt", b"1\\n2\\n3\\n", b"Gdd", b"1\\n2\\n")
        case(root, "1G-dd.txt", b"1\\n2\\n3\\n", b"G1Gdd", b"2\\n3\\n")
        case(root, "gg-dd.txt", b"1\\n2\\n3\\n", b"Gggdd", b"2\\n3\\n")
        case(root, "2gg-dd.txt", b"1\\n2\\n3\\n", b"G2ggdd", b"1\\n3\\n")

        # G/gg are linewise operator motions. Counts on both sides multiply,
        # and upward ranges include both the current and target lines.
        case(root, "dG.txt", b"1\\n2\\n3\\n4\\n", b"2GdG", b"1\\n")
        case(root, "d2G.txt", b"1\\n2\\n3\\n4\\n5\\n", b"4Gd2G", b"1\\n5\\n")
        case(root, "2d2G.txt", b"1\\n2\\n3\\n4\\n5\\n6\\n", b"3G2d2G", b"1\\n2\\n5\\n6\\n")
        case(root, "dgg.txt", b"1\\n2\\n3\\n4\\n5\\n", b"4Gdgg", b"5\\n")
        case(root, "d2gg.txt", b"1\\n2\\n3\\n4\\n5\\n", b"4Gd2gg", b"1\\n5\\n")

        # Linewise change uses the resolved absolute span, so upward cgg is not
        # approximated as a downward counted cc.
        case(root, "cG.txt", b"  one\\n    two\\nthree\\n", b"2GcGX\\x1b", b"  one\\n    X\\n")
        case(root, "cgg.txt", b"  one\\n    two\\nthree\\n", b"2GcggX\\x1b", b"  X\\nthree\\n")

        # Existing characterwise Visual mode stays characterwise: the absolute
        # motion only moves the head to first-nonblank on the target line.
        case(root, "visual-G.txt", b"aa\\nbb\\ncc\\n", b"jvGd", b"aa\\nc\\n")
        case(root, "visual-gg.txt", b"aa\\nbb\\ncc\\n", b"jvggd", b"a\\ncc\\n")

        # Counted yanks use the same range grammar.
''',
    "operator PTY absolute line cases",
)
