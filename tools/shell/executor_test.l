import executor;
import syntax;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn parse_ready(input: const []u8) -> syntax.Pipeline {
    match (syntax.parse(input)) {
        syntax.ParseResult.ready(pipeline) { return pipeline; }
        syntax.ParseResult.incomplete(_) { trap; }
        syntax.ParseResult.error(_) { trap; }
    }
}

fn require_exited(result: executor.ProcessResult, code: i64) {
    match (result) {
        executor.ProcessResult.exited(actual) { require(actual == code); }
        executor.ProcessResult.signaled(_) { trap; }
    }
}

fn test_live_launch_wait() {
    match (executor.launch(parse_ready("/usr/bin/false | /usr/bin/true"))) {
        executor.LaunchResult.ok(live) {
            require(len(live.children) == 2);
            match (live.group) {
                some(_) {}
                none { trap; }
            }
            var result = executor.wait(live);
            require(len(result.processes) == 2);
            require_exited(result.processes[0], 1);
            require_exited(result.processes[1], 0);
        }
        executor.LaunchResult.launch_failed(_) { trap; }
        executor.LaunchResult.invalid(_) { trap; }
    }
}

fn test_path_lookup() {
    match (executor.run(parse_ready("true"))) {
        executor.ExecResult.ok(job) {
            require(len(job.processes) == 1);
            require_exited(job.processes[0], 0);
        }
        executor.ExecResult.launch_failed(_) { trap; }
        executor.ExecResult.invalid(_) { trap; }
    }
}

fn test_path_miss() {
    match (executor.run(parse_ready("definitely-no-such-l-shell-command-7f3d9e"))) {
        executor.ExecResult.invalid(_) {}
        executor.ExecResult.launch_failed(_) { trap; }
        executor.ExecResult.ok(_) { trap; }
    }
}

fn test_pipeline_statuses() {
    match (executor.run(parse_ready("/usr/bin/false | /usr/bin/true"))) {
        executor.ExecResult.ok(job) {
            require(len(job.processes) == 2);
            require_exited(job.processes[0], 1);
            require_exited(job.processes[1], 0);
        }
        executor.ExecResult.launch_failed(_) { trap; }
        executor.ExecResult.invalid(_) { trap; }
    }
}

fn test_partial_launch_rollback() {
    match (executor.launch(parse_ready("/usr/bin/sleep 30 | /definitely/no-such-program"))) {
        executor.LaunchResult.launch_failed(failure) { require(failure.error_number > 0); }
        executor.LaunchResult.ok(_) { trap; }
        executor.LaunchResult.invalid(_) { trap; }
    }
}

fn test_partial_path_miss_rollback() {
    match (executor.launch(parse_ready("/usr/bin/sleep 30 | definitely-no-such-l-shell-command-7f3d9e"))) {
        executor.LaunchResult.invalid(_) {}
        executor.LaunchResult.launch_failed(_) { trap; }
        executor.LaunchResult.ok(_) { trap; }
    }
}

fn main() -> i64 {
    test_live_launch_wait();
    test_path_lookup();
    test_path_miss();
    test_pipeline_statuses();
    test_partial_launch_rollback();
    test_partial_path_miss_rollback();
    return 0;
}
