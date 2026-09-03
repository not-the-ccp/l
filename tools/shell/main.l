import byte_display;
import bytes;
import editor;
import history;
import linux.env as env;
import linux.fs as linux_fs;
import state;
import strconv;
import syntax;
import term;
import terminal_backend;
import terminal_ui;

struct Ui {
    editor: ref editor.Editor,
    history: ref history.History,
    shell: ref state.State,
    last_status: i64,
    painted_rows: u64,
    painted_cursor_row: u64,
    last_cols: u64,
    last_rows: u64,
    running: bool,
}

fn key_is(key: const []u8, value: u8) -> bool {
    return len(key) == 1 && key[0] == value;
}

fn seq(key: const []u8, value: const []u8) -> bool {
    return bytes.equal(key, value);
}

fn key_left(key: const []u8) -> bool {
    return seq(key, "\x1b[D") || seq(key, "\x1bOD");
}

fn key_right(key: const []u8) -> bool {
    return seq(key, "\x1b[C") || seq(key, "\x1bOC");
}

fn key_up(key: const []u8) -> bool {
    return seq(key, "\x1b[A") || seq(key, "\x1bOA");
}

fn key_down(key: const []u8) -> bool {
    return seq(key, "\x1b[B") || seq(key, "\x1bOB");
}

fn key_home(key: const []u8) -> bool {
    return seq(key, "\x1b[H") || seq(key, "\x1bOH") ||
        seq(key, "\x1b[1~") || seq(key, "\x1b[7~");
}

fn key_end(key: const []u8) -> bool {
    return seq(key, "\x1b[F") || seq(key, "\x1bOF") ||
        seq(key, "\x1b[4~") || seq(key, "\x1b[8~");
}

fn key_delete(key: const []u8) -> bool {
    return seq(key, "\x1b[3~");
}

fn cwd_or_empty() -> []u8 {
    match (linux_fs.cwd()) {
        some(path) { return path; }
        none { return []; }
    }
}

fn refresh_suggestion(ui: ref Ui) {
    ui.editor.suggestion = [];
    if (len(ui.editor.buffer) == 0 || ui.editor.cursor != len(ui.editor.buffer)) { return; }
    var cwd = cwd_or_empty();
    match (history.search(ui.history, ui.editor.buffer, cwd)) {
        none {}
        some(entry) {
            if (len(entry.command) > len(ui.editor.buffer) && bytes.starts_with(entry.command, ui.editor.buffer)) {
                editor.set_suggestion(ui.editor, entry.command);
            }
        }
    }
}

fn current_view(ui: ref Ui) -> terminal_ui.View {
    var cwd = linux_fs.cwd();
    var home = env.get("HOME");
    return terminal_ui.build(ui.editor, cwd, home, ui.last_status, term.cols());
}

fn redraw(ui: ref Ui) {
    refresh_suggestion(ui);
    var view = current_view(ui);
    term.write(terminal_backend.repaint(view, ui.painted_rows, ui.painted_cursor_row, true));
    ui.painted_rows = len(view.rows);
    ui.painted_cursor_row = view.cursor_row;
    ui.last_cols = term.cols();
    ui.last_rows = term.rows();
}

fn finish_prompt(ui: ref Ui) {
    term.write(terminal_backend.finish(ui.painted_rows, ui.painted_cursor_row));
    ui.painted_rows = 0;
    ui.painted_cursor_row = 0;
}

fn write_safe(data: const []u8) {
    if (len(data) == 0) { return; }
    term.write(terminal_ui.safe_scrollback(data));
}

fn write_line(data: const []u8) {
    write_safe(data);
    term.write("\r\n");
}

fn first_command_is(pipeline: syntax.Pipeline, name: const []u8) -> bool {
    return len(pipeline.commands) == 1 && len(pipeline.commands[0].words) != 0 &&
        bytes.equal(pipeline.commands[0].words[0].value, name);
}

fn exit_status(pipeline: syntax.Pipeline, fallback: i64) -> ?i64 {
    if (!first_command_is(pipeline, "exit")) { return none; }
    var words = pipeline.commands[0].words;
    if (len(words) == 1) { return some(fallback); }
    if (len(words) != 2) { return none; }
    return strconv.parse_i64(words[1].value);
}

fn execute(ui: ref Ui, pipeline: syntax.Pipeline) {
    var command_text = bytes.clone(ui.editor.buffer);
    var cwd_before = cwd_or_empty();
    finish_prompt(ui);

    if (first_command_is(pipeline, "exit")) {
        match (exit_status(pipeline, ui.last_status)) {
            some(code) {
                history.record(ui.history, command_text, cwd_before, code, 0);
                ui.last_status = code;
                ui.running = false;
                return;
            }
            none {
                write_line("lsh: usage: exit [status]");
                history.record(ui.history, command_text, cwd_before, 2, 0);
                ui.last_status = 2;
                editor.reset(ui.editor);
                return;
            }
        }
    }

    match (state.dispatch(ui.shell, pipeline)) {
        state.Dispatch.handled(result) {
            write_safe(result.output);
            match (result.error) {
                none {}
                some(problem) {
                    write_safe("lsh: ");
                    write_line(problem.message);
                }
            }
            ui.last_status = result.status;
        }
        state.Dispatch.external {
            // Do not fake foreground execution. Until linux.process.wait/group
            // and linux.tty foreground handoff are native and PTY-tested, an
            // interactive child could steal/read the terminal incorrectly.
            write_line("lsh: external commands are temporarily gated until foreground job control is available");
            ui.last_status = 125;
        }
    }
    history.record(ui.history, command_text, cwd_before, ui.last_status, 0);
    history.cancel_navigation(ui.history);
    editor.reset(ui.editor);
}

