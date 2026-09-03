import byte_display;
import bytes;
import editor;
import executor;
import history;
import job_control;
import linux.env as env;
import linux.fd as fd;
import linux.fs as linux_fs;
import linux.process as process;
import linux.process.group as groups;
import linux.tty as tty;
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
    job_table: ref job_control.Table,
    tty_input: fd.Fd,
    shell_group: process.Group,
    shell_mode: tty.Mode,
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

fn tty_ok(result: ?i64) -> bool {
    match (result) {
        none { return true; }
        some(_) { return false; }
    }
}

fn enable_editor_terminal(ui: ref Ui) -> bool {
    if (!tty_ok(tty.set_foreground(ui.tty_input, ui.shell_group))) {
        ui.running = false;
        return false;
    }
    if (!tty_ok(tty.restore(ui.tty_input, ui.shell_mode))) {
        ui.running = false;
        return false;
    }
    term.enter_raw();
    term.write("\x1b[?2004h");
    return true;
}

fn disable_editor_terminal(ui: ref Ui) {
    term.write("\x1b[?2004l\x1b[0m\x1b[?25h");
    term.leave_raw();
    // term.leave_raw restores the mode saved by enter_raw. Keep the explicit
    // snapshot authoritative as well so a previous child cannot become the
    // baseline if it stopped after changing termios.
    tty.restore(ui.tty_input, ui.shell_mode);
}

fn save_stopped_tty(ui: ref Ui, job: ref job_control.Job) {
    match (tty.capture(ui.tty_input)) {
        some(mode) { job_control.save_tty_mode(job, mode); }
        none {}
    }
}

fn announce_job(job: ref job_control.Job, label: const []u8) {
    write_safe("[");
    write_safe(strconv.format_u64(job.id));
    write_safe("] ");
    write_safe(label);
    write_safe(" ");
    write_line(job.command);
}

fn run_foreground(ui: ref Ui, job: ref job_control.Job, resume: bool) -> i64 {
    disable_editor_terminal(ui);

    if (resume) {
        match (job.tty_mode) {
            some(mode) {
                if (!tty_ok(tty.restore(ui.tty_input, mode))) {
                    enable_editor_terminal(ui);
                    write_line("lsh: fg: could not restore job terminal mode");
                    return 125;
                }
            }
            none {}
        }
    }

    if (!tty_ok(tty.set_foreground(ui.tty_input, job.group))) {
        process.send_group(job.group, process.sigkill());
        job_control.wait_foreground(job);
        enable_editor_terminal(ui);
        write_line("lsh: could not give terminal to foreground job");
        return 125;
    }

    if (resume) {
        match (job_control.continue_job(job)) {
            some(_) {
                tty.set_foreground(ui.tty_input, ui.shell_group);
                enable_editor_terminal(ui);
                write_line("lsh: fg: could not continue job");
                return 125;
            }
            none {}
        }
    }

    var result = job_control.wait_foreground(job);

    // Reclaim first. The tty still contains the child's attributes here, which
    // lets us save a stopped full-screen program's mode before restoring ours.
    if (!tty_ok(tty.set_foreground(ui.tty_input, ui.shell_group))) {
        ui.running = false;
        return 125;
    }

    match (result) {
        job_control.WaitResult.stopped(number) {
            save_stopped_tty(ui, job);
            tty.restore(ui.tty_input, ui.shell_mode);
            term.enter_raw();
            term.write("\x1b[?2004h");
            var id = job_control.store(ui.job_table, job);
            write_safe("[");
            write_safe(strconv.format_u64(id));
            write_safe("] Stopped ");
            write_line(job.command);
            return 128 + number;
        }
        job_control.WaitResult.done(status) {
            tty.restore(ui.tty_input, ui.shell_mode);
            term.enter_raw();
            term.write("\x1b[?2004h");
            job_control.prune_done(ui.job_table);
            return status;
        }
    }
}

fn external(ui: ref Ui, pipeline: syntax.Pipeline, command_text: const []u8) -> i64 {
    match (executor.launch(pipeline)) {
        executor.LaunchResult.invalid(message) {
            write_safe("lsh: ");
            write_line(message);
            return 127;
        }
        executor.LaunchResult.launch_failed(failure) {
            write_safe("lsh: could not launch ");
            write_safe(failure.command);
            write_safe(" (errno ");
            write_safe(strconv.format_i64(failure.error_number));
            write_line(")");
            return 126;
        }
        executor.LaunchResult.ok(live) {
            match (job_control.from_live(live, command_text)) {
                none {
                    write_line("lsh: executor returned a foreground job without a process group");
                    return 125;
                }
                some(job) {
                    return run_foreground(ui, job, false);
                }
            }
        }
    }
}

