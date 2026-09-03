import linux.fd as fd;
import linux.process as process;
import linux.process.group as groups;
import linux.process.wait as wait;
import linux.tty as tty;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn require_ok(result: ?i64) {
    match (result) {
        none {}
        some(_) { trap; }
    }
}

fn child_or_trap(result: process.SpawnResult) -> process.Child {
    match (process.spawn_child(result)) {
        some(child) { return child; }
        none { trap; }
    }
}

fn mode_or_trap(input: fd.Fd) -> tty.Mode {
    match (tty.capture(input)) {
        some(mode) { return mode; }
        none { trap; }
    }
}

fn foreground_is(input: fd.Fd, group: process.Group) -> bool {
    match (tty.foreground(input)) {
        some(actual) { return groups.same(actual, group); }
        none { return false; }
    }
}

fn write_all(output: fd.Fd, value: const []u8) {
    var offset: u64 = 0;
    while (offset < len(value)) {
        var rest: []u8 = [];
        for (var i = offset; i < len(value); i += 1) { push(rest, value[i]); }
        var wrote = fd.write(output, rest);
        if (wrote <= 0) { trap; }
        offset += wrote as u64;
    }
}

fn main() -> i64 {
    var input = fd.stdin();
    var output = fd.stdout();
    var error = fd.stderr();
    require(tty.is_tty(input));

    var shell_group = groups.current();
    require(foreground_is(input, shell_group));
    var shell_mode = mode_or_trap(input);

    var argv = ["cat"];
    var child = child_or_trap(process.spawn_exact(
        "/bin/cat", argv, input, output, error, none
    ));
    var job = process.group(child);
    require(!groups.same(shell_group, job));

    write_all(output, "READY\n");
    require_ok(tty.set_foreground(input, job));
    require(foreground_is(input, job));

    // The harness sends the terminal's VSUSP byte (Ctrl-Z). The tty driver, not
    // this process, must stop the foreground process group.
    var stopped = wait.group(job);
    match (wait.stop_signal(stopped)) {
        some(number) { require(number == process.sigtstp()); }
        none { trap; }
    }

    require_ok(tty.set_foreground(input, shell_group));
    require(foreground_is(input, shell_group));
    // A real full-screen child may have changed termios before stopping. Save
    // that mode for fg, then restore the shell's baseline before reading input.
    var job_mode = mode_or_trap(input);
    require_ok(tty.restore(input, shell_mode));
    write_all(output, "STOPPED\n");

    require_ok(tty.restore(input, job_mode));
    require_ok(tty.set_foreground(input, job));
    require_ok(process.send_group(job, process.sigcont()));
    var continued = wait.group(job);
    require(wait.continued(continued));
    write_all(output, "CONTINUED\n");

    // The harness now sends VINTR (Ctrl-C) through the tty. It should terminate
    // cat with SIGINT while the parent remains blocked in a kernel wait.
    var terminated = wait.group(job);
    match (wait.term_signal(terminated)) {
        some(number) { require(number == process.sigint()); }
        none { trap; }
    }

    require_ok(tty.set_foreground(input, shell_group));
    require_ok(tty.restore(input, shell_mode));
    require(foreground_is(input, shell_group));
    write_all(output, "DONE\n");

    fd.close(input);
    fd.close(output);
    fd.close(error);
    return 0;
}
