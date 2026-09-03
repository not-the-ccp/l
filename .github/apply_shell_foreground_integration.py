from pathlib import Path


def replace_between(text: str, start: str, end: str, replacement: str) -> str:
    a = text.index(start)
    b = text.index(end, a)
    return text[:a] + replacement + text[b:]


main_path = Path("tools/shell/main.l")
main = main_path.read_text()
main = main.replace(
    "import linux.process.group as groups;\nimport linux.tty as tty;",
    "import linux.process.group as groups;\nimport linux.process.signal as signals;\nimport linux.tty as tty;",
)

terminal_helpers = r'''fn enter_editor_mode(ui: ref Ui) -> bool {
    if (!tty_ok(tty.restore(ui.tty_input, ui.shell_mode))) {
        ui.running = false;
        return false;
    }
    term.enter_raw();
    term.write("\x1b[?2004h");
    return true;
}

fn enable_editor_terminal(ui: ref Ui) -> bool {
    if (!tty_ok(tty.set_foreground(ui.tty_input, ui.shell_group))) {
        ui.running = false;
        return false;
    }
    return enter_editor_mode(ui);
}

fn disable_editor_terminal(ui: ref Ui) -> bool {
    term.write("\x1b[?2004l\x1b[0m\x1b[?25h");
    term.leave_raw();
    // term.leave_raw restores the mode saved by enter_raw. Keep the explicit
    // snapshot authoritative as well so a previous child cannot become the
    // baseline if it stopped after changing termios.
    if (!tty_ok(tty.restore(ui.tty_input, ui.shell_mode))) {
        ui.running = false;
        return false;
    }
    return true;
}

'''
main = replace_between(
    main,
    "fn enable_editor_terminal(ui: ref Ui) -> bool {",
    "fn save_stopped_tty(ui: ref Ui, job: ref job_control.Job) {",
    terminal_helpers,
)

foreground = r'''fn wait_foreground_owned(ui: ref Ui, job: ref job_control.Job) -> i64 {
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
            if (!enter_editor_mode(ui)) { return 125; }
            var id = job_control.store(ui.job_table, job);
            write_safe("[");
            write_safe(strconv.format_u64(id));
            write_safe("] Stopped ");
            write_line(job.command);
            return 128 + number;
        }
        job_control.WaitResult.done(status) {
            if (!enter_editor_mode(ui)) { return 125; }
            job_control.prune_done(ui.job_table);
            return status;
        }
    }
}

// Bring an already-known background/stopped job into the foreground. New jobs
// use executor.launch_foreground(), which performs the race-free handoff before
// the child reaches exec and therefore enter wait_foreground_owned directly.
fn run_foreground(ui: ref Ui, job: ref job_control.Job, resume: bool) -> i64 {
    if (!disable_editor_terminal(ui)) { return 125; }

    if (resume) {
        match (job.tty_mode) {
            some(mode) {
                if (!tty_ok(tty.restore(ui.tty_input, mode))) {
                    if (enable_editor_terminal(ui)) {
                        write_line("lsh: fg: could not restore job terminal mode");
                    }
                    return 125;
                }
            }
            none {}
        }
    }

    if (!tty_ok(tty.set_foreground(ui.tty_input, job.group))) {
        process.send_group(job.group, process.sigkill());
        job_control.wait_foreground(job);
        if (enable_editor_terminal(ui)) {
            write_line("lsh: could not give terminal to foreground job");
        }
        return 125;
    }

    if (resume) {
        match (job_control.continue_job(job)) {
            some(_) {
                if (enable_editor_terminal(ui)) {
                    write_line("lsh: fg: could not continue job");
                }
                return 125;
            }
            none {}
        }
    }

    return wait_foreground_owned(ui, job);
}

fn external(ui: ref Ui, pipeline: syntax.Pipeline, command_text: const []u8) -> i64 {
    // Normal terminal mode must be restored before a child becomes foreground.
    // The shell ignores INT/QUIT/TSTP while interactive, closing the tiny window
    // between restoring ISIG and foreground_exact transferring terminal ownership.
    if (!disable_editor_terminal(ui)) { return 125; }

    match (executor.launch_foreground(pipeline, ui.tty_input)) {
        executor.LaunchResult.invalid(message) {
            if (!enable_editor_terminal(ui)) { return 125; }
            write_safe("lsh: ");
            write_line(message);
            return 127;
        }
        executor.LaunchResult.launch_failed(failure) {
            if (!enable_editor_terminal(ui)) { return 125; }
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
                    // This is an executor invariant failure, but the processes
                    // are already live. Do not leak an adopted-but-untracked job.
                    executor.abort(live);
                    if (!enable_editor_terminal(ui)) { return 125; }
                    write_line("lsh: executor returned a foreground job without a process group");
                    return 125;
                }
                some(job) {
                    return wait_foreground_owned(ui, job);
                }
            }
        }
    }
}

'''
main = replace_between(
    main,
    "fn run_foreground(ui: ref Ui, job: ref job_control.Job, resume: bool) -> i64 {",
    "fn selected_job(ui: ref Ui, pipeline: syntax.Pipeline) -> ?ref job_control.Job {",
    foreground,
)

