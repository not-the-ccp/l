import linux.proc as lp;
import syntax;

pub enum ProcessResult {
    exited(i64),
    signaled(i64),
}

pub struct JobResult {
    pub processes: []ProcessResult,
}

pub enum ExecResult {
    ok(JobResult),
    unsupported([]u8),
}

fn normalize_status(status: lp.TerminalStatus) -> ProcessResult {
    var exit = lp.exit_code(status);
    match (exit) {
        some(code) {
            return ProcessResult.exited(code);
        }
        none {
        }
    }

    var signal = lp.term_signal(status);
    match (signal) {
        some(number) {
            return ProcessResult.signaled(number);
        }
        none {
            trap;
        }
    }
}

pub fn success(result: JobResult) -> bool {
    for (process in result.processes) {
        match (process) {
            ProcessResult.exited(code) {
                if (code != 0) {
                    return false;
                }
            }
            ProcessResult.signaled(_) {
                return false;
            }
        }
    }
    return true;
}

pub fn run(pipeline: syntax.Pipeline) -> ExecResult {
    if (pipeline.background) {
        return ExecResult.unsupported("background jobs are not executable yet");
    }
    if (len(pipeline.commands) == 0) {
        return ExecResult.unsupported("empty pipeline");
    }
    for (command in pipeline.commands) {
        if (len(command.redirects) != 0) {
            return ExecResult.unsupported("redirection is not executable yet");
        }
    }

    var input = lp.stdin();
    var output = lp.stdout();
    var error = lp.stderr();
    var pipes: [][]lp.Fd = [];
    if (len(pipeline.commands) > 1) {
        for (var i: u64 = 0; i + 1 < len(pipeline.commands); i += 1) {
            push(pipes, lp.pipe());
        }
    }

    var children: []lp.Child = [];
    var group: ?lp.Group = none;

    for (var i: u64 = 0; i < len(pipeline.commands); i += 1) {
        var command = pipeline.commands[i];
        var child: lp.Child = if (i == 0) {
            if (len(pipeline.commands) == 1) {
                lp.spawn(command.argv[0], command.argv, input, output, error, group)
            } else {
                lp.spawn(command.argv[0], command.argv, input, pipes[0][1], error, group)
            }
        } else {
            if (i + 1 == len(pipeline.commands)) {
                lp.spawn(command.argv[0], command.argv, pipes[i - 1][0], output, error, group)
            } else {
                lp.spawn(command.argv[0], command.argv, pipes[i - 1][0], pipes[i][1], error, group)
            }
        };
        push(children, child);
        if (i == 0) {
            group = some(lp.group(child));
        }
    }

    for (pipe in pipes) {
        lp.close(pipe[0]);
        lp.close(pipe[1]);
    }
    lp.close(input);
    lp.close(output);
    lp.close(error);

    var results: []ProcessResult = [];
    for (child in children) {
        push(results, normalize_status(lp.wait_terminal(child)));
    }
    return ExecResult.ok(JobResult { processes: results });
}
