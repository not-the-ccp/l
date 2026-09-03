import bytes;
import linux.fd as fd;
import linux.process as process;

fn require(ok: bool) {
    if (!ok) {
        trap;
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
