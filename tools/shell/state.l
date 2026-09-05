import bytes;
import linux.env as env;
import linux.fs as fs;
import syntax;

pub struct BuiltinError {
    pub message: const []u8,
    pub error_number: ?i64,
}

pub struct BuiltinResult {
    pub status: i64,
    // Output is data, not terminal presentation. Once a builtin has produced
    // it the shell only forwards/prints/redirects those bytes; callers do not
    // need a mutation capability for the result buffer.
    pub output: const []u8,
    pub error: ?BuiltinError,
}

pub enum Dispatch {
    external,
    handled(BuiltinResult),
}

pub struct State {
    pub previous_cwd: ?[]u8,
}

pub fn create() -> ref State {
    return new State { previous_cwd: none };
}

fn success(output: const []u8) -> BuiltinResult {
    return BuiltinResult {
        status: 0,
        output: output,
        error: none,
    };
}

fn failure(status: i64, message: const []u8, number: ?i64) -> BuiltinResult {
    return BuiltinResult {
        status: status,
        output: [],
        error: some(BuiltinError {
            message: message,
            error_number: number,
        }),
    };
}

fn is_name(command: syntax.Command, name: const []u8) -> bool {
    return len(command.words) != 0 && bytes.equal(command.words[0].value, name);
}

fn is_builtin(command: syntax.Command) -> bool {
    return is_name(command, "cd") || is_name(command, "env");
}

fn handle_cd(state: ref State, command: syntax.Command) -> BuiltinResult {
    if (len(command.words) > 2) {
        return failure(2, "usage: cd [directory]", none);
    }

    var target: ?[]u8 = none;
    var print_target = false;
    if (len(command.words) == 1) {
        match (env.get("HOME")) {
            some(home) {
                target = some(bytes.clone(home));
            }
            none {
                return failure(1, "HOME is not set", none);
            }
        }
    } else if (bytes.equal(command.words[1].value, "-")) {
        match (state.previous_cwd) {
            some(previous) {
                target = some(bytes.clone(previous));
                print_target = true;
            }
            none {
                return failure(1, "no previous directory", none);
            }
        }
    } else {
        target = some(bytes.clone(command.words[1].value));
    }

    match (target) {
        none { trap; }
        some(path) {
            var before = fs.cwd();
            match (fs.chdir(path)) {
                some(number) {
                    return failure(1, "could not change directory", some(number));
                }
                none {
                    state.previous_cwd = before;
                    if (print_target) {
                        var out = bytes.clone(path);
                        push(out, '\n');
                        return success(out);
                    }
                    return success([]);
                }
            }
        }
    }
}

fn environment_listing() -> []u8 {
    var out: []u8 = [];
    var entries = env.entries();
    for (entry in entries) {
        bytes.append(out, entry);
        push(out, '\n');
    }
    return out;
}

fn handle_env(command: syntax.Command) -> BuiltinResult {
    if (len(command.words) == 1) {
        return success(environment_listing());
    }

    var action = command.words[1].value;
    if (bytes.equal(action, "list")) {
        if (len(command.words) != 2) {
            return failure(2, "usage: env list", none);
        }
        return success(environment_listing());
    }

    if (bytes.equal(action, "get")) {
        if (len(command.words) != 3) {
            return failure(2, "usage: env get NAME", none);
        }
        match (env.get(command.words[2].value)) {
            some(value) {
                var out = bytes.clone(value);
                push(out, '\n');
                return success(out);
            }
            none {
                return failure(1, "environment variable is not set", none);
            }
        }
    }

    if (bytes.equal(action, "set")) {
        if (len(command.words) != 4) {
            return failure(2, "usage: env set NAME VALUE", none);
        }
        match (env.set(command.words[2].value, command.words[3].value, true)) {
            none {
                return success([]);
            }
            some(number) {
                return failure(1, "could not set environment variable", some(number));
            }
        }
    }

    if (bytes.equal(action, "unset")) {
        if (len(command.words) != 3) {
            return failure(2, "usage: env unset NAME", none);
        }
        match (env.unset(command.words[2].value)) {
            none {
                return success([]);
            }
            some(number) {
                return failure(1, "could not unset environment variable", some(number));
            }
        }
    }

    return failure(2, "usage: env [list|get NAME|set NAME VALUE|unset NAME]", none);
}

// Dispatch only state owned by the shell process. Everything else remains an
// ordinary external command for executor.run(). Builtins are currently
// standalone-only; rejecting them in a pipeline is preferable to silently
// running a state mutation in a child-like context that cannot affect the
// interactive shell.
pub fn dispatch(state: ref State, pipeline: syntax.Pipeline) -> Dispatch {
    if (len(pipeline.commands) == 0) {
        return Dispatch.handled(success([]));
    }

    if (len(pipeline.commands) != 1) {
        for (command in pipeline.commands) {
            if (is_builtin(command)) {
                return Dispatch.handled(failure(2, "shell builtin cannot be used in a pipeline yet", none));
            }
        }
        return Dispatch.external;
    }

    var command = pipeline.commands[0];
    if (is_name(command, "cd")) {
        return Dispatch.handled(handle_cd(state, command));
    }
    if (is_name(command, "env")) {
        return Dispatch.handled(handle_env(command));
    }
    return Dispatch.external;
}
