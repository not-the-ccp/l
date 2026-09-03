import tools.lace2.navigation as nav;
import tools.lace2.piece_tree as text;

fn expect(ok: bool) {
    if (!ok) { trap; }
}

fn main() {
    var doc = text.from_bytes(['a', 0xe2, 0x82, 0xac, 0xff, 'b', '\n', '\t', 'x', 'y', '\n', 'z']);

    expect(nav.next_atom(doc, 0) == 1);
    expect(nav.next_atom(doc, 1) == 4);
    expect(nav.next_atom(doc, 4) == 5);
    expect(nav.previous_atom(doc, 4) == 1);
    expect(nav.previous_atom(doc, 5) == 4);

    expect(nav.line_start(doc, 5) == 0);
    expect(nav.line_end(doc, 0) == 6);
    expect(nav.line_start(doc, 9) == 7);
    expect(nav.line_end(doc, 7) == 10);

    var next = nav.next_line_start(doc, 0);
    match (next) { none { trap; } some(value) { expect(value == 7); } }
    var previous = nav.previous_line_start(doc, 9);
    match (previous) { none { trap; } some(value) { expect(value == 0); } }

    expect(nav.first_nonblank(doc, 7) == 8);
    expect(nav.screen_column(doc, 7, 8, 4) == 4);
    expect(nav.offset_for_column(doc, 7, 4, 4) == 8);
    expect(nav.offset_for_column(doc, 7, 5, 4) == 9);

    var words = text.from_bytes("alpha + beta\n  gamma");
    expect(nav.word_forward(words, 0) == 6);
    expect(nav.word_forward(words, 6) == 8);
    expect(nav.word_backward(words, 12) == 8);
    expect(nav.word_end(words, 0) == 4);
    expect(nav.word_end(words, 5) == 6);

    // A terminating newline closes the final logical line. EOF after it must
    // not become another navigable line.
    var ended = text.from_bytes("one\ntwo\n");
    var length = text.byte_len(ended);
    expect(nav.line_start(ended, length) == 4);
    expect(nav.cursor_end(ended, length) == 6);
    var after_last = nav.next_line_start(ended, 4);
    match (after_last) { none { } some(_) { trap; } }

    // Consecutive terminating newlines still represent real empty lines; only
    // the insertion boundary after the final terminator is non-navigable.
    var blanks = text.from_bytes("\n\n");
    expect(nav.line_start(blanks, text.byte_len(blanks)) == 1);
    expect(nav.cursor_end(blanks, text.byte_len(blanks)) == 1);
}
