import bytes;
import tools.lace2.editor_model as model;
import tools.lace2.render as render;

fn expect(ok: bool) {
    if (!ok) { trap; }
}

fn main() {
    var editor = model.create(['A', 0x1b, '[', '2', 'J', 0xff, 'B', '\n']);
    var path: []u8 = ['b', 'a', 'd', 0x1b, '[', '2', 'J'];
    var message: []u8 = ['m', 's', 'g', 0x1b, '[', '2', 'J'];
    var frame = render.draw(editor, path, message, 0, 1, 0, 8, 80);

    expect(bytes.find(frame.bytes, "<FF>", 0) is some(_));
    expect(bytes.find(frame.bytes, "^[", 0) is some(_));
    expect(bytes.find(frame.bytes, "\x1b[2J", 0) is none);

    editor.unicode_guard = model.UnicodeGuard.all_non_ascii;
    var unicode_editor = model.create([0xd0, 0xb0]);
    unicode_editor.unicode_guard = model.UnicodeGuard.all_non_ascii;
    var guarded = render.draw(unicode_editor, "unicode", "", 0, 1, 0, 6, 40);
    expect(bytes.find(guarded.bytes, "\x1b[48;5;52m", 0) is some(_));


    // Horizontal scrolling may begin inside a multi-column atom. The
    // visible suffix must still occupy its logical cells so following
    // text and the terminal cursor agree on geometry.
    var tab_editor = model.create("\tX\n");
    tab_editor.tab_width = 4;
    model.set_cursor(tab_editor, 1);
    var tab_frame = render.draw(tab_editor, "", "", 0, 1, 2, 6, 20);
    expect(tab_frame.cursor_visible);
    expect(tab_frame.cursor_col == 9);
    expect(bytes.find(tab_frame.bytes, "  \x1b[0mX\x1b[0m", 0) is some(_));

    var escaped_editor = model.create([0xff, 'X', '\n']);
    model.set_cursor(escaped_editor, 1);
    var escaped_frame = render.draw(escaped_editor, "", "", 0, 1, 2, 6, 20);
    expect(escaped_frame.cursor_visible);
    expect(escaped_frame.cursor_col == 9);
    expect(bytes.find(escaped_frame.bytes, "F>\x1b[0mX\x1b[0m", 0) is some(_));

    var long_line: []u8 = [];
    for (var i: u64 = 0; i < 20000; i += 1) { push(long_line, 'a'); }
    push(long_line, '\n');
    var long_editor = model.create(long_line);
    model.set_cursor(long_editor, 16384);
    var long_frame = render.draw(long_editor, "", "", 0, 1, 16380, 6, 20);
    expect(long_frame.cursor_visible);
    expect(long_frame.cursor_col == 11);
    expect(len(long_frame.bytes) < 1000);

    var boundary_line: []u8 = [];
    for (var i: u64 = 0; i < 4095; i += 1) { push(boundary_line, 'a'); }
    push(boundary_line, 0xe2);
    push(boundary_line, 0x82);
    push(boundary_line, 0xac);
    push(boundary_line, 'z');
    push(boundary_line, '\n');
    var boundary_editor = model.create(boundary_line);
    model.set_cursor(boundary_editor, 4095);
    var boundary_frame = render.draw(boundary_editor, "", "", 0, 1, 4093, 6, 20);
    expect(boundary_frame.cursor_visible);
    expect(boundary_frame.cursor_col == 9);
    // The euro sign must be emitted as its original three UTF-8 bytes. If the
    // chunk boundary split it into invalid-byte escapes this sequence vanishes.
    expect(bytes.find(boundary_frame.bytes, [0xe2, 0x82, 0xac], 0) is some(_));

    // Terminal chrome must never emit an unbounded status or message row.
    // Before clipping, either of these strings wrapped into the editing area
    // on a narrow terminal and made the screen look corrupted.
    var narrow = model.create("x\n");
    var clipped = render.draw(
        narrow,
        "this/path/is/far/too/long/for/the/status/row",
        "this help or error message is also much too long for one row",
        0,
        1,
        0,
        5,
        18
    );
    expect(bytes.find(clipped.bytes, "this/path/is/far/too/long/for/the/status/row", 0) is none);
    expect(bytes.find(clipped.bytes, "this help or error message is also much too long for one row", 0) is none);
}
