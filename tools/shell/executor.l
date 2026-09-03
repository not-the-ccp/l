import bytes;
import sys;
import linux.fd as fd;
import linux.process as process;
import syntax;

pub enum ProcessResult {
    exited(i64),
    signaled(i64),
}

pub struct JobResult {
    pub processes: []ProcessResult,
}

pub struct LaunchFailure {
    pub command: []u8,
    pub error_number: i64,
}

pub enum ExecResult {
    ok(JobResult),
    launch_failed(LaunchFailure),
    invalid([]u8),
}

enum SpawnAttempt {
    ok(process.Child),
    not_found,
    failed(i64),
}

fn normalize_status(status: process.ExitStatus) -> ProcessResult {
    match (process.exit_code(status)) {
        some(code) {
            return ProcessResult.exited(code);
        }
        none {}
    }
    match (process.term_signal(status)) {
        some(number) {
            return ProcessResult.signaled(number);
        }
        none {
            trap;
        }
    }
}

fn argv_for(command: syntax.Command) -> []const []u8 {
    var argv: []const []u8 = [];
    for (word in command.words) {
        push(argv, word.value);
    }
    return argv;
}

fn contains_slash(value: const []u8) -> bool {
    match (bytes.find_byte(value, '/', 0)) {
        some(_) {
            return true;
        }
        none {
            return false;
        }
    }
}

// Linux PATH lookup skips candidates whose path does not exist or crosses a
// non-directory component. Other exec errors (for example EACCES) are retained
// so a failed search can report the meaningful launch error instead of claiming
// that the command was absent.
fn path_miss(error_number: i64) -> bool {
    return error_number == 2 || error_number == 20; // ENOENT, ENOTDIR
}

fn path_candidate(directory: const []u8, name: const []u8) -> []u8 {
    if (len(directory) == 0) {
        return bytes.clone(name);
    }
    var out = bytes.clone(directory);
    if (out[len(out) - 1] != '/') {
        push(out, '/');
    }
    bytes.append(out, name);
    return out;
}

fn spawn_at(path: const []u8, argv: const []const []u8, input: fd.Fd, output: fd.Fd, error: fd.Fd, group: ?process.Group) -> SpawnAttempt {
    var result = process.spawn_exact(path, argv, input, output, error, group);
    match (process.spawn_child(result)) {
        some(child) {
            return SpawnAttempt.ok(child);
        }
        none {}
    }
    match (process.spawn_error(result)) {
        some(number) {
            return SpawnAttempt.failed(number);
        }
        none {
            trap;
        }
    }
}

fn spawn_command(command: syntax.Command, input: fd.Fd, output: fd.Fd, error: fd.Fd, group: ?process.Group) -> SpawnAttempt {
    if (len(command.words) == 0 || len(command.words[0].value) == 0) {
        return SpawnAttempt.not_found;
    }

    var argv = argv_for(command);
    var name = command.words[0].value;
    if (contains_slash(name)) {
        return spawn_at(name, argv, input, output, error, group);
    }

    match (sys.getenv("PATH")) {
        none {
            return SpawnAttempt.not_found;
        }
        some(path) {
            var directories = bytes.split_byte(path, ':');
            var last_error: ?i64 = none;
            for (directory in directories) {
                var candidate = path_candidate(directory, name);
                match (spawn_at(candidate, argv, input, output, error, group)) {
                    SpawnAttempt.ok(child) {
                        return SpawnAttempt.ok(child);
                    }
                    SpawnAttempt.failed(number) {
                        if (!path_miss(number)) {
                            last_error = some(number);
                        }
                    }
                    SpawnAttempt.not_found {}
                }
            }
            match (last_error) {
                some(number) {
                    return SpawnAttempt.failed(number);
                }
                none {
                    return SpawnAttempt.not_found;
                }
            }
        }
    }
}

fn close_pipes(pipes: [][]fd.Fd) {
    for (pipe in pipes) {
        fd.close(pipe[0]);
        fd.close(pipe[1]);
    }
}

fn close_stdio(input: fd.Fd, output: fd.Fd, error: fd.Fd) {
    fd.close(input);
    fd.close(output);
    fd.close(error);
}

fn rollback(children: []process.Child, group: ?process.Group, pipes: [][]fd.Fd, input: fd.Fd, output: fd.Fd, error: fd.Fd) {
    var group_killed = false;
    match (group) {
        some(value) {
            match (process.send_group(value, process.sigkill())) {
                none {
                    group_killed = true;
                }
                some(_) {}
            }
        }
        none {}
    }

    if (!group_killed) {
        for (child in children) {
            process.send(child, process.sigkill());
        }
    }

    close_pipes(pipes);
    close_stdio(input, output, error);
    for (child in children) {
        process.wait_exit(child);
    }
}

fn launch_failure(command: syntax.Command, number: i64) -> ExecResult {
    var name: []u8 = [];
    if (len(command.words) != 0) {
        name = bytes.clone(command.words[0].value);
    }
    return ExecResult.launch_failed(LaunchFailure {
        command: name,
        error_number: number,
    });
}

pub fn run(pipeline: syntax.Pipeline) -> ExecResult {
    if (len(pipeline.commands) == 0) {
        return ExecResult.ok(JobResult { processes: [] });
    }

    var input = fd.stdin();
    var output = fd.stdout();
    var error = fd.stderr();
    var pipes: [][]fd.Fd = [];
    for (var i: u64 = 1; i < len(pipeline.commands); i += 1) {
        push(pipes, fd.pipe());
    }

    var children: []process.Child = [];
    var group: ?process.Group = none;

    for (var i: u64 = 0; i < len(pipeline.commands); i += 1) {
        var stage_input = input;
        var stage_output = output;
        if (i > 0) {
            stage_input = pipes[i - 1][0];
        }
        if (i + 1 < len(pipeline.commands)) {
            stage_output = pipes[i][1];
        }

        var command = pipeline.commands[i];
        match (spawn_command(command, stage_input, stage_output, error, group)) {
            SpawnAttempt.ok(child) {
                push(children, child);
                if (i == 0) {
                    group = some(process.group(child));
                }
            }
            SpawnAttempt.not_found {
                rollback(children, group, pipes, input, output, error);
                return ExecResult.invalid("command could not be resolved");
            }
            SpawnAttempt.failed(number) {
                rollback(children, group, pipes, input, output, error);
                return launch_failure(command, number);
            }
        }
    }

    close_pipes(pipes);
    close_stdio(input, output, error);

    var results: []ProcessResult = [];
    for (child in children) {
        push(results, normalize_status(process.wait_exit(child)));
    }
    return ExecResult.ok(JobResult { processes: results });
}
