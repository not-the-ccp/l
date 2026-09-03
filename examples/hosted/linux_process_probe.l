import bytes;
import linux.fd as fd;
import linux.process as process;

fn require(ok: bool) {
    if (!ok) {
        trap;
    }
}

fn require_signal_ok(result: ?i64) {
    match (result) {
        none {}
        some(_) {
            trap;
        }
    }
}

fn test_fd_io() {
    var ends = fd.pipe();
    var writer = fd.dup(ends[1]);
    fd.close(ends[1]);

    match (fd.read(ends[0], 0)) {
        some(data) {
            require(len(data) == 0);
        }
        none {
            trap;
        }
    }

    require(fd.write(writer, "abc") == 3);
    fd.close(writer);

    match (fd.read(ends[0], 16)) {
        some(data) {
            require(bytes.equal(data, "abc"));
        }
        none {
            trap;
        }
    }
    match (fd.read(ends[0], 16)) {
        none {}
        some(_) {
            trap;
        }
    }
    fd.close(ends[0]);
}

fn child_or_trap(result: process.SpawnResult) -> process.Child {
    match (process.spawn_child(result)) {
        some(child) {
            return child;
        }
        none {
            trap;
        }
    }
}

fn require_spawn_error(result: process.SpawnResult) {
    match (process.spawn_child(result)) {
        none {}
        some(_) {
            trap;
        }
    }
    match (process.spawn_error(result)) {
        some(number) {
            require(number > 0);
        }
        none {
            trap;
        }
    }
}

fn exited_zero(status: process.ExitStatus) -> bool {
    match (process.exit_code(status)) {
        some(code) {
            return code == 0;
        }
        none {
            return false;
        }
    }
}

fn require_signaled(status: process.ExitStatus, expected: i64) {
    match (process.term_signal(status)) {
        some(number) {
            require(number == expected);
        }
        none {
            trap;
        }
    }
}

fn test_signals(input: fd.Fd, output: fd.Fd, error: fd.Fd) {
    var term = process.sigterm();
    require(term > 0);
    require(process.sigint() > 0);
    require(process.sigquit() > 0);
    require(process.sigkill() > 0);
    require(process.sigstop() > 0);
    require(process.sigtstp() > 0);
    require(process.sigcont() > 0);
    require(process.sighup() > 0);

    var sleep_argv = ["sleep", "30"];
    var direct = child_or_trap(process.spawn_exact(
        "/usr/bin/sleep",
        sleep_argv,
        input,
        output,
        error,
        none
    ));
    require_signal_ok(process.send(direct, term));
    require_signaled(process.wait_exit(direct), term);

    var first = child_or_trap(process.spawn_exact(
        "/usr/bin/sleep",
        sleep_argv,
        input,
        output,
        error,
        none
    ));
    var group = process.group(first);
    var second = child_or_trap(process.spawn_exact(
        "/usr/bin/sleep",
        sleep_argv,
        input,
        output,
        error,
        some(group)
    ));
    require_signal_ok(process.send_group(group, term));
    require_signaled(process.wait_exit(first), term);
    require_signaled(process.wait_exit(second), term);
}

fn main() -> i64 {
    test_fd_io();

    var input = fd.stdin();
    var output = fd.stdout();
    var error = fd.stderr();

    var missing_argv = ["missing-program"];
    require_spawn_error(process.spawn_exact(
        "/definitely/not/an/executable",
        missing_argv,
        input,
        output,
        error,
        none
    ));

    test_signals(input, output, error);

    var first_pipe = fd.pipe();
    var second_pipe = fd.pipe();

    var first_argv = ["printf", "%s", "foo"];
    var first = child_or_trap(process.spawn_exact(
        "/usr/bin/printf",
        first_argv,
        input,
        first_pipe[1],
        error,
        none
    ));
    var job = process.group(first);

    var second_argv = ["tr", "o", "a"];
    var second = child_or_trap(process.spawn_exact(
        "/usr/bin/tr",
        second_argv,
        first_pipe[0],
        second_pipe[1],
        error,
        some(job)
    ));

    var third_argv = ["wc", "-c"];
    var third = child_or_trap(process.spawn_exact(
        "/usr/bin/wc",
        third_argv,
        second_pipe[0],
        output,
        error,
        some(job)
    ));

    fd.close(first_pipe[0]);
    fd.close(first_pipe[1]);
    fd.close(second_pipe[0]);
    fd.close(second_pipe[1]);
    fd.close(input);
    fd.close(output);
    fd.close(error);

    var first_status = process.wait_exit(first);
    var second_status = process.wait_exit(second);
    var third_status = process.wait_exit(third);

    if (!exited_zero(first_status) || !exited_zero(second_status) || !exited_zero(third_status)) {
        return 1;
    }
    return 0;
}