fn selected_job(ui: ref Ui, pipeline: syntax.Pipeline) -> ?ref job_control.Job {
    job_control.poll_all(ui.job_table);
    var words = pipeline.commands[0].words;
    if (len(words) == 1) { return job_control.latest_active(ui.job_table); }
    if (len(words) != 2) { return none; }
    match (strconv.parse_u64(words[1].value)) {
        none { return none; }
        some(id) { return job_control.find(ui.job_table, id); }
    }
}

fn jobs_builtin(ui: ref Ui, pipeline: syntax.Pipeline) -> ?i64 {
    if (!first_command_is(pipeline, "jobs")) { return none; }
    if (len(pipeline.commands[0].words) != 1) {
        write_line("lsh: usage: jobs");
        return some(2);
    }
    job_control.poll_all(ui.job_table);
    for (job in ui.job_table.jobs) {
        if (job.state == job_control.JobState.running) {
            announce_job(job, "Running");
        } else if (job.state == job_control.JobState.stopped) {
            announce_job(job, "Stopped");
        } else {
            announce_job(job, "Done");
        }
    }
    job_control.prune_done(ui.job_table);
    return some(0);
}

fn fg_builtin(ui: ref Ui, pipeline: syntax.Pipeline) -> ?i64 {
    if (!first_command_is(pipeline, "fg")) { return none; }
    match (selected_job(ui, pipeline)) {
        none {
            write_line("lsh: fg: no such active job");
            return some(1);
        }
        some(job) {
            if (job.state == job_control.JobState.done) {
                write_line("lsh: fg: job is already done");
                return some(1);
            }
            write_line(job.command);
            return some(run_foreground(ui, job, job.state == job_control.JobState.stopped));
        }
    }
}

fn bg_builtin(ui: ref Ui, pipeline: syntax.Pipeline) -> ?i64 {
    if (!first_command_is(pipeline, "bg")) { return none; }
    match (selected_job(ui, pipeline)) {
        none {
            write_line("lsh: bg: no such active job");
            return some(1);
        }
        some(job) {
            if (job.state == job_control.JobState.done) {
                write_line("lsh: bg: job is already done");
                return some(1);
            }
            if (job.state == job_control.JobState.stopped) {
                match (job_control.continue_job(job)) {
                    some(_) {
                        write_line("lsh: bg: could not continue job");
                        return some(1);
                    }
                    none {}
                }
            }
            announce_job(job, "Running");
            return some(0);
        }
    }
}

fn interactive_builtin(ui: ref Ui, pipeline: syntax.Pipeline) -> ?i64 {
    match (jobs_builtin(ui, pipeline)) {
        some(status) { return some(status); }
        none {}
    }
    match (fg_builtin(ui, pipeline)) {
        some(status) { return some(status); }
        none {}
    }
    return bg_builtin(ui, pipeline);
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

    match (interactive_builtin(ui, pipeline)) {
        some(status) {
            ui.last_status = status;
        }
        none {
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
                    ui.last_status = external(ui, pipeline, command_text);
                }
            }
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

fn mode_or_none(input: fd.Fd) -> ?tty.Mode {
    if (!tty.is_tty(input)) { return none; }
    return tty.capture(input);
}

fn run_with_terminal(input: fd.Fd, shell_mode: tty.Mode) -> i64 {
    var shell_group = groups.current();
    match (tty.foreground(input)) {
        none {
            fd.close(input);
            return 2;
        }
        some(foreground) {
            if (!groups.same(foreground, shell_group)) {
                fd.close(input);
                return 2;
            }
        }
    }

    var ui = new Ui {
        editor: editor.create(),
        history: history.create(),
        shell: state.create(),
        job_table: job_control.create(),
        tty_input: input,
        shell_group: shell_group,
        shell_mode: shell_mode,
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
        job_control.poll_all(ui.job_table);
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
    tty.restore(input, shell_mode);
    fd.close(input);
    return ui.last_status;
}

fn run() -> i64 {
    var input = fd.stdin();
    match (mode_or_none(input)) {
        none {
            fd.close(input);
            return 2;
        }
        some(mode) { return run_with_terminal(input, mode); }
    }
}

pub fn main() -> i64 {
    return run();
}
