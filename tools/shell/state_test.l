import bytes;
import executor;
import linux.env as env;
import linux.fs as fs;
import state;
import syntax;

fn require(ok: bool) {
    if (!ok) {
        trap;
    }
}

fn parse_ready(input: const []u8) -> syntax.Pipeline {
    match (syntax.parse(input)) {
        syntax.ParseResult.ready(pipeline) {
            return pipeline;
        }
        syntax.ParseResult.incomplete(_) { trap; }
        syntax.ParseResult.error(_) { trap; }
    }
}

fn handled(value: state.Dispatch) -> state.BuiltinResult {
    match (value) {
        state.Dispatch.handled(result) {
            return result;
        }
        state.Dispatch.external { trap; }
    }
}

fn require_external(value: state.Dispatch) {
    match (value) {
        state.Dispatch.external {}
        state.Dispatch.handled(_) { trap; }
    }
}

fn require_exited(result: executor.ProcessResult, code: i64) {
    match (result) {
        executor.ProcessResult.exited(actual) {
            require(actual == code);
        }
        executor.ProcessResult.signaled(_) { trap; }
    }
}

fn child_exit(input: const []u8) -> i64 {
    match (executor.run(parse_ready(input))) {
        executor.ExecResult.ok(job) {
            require(len(job.processes) == 1);
            match (job.processes[0]) {
                executor.ProcessResult.exited(code) { return code; }
                executor.ProcessResult.signaled(_) { trap; }
            }
        }
        executor.ExecResult.launch_failed(_) { trap; }
        executor.ExecResult.invalid(_) { trap; }
    }
}

fn main() -> i64 {
    var shell = state.create();

    // Empty input is a shell-owned no-op; unrelated commands are left to the
    // external executor.
    require(handled(state.dispatch(shell, parse_ready(""))).status == 0);
    require_external(state.dispatch(shell, parse_ready("/usr/bin/true")));

    // Stateful builtins are rejected in pipelines until builtin stream wiring
    // exists; silently mutating a throwaway context would be misleading.
    var piped = handled(state.dispatch(shell, parse_ready("cd / | /usr/bin/true")));
    require(piped.status == 2);
    match (piped.error) {
        some(problem) {
            require(bytes.equal(problem.message, "shell builtin cannot be used in a pipeline yet"));
        }
        none { trap; }
    }

    var original: []u8 = [];
    match (fs.cwd()) {
        some(path) { original = bytes.clone(path); }
        none { trap; }
    }

    var changed = handled(state.dispatch(shell, parse_ready("cd /")));
    require(changed.status == 0);
    match (fs.cwd()) {
        some(path) { require(bytes.equal(path, "/")); }
        none { trap; }
    }

    // `cd -` is state, not environment magic: the shell remembers the last
    // named cwd itself and reports the implicit destination to the UI.
    var back = handled(state.dispatch(shell, parse_ready("cd -")));
    require(back.status == 0);
    match (fs.cwd()) {
        some(path) { require(bytes.equal(path, original)); }
        none { trap; }
    }
    var expected_back = bytes.clone(original);
    push(expected_back, '\n');
    require(bytes.equal(back.output, expected_back));

    // A failed directory change does not destroy the previous-directory slot.
    var failed_cd = handled(state.dispatch(shell, parse_ready("cd /definitely/no/such/l-shell-directory")));
    require(failed_cd.status == 1);
    match (failed_cd.error) {
        some(problem) {
            match (problem.error_number) {
                some(number) { require(number > 0); }
                none { trap; }
            }
        }
        none { trap; }
    }
    match (fs.cwd()) {
        some(path) { require(bytes.equal(path, original)); }
        none { trap; }
    }

    var variable = "L_SHELL_STATE_TEST_7F3D9E";
    env.unset(variable);

    var set_result = handled(state.dispatch(shell, parse_ready("env set L_SHELL_STATE_TEST_7F3D9E human-value")));
    require(set_result.status == 0);
    match (env.get(variable)) {
        some(value) { require(bytes.equal(value, "human-value")); }
        none { trap; }
    }

    var get_result = handled(state.dispatch(shell, parse_ready("env get L_SHELL_STATE_TEST_7F3D9E")));
    require(get_result.status == 0);
    require(bytes.equal(get_result.output, "human-value\n"));

    var list_result = handled(state.dispatch(shell, parse_ready("env list")));
    require(list_result.status == 0);
    match (bytes.find(list_result.output, "L_SHELL_STATE_TEST_7F3D9E=human-value", 0)) {
        some(_) {}
        none { trap; }
    }

    // The mutation is process state: newly launched external programs observe
    // it without shell-text interpolation or an intermediary legacy shell.
    require(child_exit("/usr/bin/printenv L_SHELL_STATE_TEST_7F3D9E") == 0);

    var unset_result = handled(state.dispatch(shell, parse_ready("env unset L_SHELL_STATE_TEST_7F3D9E")));
    require(unset_result.status == 0);
    match (env.get(variable)) {
        none {}
        some(_) { trap; }
    }
    require(child_exit("/usr/bin/printenv L_SHELL_STATE_TEST_7F3D9E") == 1);

    var missing = handled(state.dispatch(shell, parse_ready("env get L_SHELL_STATE_TEST_7F3D9E")));
    require(missing.status == 1);

    // Restore explicitly in case the test's original cwd differed by symlink or
    // mount naming from the path used by the surrounding test harness.
    match (fs.chdir(original)) {
        none {}
        some(_) { trap; }
    }
    return 0;
}
