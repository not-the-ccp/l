import bytes;
import editor;
import terminal_backend;
import terminal_ui;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn contains(src: const []u8, needle: const []u8) -> bool {
    match (bytes.find(src, needle, 0)) {
        some(_) { return true; }
        none { return false; }
    }
}

fn main() -> i64 {
    var model = editor.create();
    editor.set_buffer(model, "printf \"hello world\" | wc -c");
    var view = terminal_ui.build(model, some("/tmp/work"), some("/tmp"), 7, 80);
    var plain = terminal_ui.plain(view);
    require(contains(plain, "~/work [7] › printf \"hello world\" | wc -c"));
    require(view.cursor_row == 0);
    require(view.cursor_col > 0);

    // Raw control bytes in cwd/input become visible text, never terminal
    // protocol. The backend may add its own trusted ANSI after this point.
    var hostile = editor.create();
    editor.set_buffer(hostile, ['e', 'c', 'h', 'o', ' ', 0x1b, '[', '2', 'J']);
    var hostile_view = terminal_ui.build(hostile, some(['/', 'x', 0x1b, '[', 'H']), none, 0, 80);
    var hostile_plain = terminal_ui.plain(hostile_view);
    require(contains(hostile_plain, "^["));
    require(!contains(hostile_plain, [0x1b, '[', '2', 'J']));
    require(!contains(hostile_plain, [0x1b, '[', 'H']));

    editor.set_buffer(model, "printf x |");
    match (editor.enter(model)) {
        editor.EnterResult.continued {}
        _ { trap; }
    }
    editor.insert(model, "wc -c");
    var multiline = terminal_ui.build(model, some("/tmp"), some("/tmp"), 0, 80);
    var multiline_plain = terminal_ui.plain(multiline);
    require(contains(multiline_plain, "~ › printf x |"));
    require(contains(multiline_plain, "… wc -c"));
    require(multiline.cursor_row >= 1);

    editor.set_buffer(model, "pri");
    editor.set_suggestion(model, "printf hello world");
    var suggested = terminal_ui.build(model, some("/"), none, 0, 80);
    require(contains(terminal_ui.plain(suggested), "pri"));
    require(contains(terminal_ui.plain(suggested), "ntf hello world"));

    // Narrow terminals wrap explicitly and still report an in-range cursor.
    var narrow = terminal_ui.build(model, some("/very/long/path"), none, 0, 12);
    require(len(narrow.rows) > 1);
    require(narrow.cursor_row < len(narrow.rows));
    require(narrow.cursor_col < 12);

    var safe = terminal_ui.safe_scrollback(['a', 0x1b, '[', '2', 'J', '\n', 0xff]);
    require(bytes.equal(safe, "a^[[2J\r\n<FF>"));

    var painted = terminal_backend.repaint(suggested, 0, 0, true);
    require(contains(painted, "\x1b[?25l"));
    require(contains(painted, "\x1b[?25h"));
    // Trusted renderer ANSI exists, but hostile source bytes were already
    // sanitized before reaching this layer.
    var hostile_painted = terminal_backend.repaint(hostile_view, 0, 0, true);
    require(contains(hostile_painted, "^["));
    require(!contains(hostile_painted, "\x1b[2J"));
    return 0;
}
