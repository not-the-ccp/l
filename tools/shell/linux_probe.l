import linux.proc as lp;

fn exited_zero(status: lp.TerminalStatus) -> bool {
    var code = lp.exit_code(status);
    match (code) {
        none {
            return false;
        }
        some(value) {
            return value == 0;
        }
    }
}

fn main() -> i64 {
    var input = lp.stdin();
    var output = lp.stdout();
    var error = lp.stderr();
    var first_pipe = lp.pipe();
    var second_pipe = lp.pipe();

    var first_argv: [][]u8 = ["printf", "foo"];
    var first = lp.spawn(
        "/usr/bin/printf",
        first_argv,
        input,
        first_pipe[1],
        error,
        none
    );
    var job = lp.group(first);

    var second_argv: [][]u8 = ["tr", "o", "a"];
    var second = lp.spawn(
        "/usr/bin/tr",
        second_argv,
        first_pipe[0],
        second_pipe[1],
        error,
        some(job)
    );

    var third_argv: [][]u8 = ["wc", "-c"];
    var third = lp.spawn(
        "/usr/bin/wc",
        third_argv,
        second_pipe[0],
        output,
        error,
        some(job)
    );

    // The parent must not retain any pipe endpoint. In particular, an open
    // write end here would keep downstream reads from observing EOF.
    lp.close(first_pipe[0]);
    lp.close(first_pipe[1]);
    lp.close(second_pipe[0]);
    lp.close(second_pipe[1]);
    lp.close(input);
    lp.close(output);
    lp.close(error);

    var first_status = lp.wait_terminal(first);
    var second_status = lp.wait_terminal(second);
    var third_status = lp.wait_terminal(third);

    if (!exited_zero(first_status)) {
        return 1;
    }
    if (!exited_zero(second_status)) {
        return 1;
    }
    if (!exited_zero(third_status)) {
        return 1;
    }
    return 0;
}
