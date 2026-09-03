import bytes;
import sys;
import linux.fd as fd;
import linux.process as process;
import linux.process.launch as process_launch;
import syntax;

pub enum ProcessResult {
    exited(i64),
    signaled(i64),
}

pub struct JobResult {
    pub processes: []ProcessResult,
}

// A successfully launched pipeline whose children have not yet been reaped.
// The first child creates the process group and every later stage joins it.
// Empty pipelines are represented with no group and no children.
pub struct LiveJob {
    pub children: []process.Child,
    pub group: ?process.Group,
}

pub struct LaunchFailure {
    pub command: []u8,
    pub error_number: i64,
}

pub enum LaunchResult {
    ok(LiveJob),
    launch_failed(LaunchFailure),
    invalid([]u8),
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
        some(_) { return true; }
        none { return false; }
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

fn spawn_result(result: process.SpawnResult) -> SpawnAttempt {
    match (process.spawn_child(result)) {
        some(child) { return SpawnAttempt.ok(child); }
        none {}
    }
    match (process.spawn_error(result)) {
        some(number) { return SpawnAttempt.failed(number); }
        none { trap; }
    }
}

fn spawn_at(
    path: const []u8,
    argv: const []const []u8,
    input: fd.Fd,
    output: fd.Fd,
    error: fd.Fd,
    group: ?process.Group,
    terminal: ?fd.Fd,
) -> SpawnAttempt {
    match (terminal) {
        none {
            return spawn_result(process.spawn_exact(path, argv, input, output, error, group));
        }
        some(terminal_fd) {
            return spawn_result(process_launch.foreground_exact(
                path, argv, input, output, error, group, terminal_fd
            ));
        }
    }
}

fn spawn_command(
    command: syntax.Command,
    input: fd.Fd,
    output: fd.Fd,
    error: fd.Fd,
    group: ?process.Group,
    terminal: ?fd.Fd,
) -> SpawnAttempt {
    if (len(command.words) == 0 || len(command.words[0].value) == 0) {
        return SpawnAttempt.not_found;
    }

    var argv = argv_for(command);
    var name = command.words[0].value;
    if (contains_slash(name)) {
        return spawn_at(name, argv, input, output, error, group, terminal);
    }

    match (sys.getenv("PATH")) {
        none { return SpawnAttempt.not_found; }
        some(path) {
            var directories = bytes.split_byte(path, ':');
            var last_error: ?i64 = none;
            for (directory in directories) {
                var candidate = path_candidate(directory, name);
                match (spawn_at(candidate, argv, input, output, error, group, terminal)) {
                    SpawnAttempt.ok(child) { return SpawnAttempt.ok(child); }
                    SpawnAttempt.failed(number) {
                        if (!path_miss(number)) { last_error = some(number); }
                    }
                    SpawnAttempt.not_found {}
                }
            }
            match (last_error) {
                some(number) { return SpawnAttempt.failed(number); }
                none { return SpawnAttempt.not_found; }
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

fn kill_children(children: []process.Child, group: ?process.Group) {
    var group_killed = false;
    match (group) {
        some(value) {
            match (process.send_group(value, process.sigkill())) {
                none { group_killed = true; }
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
}

fn rollback(children: []process.Child, group: ?process.Group, pipes: [][]fd.Fd, input: fd.Fd, output: fd.Fd, error: fd.Fd) {
    kill_children(children, group);
    close_pipes(pipes);
    close_stdio(input, output, error);
    for (child in children) {
        process.wait_exit(child);
    }
}

fn failure(command: syntax.Command, number: i64) -> LaunchFailure {
    var name: []u8 = [];
    if (len(command.words) != 0) {
        name = bytes.clone(command.words[0].value);
    }
    return LaunchFailure { command: name, error_number: number };
}

// Launch owns temporary stdio/pipe handles only until all stages have either
// spawned or rollback has completed. Child processes keep their duplicated
// descriptors, so a returned LiveJob contains only process handles + pgrp.
// A foreground terminal is an extra borrowed handle: foreground_exact performs
// the race-free pgrp/tty handoff before each child reaches exec.
fn launch_impl(pipeline: syntax.Pipeline, terminal: ?fd.Fd) -> LaunchResult {
    if (len(pipeline.commands) == 0) {
        return LaunchResult.ok(LiveJob { children: [], group: none });
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
        if (i > 0) { stage_input = pipes[i - 1][0]; }
        if (i + 1 < len(pipeline.commands)) { stage_output = pipes[i][1]; }

        var command = pipeline.commands[i];
        match (spawn_command(command, stage_input, stage_output, error, group, terminal)) {
            SpawnAttempt.ok(child) {
                push(children, child);
                if (i == 0) { group = some(process.group(child)); }
            }
            SpawnAttempt.not_found {
                rollback(children, group, pipes, input, output, error);
                return LaunchResult.invalid("command could not be resolved");
            }
            SpawnAttempt.failed(number) {
                rollback(children, group, pipes, input, output, error);
                return LaunchResult.launch_failed(failure(command, number));
            }
        }
    }

    close_pipes(pipes);
    close_stdio(input, output, error);
    return LaunchResult.ok(LiveJob { children: children, group: group });
}

pub fn launch(pipeline: syntax.Pipeline) -> LaunchResult {
    return launch_impl(pipeline, none);
}

pub fn launch_foreground(pipeline: syntax.Pipeline, terminal: fd.Fd) -> LaunchResult {
    return launch_impl(pipeline, some(terminal));
}

// Abort is for a successfully returned LiveJob that a higher layer can no
// longer adopt. It is intentionally separate from wait(): abort first kills the
// process group transactionally, then reaps every child handle.
pub fn abort(job: LiveJob) {
    kill_children(job.children, job.group);
    for (child in job.children) {
        process.wait_exit(child);
    }
}

pub fn wait(job: LiveJob) -> JobResult {
    var results: []ProcessResult = [];
    for (child in job.children) {
        push(results, normalize_status(process.wait_exit(child)));
    }
    return JobResult { processes: results };
}

pub fn run(pipeline: syntax.Pipeline) -> ExecResult {
    match (launch(pipeline)) {
        LaunchResult.ok(job) {
            return ExecResult.ok(wait(job));
        }
        LaunchResult.launch_failed(problem) {
            return ExecResult.launch_failed(problem);
        }
        LaunchResult.invalid(message) {
            return ExecResult.invalid(message);
        }
    }
}
