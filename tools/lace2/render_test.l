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
}
