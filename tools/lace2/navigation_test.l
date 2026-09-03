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

    var long_data: []u8 = [];
    for (var i: u64 = 0; i < 10000; i += 1) { push(long_data, 'x'); }
    push(long_data, '\n');
    push(long_data, 'y');
    var long_doc = text.from_bytes(long_data);
    expect(nav.line_end(long_doc, 0) == 10000);
    expect(nav.line_start(long_doc, 9999) == 0);
    expect(nav.line_start(long_doc, 10001) == 10001);
    expect(nav.screen_column(long_doc, 0, 10000, 4) == 10000);
    expect(nav.offset_for_column(long_doc, 0, 8193, 4) == 8193);

    // A valid UTF-8 atom may begin at the final byte of a 4 KiB streaming
    // window. The lookahead bytes must make it one display atom rather than
    // three invalid bytes, without double-counting it in the next chunk.
    var boundary: []u8 = [];
    for (var i: u64 = 0; i < 4095; i += 1) { push(boundary, 'a'); }
    push(boundary, 0xe2);
    push(boundary, 0x82);
    push(boundary, 0xac);
    push(boundary, 'z');
    push(boundary, '\n');
    var boundary_doc = text.from_bytes(boundary);
    expect(nav.screen_column(boundary_doc, 0, 4098, 4) == 4096);
    expect(nav.offset_for_column(boundary_doc, 0, 4095, 4) == 4095);
    expect(nav.offset_for_column(boundary_doc, 0, 4096, 4) == 4098);

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
