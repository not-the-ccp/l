from pathlib import Path

p = Path('tools/lace2/navigation_test.l')
s = p.read_text()
anchor = '''    // A terminating newline closes the final logical line. EOF after it must
'''
insert = '''    // A valid UTF-8 atom may begin at the final byte of a 4 KiB streaming
    // window. The lookahead bytes must make it one display atom rather than
    // three invalid bytes, without double-counting it in the next chunk.
    var boundary: []u8 = [];
    for (var i: u64 = 0; i < 4095; i += 1) { push(boundary, 'a'); }
    push(boundary, 0xe2);
    push(boundary, 0x82);
    push(boundary, 0xac);
    push(boundary, 'z');
    push(boundary, '\\n');
    var boundary_doc = text.from_bytes(boundary);
    expect(nav.screen_column(boundary_doc, 0, 4098, 4) == 4096);
    expect(nav.offset_for_column(boundary_doc, 0, 4095, 4) == 4095);
    expect(nav.offset_for_column(boundary_doc, 0, 4096, 4) == 4098);

    // A terminating newline closes the final logical line. EOF after it must
'''
if s.count(anchor) != 1:
    raise SystemExit('navigation boundary anchor changed')
p.write_text(s.replace(anchor, insert, 1))

p = Path('tools/lace2/render_test.l')
s = p.read_text()
anchor = '''    // Terminal chrome must never emit an unbounded status or message row.
'''
insert = '''    var boundary_line: []u8 = [];
    for (var i: u64 = 0; i < 4095; i += 1) { push(boundary_line, 'a'); }
    push(boundary_line, 0xe2);
    push(boundary_line, 0x82);
    push(boundary_line, 0xac);
    push(boundary_line, 'z');
    push(boundary_line, '\\n');
    var boundary_editor = model.create(boundary_line);
    model.set_cursor(boundary_editor, 4095);
    var boundary_frame = render.draw(boundary_editor, "", "", 0, 1, 4093, 6, 20);
    expect(boundary_frame.cursor_visible);
    expect(boundary_frame.cursor_col == 9);
    // The euro sign must be emitted as its original three UTF-8 bytes. If the
    // chunk boundary split it into invalid-byte escapes this sequence vanishes.
    expect(bytes.find(boundary_frame.bytes, [0xe2, 0x82, 0xac], 0) is some(_));

    // Terminal chrome must never emit an unbounded status or message row.
'''
if s.count(anchor) != 1:
    raise SystemExit('render boundary anchor changed')
p.write_text(s.replace(anchor, insert, 1))