signal_helpers = r'''fn signal_ok(result: ?i64) -> bool {
    match (result) {
        none { return true; }
        some(_) { return false; }
    }
}

fn restore_shell_signals() {
    signals.default(process.sigint());
    signals.default(process.sigquit());
    signals.default(process.sigtstp());
}

fn ignore_shell_signals() -> bool {
    if (!signal_ok(signals.ignore(process.sigint()))) { return false; }
    if (!signal_ok(signals.ignore(process.sigquit()))) {
        signals.default(process.sigint());
        return false;
    }
    if (!signal_ok(signals.ignore(process.sigtstp()))) {
        signals.default(process.sigquit());
        signals.default(process.sigint());
        return false;
    }
    return true;
}

'''
main = main.replace("fn mode_or_none(input: fd.Fd) -> ?tty.Mode {", signal_helpers + "fn mode_or_none(input: fd.Fd) -> ?tty.Mode {")
main = main.replace(
    "    var ui = new Ui {\n",
    "    if (!ignore_shell_signals()) {\n        fd.close(input);\n        return 2;\n    }\n\n    var ui = new Ui {\n",
    1,
)
main = main.replace(
    "    tty.restore(input, shell_mode);\n    fd.close(input);\n    return ui.last_status;",
    "    tty.restore(input, shell_mode);\n    restore_shell_signals();\n    fd.close(input);\n    return ui.last_status;",
)
main_path.write_text(main)


test_path = Path("tests/shell_pty.py")
test = test_path.read_text()
test = test.replace(
    "def interrupt_foreground(fd: int, command: bytes, control: bytes) -> bytes:\n"
    "    os.write(fd, command + b\"\\r\")\n"
    "    time.sleep(0.20)\n",
    "def interrupt_foreground(fd: int, command: bytes, control: bytes, settle: float = 0.20) -> bytes:\n"
    "    os.write(fd, command + b\"\\r\")\n"
    "    time.sleep(settle)\n",
)
needle = "        # Ordinary external execution now uses a real foreground process group.\n"
addition = r'''        # The interactive shell itself ignores terminal-control signals. Raw
        # editing normally suppresses ISIG, but this also closes the handoff
        # window after Enter and before a new child pgrp owns the tty.
        os.kill(pid, signal.SIGINT)
        os.kill(pid, signal.SIGQUIT)
        os.kill(pid, signal.SIGTSTP)
        time.sleep(0.05)
        chunk = send(fd, b"env get HOME\r")
        transcript += chunk
        assert str(home).encode() in strip_control(chunk), strip_control(chunk[-3000:])

'''
test = test.replace(needle, addition + needle)
needle2 = "        # Ctrl-C is generated by the tty driver for the child's foreground pgrp;\n"
addition2 = r'''        # Exercise the foreground-launch boundary repeatedly with a command that
        # reads the tty immediately. A racy fork/setpgid/tcsetpgrp sequence can
        # spuriously stop cat with SIGTTIN before our Ctrl-C arrives.
        for _ in range(8):
            chunk = interrupt_foreground(fd, b"cat", b"\x03", settle=0.03)
            transcript += chunk
            assert b"Stopped" not in strip_control(chunk), strip_control(chunk[-3000:])

'''
test = test.replace(needle2, addition2 + needle2)
test_path.write_text(test)