fn submit(ui: ref Ui) {
    match (editor.enter(ui.editor)) {
        editor.EnterResult.execute(pipeline) { execute(ui, pipeline); }
        editor.EnterResult.continued {}
        editor.EnterResult.invalid(_) {}
        editor.EnterResult.empty {
            finish_prompt(ui);
            editor.reset(ui.editor);
        }
    }
}

fn history_previous(ui: ref Ui) {
    match (history.previous(ui.history, ui.editor.buffer)) {
        none {}
        some(value) { editor.set_buffer(ui.editor, value); }
    }
}

fn history_next(ui: ref Ui) {
    match (history.next(ui.history)) {
        none {}
        some(value) { editor.set_buffer(ui.editor, value); }
    }
}

fn reverse_search(ui: ref Ui) {
    if (len(ui.editor.buffer) == 0) { return; }
    var cwd = cwd_or_empty();
    match (history.search(ui.history, ui.editor.buffer, cwd)) {
        none {}
        some(entry) { editor.set_buffer(ui.editor, entry.command); }
    }
}

fn cancel_line(ui: ref Ui) {
    finish_prompt(ui);
    write_line("^C");
    editor.reset(ui.editor);
    history.cancel_navigation(ui.history);
    ui.last_status = 130;
}

fn paste(ui: ref Ui) {
    while (true) {
        var next = term.read_key();
        match (next) {
            none { return; }
            some(value) {
                if (seq(value, "\x1b[201~")) { return; }
                // During bracketed paste every event is data, including escape
                // sequences and newlines. The parser/editor still sees exact
                // bytes; terminal_ui is responsible for safe presentation.
                editor.insert(ui.editor, value);
            }
        }
    }
}

fn handle_key(ui: ref Ui, key: []u8) {
    if (seq(key, "\x1b[200~")) { paste(ui); return; }
    if (key_is(key, '\r') || key_is(key, '\n')) { submit(ui); return; }
    if (key_is(key, 0x03)) { cancel_line(ui); return; } // Ctrl-C
    if (key_is(key, 0x04)) { // Ctrl-D
        if (len(ui.editor.buffer) == 0) {
            finish_prompt(ui);
            ui.running = false;
        } else {
            editor.delete_forward(ui.editor);
        }
        return;
    }
    if (key_is(key, 0x0c)) { // Ctrl-L
        term.write(terminal_backend.clear_screen());
        ui.painted_rows = 0;
        ui.painted_cursor_row = 0;
        return;
    }
    if (key_is(key, 0x01) || key_home(key)) { editor.move_home(ui.editor); return; } // Ctrl-A
    if (key_is(key, 0x05) || key_end(key)) { editor.move_end(ui.editor); return; }   // Ctrl-E
    if (key_is(key, 0x12)) { reverse_search(ui); return; } // Ctrl-R
    if (key_is(key, 0x06)) { // Ctrl-F: accept ghost text, otherwise move right.
        if (len(editor.suggestion_suffix(ui.editor)) != 0) { editor.accept_suggestion(ui.editor); }
        else { editor.move_right(ui.editor); }
        return;
    }
    if (key_is(key, '\t')) {
        editor.accept_suggestion_word(ui.editor);
        return;
    }
    if (key_is(key, 0x7f) || key_is(key, 0x08)) { editor.backspace(ui.editor); return; }
    if (key_delete(key)) { editor.delete_forward(ui.editor); return; }
    if (key_left(key)) { editor.move_left(ui.editor); return; }
    if (key_right(key)) {
        if (ui.editor.cursor == len(ui.editor.buffer) && len(editor.suggestion_suffix(ui.editor)) != 0) {
            editor.accept_suggestion(ui.editor);
        } else {
            editor.move_right(ui.editor);
        }
        return;
    }
    if (key_up(key)) { history_previous(ui); return; }
    if (key_down(key)) { history_next(ui); return; }

    // Escape sequences not recognized above are keys, not text. Ordinary byte
    // and UTF-8-scalar events from the host are inserted exactly.
    if (len(key) != 0 && key[0] != 0x1b && key[0] >= 0x20) {
        editor.insert(ui.editor, key);
        history.cancel_navigation(ui.history);
    }
}

fn run() -> i64 {
    var ui = new Ui {
        editor: editor.create(),
        history: history.create(),
        shell: state.create(),
        last_status: 0,
        painted_rows: 0,
        painted_cursor_row: 0,
        last_cols: term.cols(),
        last_rows: term.rows(),
        running: true,
    };

    term.enter_raw();
    term.write("\x1b[?2004h"); // bracketed paste
    while (ui.running) {
        redraw(ui);
        var key = term.read_key_timeout(150);
        match (key) {
            none {
                // Timeouts also make resize repaint deterministic without a
                // host-level SIGWINCH API.
                if (term.cols() != ui.last_cols || term.rows() != ui.last_rows) {
                    redraw(ui);
                }
            }
            some(value) { handle_key(ui, value); }
        }
    }
    term.write("\x1b[?2004l\x1b[0m\x1b[?25h");
    term.leave_raw();
    return ui.last_status;
}

pub fn main() -> i64 {
    return run();
}
