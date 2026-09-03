#!/usr/bin/env python3
from pathlib import Path


def once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, got {count}")
    return text.replace(old, new, 1)


def replace_region(text: str, start: str, end: str, new: str, label: str) -> str:
    a = text.find(start)
    if a < 0:
        raise SystemExit(f"{label}: start not found")
    b = text.find(end, a)
    if b < 0:
        raise SystemExit(f"{label}: end not found")
    return text[:a] + new + text[b:]


def edit(path: str, fn):
    p = Path(path)
    p.write_text(fn(p.read_text()))


def syntax_file(s: str) -> str:
    s = once(s,
'''pub struct Command {
    pub words: []Word,
    pub span: Span,
}
''',
'''pub enum RedirectionKind {
    input,
    output_truncate,
    output_append,
}

pub struct Redirection {
    pub kind: RedirectionKind,
    pub target: Word,
    pub span: Span,
}

pub struct Command {
    pub words: []Word,
    pub redirections: []Redirection,
    pub span: Span,
}
''', 'command redirection model')

    s = once(s,
'''pub enum IncompleteKind {
    single_quote,
    double_quote,
    pipeline,
}
''',
'''pub enum IncompleteKind {
    single_quote,
    double_quote,
    pipeline,
    redirection,
}
''', 'redirection incomplete kind')

    s = once(s,
'''enum TokenKind {
    word,
    pipe,
}
''',
'''enum TokenKind {
    word,
    pipe,
    redirect_input,
    redirect_output,
    redirect_append,
}
''', 'redirection token kinds')

    s = once(s,
'''fn scan_word(input: const []u8, start: u64) -> ScannedWord {
''',
'''fn is_operator_start(value: u8) -> bool {
    return value == '|' || value == '<' || value == '>';
}

fn scan_word(input: const []u8, start: u64) -> ScannedWord {
''', 'operator delimiter helper')

    s = s.replace(
        'while (i < len(input) && !bytes.is_ascii_space(input[i])) {',
        'while (i < len(input) && !bytes.is_ascii_space(input[i]) && !is_operator_start(input[i])) {',
        1,
    )
    s = s.replace(
        "while (i < len(input) && !bytes.is_ascii_space(input[i]) && input[i] != 39 && input[i] != '\"') {",
        "while (i < len(input) && !bytes.is_ascii_space(input[i]) && !is_operator_start(input[i]) && input[i] != 39 && input[i] != '\"') {",
        1,
    )

    lex = r'''fn lex(input: const []u8) -> Lexed {
    var tokens: []Token = [];
    var i: u64 = 0;
    var incomplete: ?Incomplete = none;

    while (i < len(input)) {
        while (i < len(input) && bytes.is_ascii_space(input[i])) {
            i += 1;
        }
        if (i >= len(input)) {
            break;
        }

        if (input[i] == '|') {
            push(tokens, Token {
                kind: TokenKind.pipe,
                word: none,
                span: Span { start: i, end: i + 1 },
            });
            i += 1;
            continue;
        }
        if (input[i] == '<') {
            push(tokens, Token {
                kind: TokenKind.redirect_input,
                word: none,
                span: Span { start: i, end: i + 1 },
            });
            i += 1;
            continue;
        }
        if (input[i] == '>') {
            var end = i + 1;
            var kind = TokenKind.redirect_output;
            if (end < len(input) && input[end] == '>') {
                end += 1;
                kind = TokenKind.redirect_append;
            }
            push(tokens, Token {
                kind: kind,
                word: none,
                span: Span { start: i, end: end },
            });
            i = end;
            continue;
        }

        var scanned = scan_word(input, i);
        push(tokens, Token { kind: TokenKind.word, word: some(scanned.word), span: scanned.word.span });
        i = scanned.word.span.end;
        match (scanned.incomplete) {
            some(reason) {
                incomplete = some(reason);
                break;
            }
            none {}
        }
    }

    return Lexed { tokens: tokens, incomplete: incomplete };
}

'''
    s = replace_region(s, 'fn word_token(word: Word) -> Token {', 'fn token_word(token: Token) -> Word {', lex, 'lexer replacement')

    parser = r'''fn redirect_kind(token: Token) -> RedirectionKind {
    if (token.kind == TokenKind.redirect_input) { return RedirectionKind.input; }
    if (token.kind == TokenKind.redirect_output) { return RedirectionKind.output_truncate; }
    if (token.kind == TokenKind.redirect_append) { return RedirectionKind.output_append; }
    trap;
}

fn is_redirect(token: Token) -> bool {
    return token.kind == TokenKind.redirect_input ||
        token.kind == TokenKind.redirect_output ||
        token.kind == TokenKind.redirect_append;
}

fn command_value(words: []Word, redirections: []Redirection, start: u64, end: u64) -> Command {
    return Command {
        words: words,
        redirections: redirections,
        span: Span { start: start, end: end },
    };
}

fn parse_tokens(tokens: []Token, input_len: u64) -> ParseResult {
    if (len(tokens) == 0) {
        return ParseResult.ready(Pipeline {
            commands: [],
            pipes: [],
            span: Span { start: 0, end: input_len },
        });
    }

    var commands: []Command = [];
    var pipes: []Span = [];
    var words: []Word = [];
    var redirections: []Redirection = [];
    var command_start: u64 = 0;
    var command_end: u64 = 0;
    var have_component = false;

    for (var i: u64 = 0; i < len(tokens); i += 1) {
        var token = tokens[i];
        if (token.kind == TokenKind.word) {
            var word = token_word(token);
            if (!have_component) {
                command_start = word.span.start;
                have_component = true;
            }
            command_end = word.span.end;
            push(words, word);
            continue;
        }

        if (is_redirect(token)) {
            if (!have_component) {
                command_start = token.span.start;
                have_component = true;
            }
            if (i + 1 == len(tokens)) {
                if (len(words) != 0) {
                    push(commands, command_value(words, redirections, command_start, token.span.end));
                }
                var trailing = Pipeline {
                    commands: commands,
                    pipes: pipes,
                    span: Span { start: tokens[0].span.start, end: token.span.end },
                };
                return partial(trailing, Incomplete {
                    kind: IncompleteKind.redirection,
                    span: token.span,
                });
            }
            var target_token = tokens[i + 1];
            if (target_token.kind != TokenKind.word) {
                return ParseResult.error(ParseError {
                    message: "redirection target must be a word",
                    span: target_token.span,
                });
            }
            var target = token_word(target_token);
            push(redirections, Redirection {
                kind: redirect_kind(token),
                target: target,
                span: Span { start: token.span.start, end: target.span.end },
            });
            command_end = target.span.end;
            i += 1;
            continue;
        }

        if (len(words) == 0) {
            return ParseResult.error(ParseError {
                message: "pipeline contains a command with no executable",
                span: token.span,
            });
        }

        push(commands, command_value(words, redirections, command_start, command_end));
        push(pipes, token.span);
        words = [];
        redirections = [];
        have_component = false;

        if (i + 1 == len(tokens)) {
            var trailing = Pipeline {
                commands: commands,
                pipes: pipes,
                span: Span { start: tokens[0].span.start, end: token.span.end },
            };
            return partial(trailing, Incomplete {
                kind: IncompleteKind.pipeline,
                span: token.span,
            });
        }
    }

    if (len(words) == 0) {
        return ParseResult.error(ParseError {
            message: "command has redirections but no executable",
            span: Span { start: command_start, end: command_end },
        });
    }
    push(commands, command_value(words, redirections, command_start, command_end));
    return ParseResult.ready(Pipeline {
        commands: commands,
        pipes: pipes,
        span: Span { start: tokens[0].span.start, end: tokens[len(tokens) - 1].span.end },
    });
}

'''
    s = replace_region(s, 'fn parse_tokens(tokens: []Token, input_len: u64) -> ParseResult {', 'pub fn parse(input: const []u8) -> ParseResult {', parser, 'parser replacement')

    old = '''    var punctuation = expect_ready("echo a|b x>y foo&bar >output");
    require(len(punctuation.commands) == 1);
    require_bytes(punctuation.commands[0].words[1].value, "a|b");
    require_bytes(punctuation.commands[0].words[2].value, "x>y");
    require_bytes(punctuation.commands[0].words[3].value, "foo&bar");
    require_bytes(punctuation.commands[0].words[4].value, ">output");
'''
    new = '''    var operators = expect_ready("printf hi>out|cat<input >>append");
    require(len(operators.commands) == 2);
    require(len(operators.pipes) == 1);
    require(len(operators.commands[0].words) == 2);
    require(len(operators.commands[0].redirections) == 1);
    require(operators.commands[0].redirections[0].kind == RedirectionKind.output_truncate);
    require_bytes(operators.commands[0].redirections[0].target.value, "out");
    require(len(operators.commands[1].redirections) == 2);
    require(operators.commands[1].redirections[0].kind == RedirectionKind.input);
    require_bytes(operators.commands[1].redirections[0].target.value, "input");
    require(operators.commands[1].redirections[1].kind == RedirectionKind.output_append);
    require_bytes(operators.commands[1].redirections[1].target.value, "append");

    var ampersand = expect_ready("echo foo&bar");
    require_bytes(ampersand.commands[0].words[1].value, "foo&bar");
'''
    s = once(s, old, new, 'operator self-test')
    s = once(s,
'''    var pipe_partial = expect_incomplete("cat |   \n", IncompleteKind.pipeline);
    require(len(pipe_partial.pipeline.commands) == 1);
    require(len(pipe_partial.pipeline.pipes) == 1);
    require_bytes(pipe_partial.pipeline.commands[0].words[0].value, "cat");

    expect_error("| cat");
''',
'''    var pipe_partial = expect_incomplete("cat |   \n", IncompleteKind.pipeline);
    require(len(pipe_partial.pipeline.commands) == 1);
    require(len(pipe_partial.pipeline.pipes) == 1);
    require_bytes(pipe_partial.pipeline.commands[0].words[0].value, "cat");

    var redirect_partial = expect_incomplete("printf x >", IncompleteKind.redirection);
    require(len(redirect_partial.pipeline.commands) == 1);
    require_bytes(redirect_partial.pipeline.commands[0].words[0].value, "printf");

    var quoted_operator = expect_ready("printf 'a>b' \"c<d\"");
    require(len(quoted_operator.commands[0].redirections) == 0);
    require_bytes(quoted_operator.commands[0].words[1].value, "a>b");
    require_bytes(quoted_operator.commands[0].words[2].value, "c<d");

    expect_error("| cat");
''', 'redirection parser tests')
    return s


def executor_file(s: str) -> str:
    s = once(s,
'''pub struct LaunchFailure {
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
''',
'''pub struct LaunchFailure {
    pub command: []u8,
    pub error_number: i64,
}

pub struct RedirectionFailure {
    pub path: []u8,
    pub error_number: i64,
}

pub enum LaunchResult {
    ok(LiveJob),
    launch_failed(LaunchFailure),
    redirection_failed(RedirectionFailure),
    invalid([]u8),
}

pub enum ExecResult {
    ok(JobResult),
    launch_failed(LaunchFailure),
    redirection_failed(RedirectionFailure),
    invalid([]u8),
}
''', 'executor failure model')

    s = once(s,
'''enum SpawnAttempt {
    ok(process.Child),
    not_found,
    failed(i64),
}
''',
'''enum SpawnAttempt {
    ok(process.Child),
    not_found,
    failed(i64),
}

enum OpenAttempt {
    ok(fd.Fd),
    failed(i64),
}

struct PreparedStage {
    input: fd.Fd,
    output: fd.Fd,
}

struct PreparedPipeline {
    stages: []PreparedStage,
    opened: []fd.Fd,
}

enum PrepareResult {
    ok(PreparedPipeline),
    failed(RedirectionFailure),
}
''', 'executor prepared IO model')

    helper = r'''fn close_fds(values: []fd.Fd) {
    for (value in values) {
        fd.close(value);
    }
}

fn redirection_failure(redirection: syntax.Redirection, number: i64) -> RedirectionFailure {
    return RedirectionFailure {
        path: bytes.clone(redirection.target.value),
        error_number: number,
    };
}

fn open_attempt(result: fd.OpenResult) -> OpenAttempt {
    match (fd.open_fd(result)) {
        some(value) { return OpenAttempt.ok(value); }
        none {}
    }
    match (fd.open_error(result)) {
        some(number) { return OpenAttempt.failed(number); }
        none { trap; }
    }
}

fn open_redirection(redirection: syntax.Redirection) -> OpenAttempt {
    if (redirection.kind == syntax.RedirectionKind.input) {
        return open_attempt(fd.open_read(redirection.target.value));
    }
    if (redirection.kind == syntax.RedirectionKind.output_truncate) {
        return open_attempt(fd.create_truncate(redirection.target.value));
    }
    return open_attempt(fd.create_append(redirection.target.value));
}

fn prepare_stages(
    pipeline: syntax.Pipeline,
    input: fd.Fd,
    output: fd.Fd,
    pipes: [][]fd.Fd,
) -> PrepareResult {
    var stages: []PreparedStage = [];
    var opened: []fd.Fd = [];

    for (var i: u64 = 0; i < len(pipeline.commands); i += 1) {
        var stage_input = input;
        var stage_output = output;
        if (i > 0) { stage_input = pipes[i - 1][0]; }
        if (i + 1 < len(pipeline.commands)) { stage_output = pipes[i][1]; }

        var command = pipeline.commands[i];
        for (redirection in command.redirections) {
            match (open_redirection(redirection)) {
                OpenAttempt.ok(value) {
                    push(opened, value);
                    if (redirection.kind == syntax.RedirectionKind.input) {
                        stage_input = value;
                    } else {
                        stage_output = value;
                    }
                }
                OpenAttempt.failed(number) {
                    close_fds(opened);
                    return PrepareResult.failed(redirection_failure(redirection, number));
                }
            }
        }
        push(stages, PreparedStage { input: stage_input, output: stage_output });
    }

    return PrepareResult.ok(PreparedPipeline { stages: stages, opened: opened });
}

'''
    s = once(s, 'fn close_pipes(pipes: [][]fd.Fd) {\n', helper + 'fn close_pipes(pipes: [][]fd.Fd) {\n', 'executor IO preparation helpers')

    s = once(s,
'''fn rollback(children: []process.Child, group: ?process.Group, pipes: [][]fd.Fd, input: fd.Fd, output: fd.Fd, error: fd.Fd) {
    kill_children(children, group);
    close_pipes(pipes);
    close_stdio(input, output, error);
''',
'''fn rollback(children: []process.Child, group: ?process.Group, opened: []fd.Fd, pipes: [][]fd.Fd, input: fd.Fd, output: fd.Fd, error: fd.Fd) {
    kill_children(children, group);
    close_fds(opened);
    close_pipes(pipes);
    close_stdio(input, output, error);
''', 'rollback redirection handles')

    loop_old = '''    var children: []process.Child = [];
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
'''
    loop_new = '''    var prepared: PreparedPipeline;
    match (prepare_stages(pipeline, input, output, pipes)) {
        PrepareResult.failed(problem) {
            close_pipes(pipes);
            close_stdio(input, output, error);
            return LaunchResult.redirection_failed(problem);
        }
        PrepareResult.ok(value) { prepared = value; }
    }

    var children: []process.Child = [];
    var group: ?process.Group = none;

    for (var i: u64 = 0; i < len(pipeline.commands); i += 1) {
        var command = pipeline.commands[i];
        var stage = prepared.stages[i];
        match (spawn_command(command, stage.input, stage.output, error, group, terminal)) {
            SpawnAttempt.ok(child) {
                push(children, child);
                if (i == 0) { group = some(process.group(child)); }
            }
            SpawnAttempt.not_found {
                rollback(children, group, prepared.opened, pipes, input, output, error);
                return LaunchResult.invalid("command could not be resolved");
            }
            SpawnAttempt.failed(number) {
                rollback(children, group, prepared.opened, pipes, input, output, error);
                return LaunchResult.launch_failed(failure(command, number));
            }
        }
    }

    close_fds(prepared.opened);
    close_pipes(pipes);
    close_stdio(input, output, error);
    return LaunchResult.ok(LiveJob { children: children, group: group });
'''
    s = once(s, loop_old, loop_new, 'launch prepared redirections')

    s = once(s,
'''        LaunchResult.launch_failed(problem) {
            return ExecResult.launch_failed(problem);
        }
        LaunchResult.invalid(message) {
''',
'''        LaunchResult.launch_failed(problem) {
            return ExecResult.launch_failed(problem);
        }
        LaunchResult.redirection_failed(problem) {
            return ExecResult.redirection_failed(problem);
        }
        LaunchResult.invalid(message) {
''', 'run redirection propagation')
    return s


def main_file(s: str) -> str:
    s = once(s,
'''        executor.LaunchResult.launch_failed(failure) {
            if (!enable_editor_terminal(ui)) { return 125; }
            write_safe("lsh: could not launch ");
            write_safe(failure.command);
            write_safe(" (errno ");
            write_safe(strconv.format_i64(failure.error_number));
            write_line(")");
            return 126;
        }
        executor.LaunchResult.ok(live) {
''',
'''        executor.LaunchResult.launch_failed(failure) {
            if (!enable_editor_terminal(ui)) { return 125; }
            write_safe("lsh: could not launch ");
            write_safe(failure.command);
            write_safe(" (errno ");
            write_safe(strconv.format_i64(failure.error_number));
            write_line(")");
            return 126;
        }
        executor.LaunchResult.redirection_failed(failure) {
            if (!enable_editor_terminal(ui)) { return 125; }
            write_safe("lsh: could not open ");
            write_safe(failure.path);
            write_safe(" (errno ");
            write_safe(strconv.format_i64(failure.error_number));
            write_line(")");
            return 1;
        }
        executor.LaunchResult.ok(live) {
''', 'interactive redirection failure')

    # Stateful/interactive builtins currently write through the shell UI rather
    # than process FDs. Reject redirections explicitly instead of silently
    # ignoring them until builtin IO is generalized.
    marker = 'fn execute(ui: ref Ui, pipeline: syntax.Pipeline) {\n'
    helper = '''fn has_redirections(pipeline: syntax.Pipeline) -> bool {\n    for (command in pipeline.commands) {\n        if (len(command.redirections) != 0) { return true; }\n    }\n    return false;\n}\n\nfn redirection_rejected_builtin(pipeline: syntax.Pipeline) -> bool {\n    if (!has_redirections(pipeline)) { return false; }\n    return first_command_is(pipeline, "exit") || first_command_is(pipeline, "jobs") ||\n        first_command_is(pipeline, "fg") || first_command_is(pipeline, "bg") ||\n        first_command_is(pipeline, "cd") || first_command_is(pipeline, "env");\n}\n\n'''
    s = once(s, marker, helper + marker, 'builtin redirection guard helper')
    s = once(s,
'''    finish_prompt(ui);

    if (first_command_is(pipeline, "exit")) {
''',
'''    finish_prompt(ui);

    if (redirection_rejected_builtin(pipeline)) {
        write_line("lsh: redirection for shell builtins is not implemented yet");
        history.record(ui.history, command_text, cwd_before, 2, 0);
        ui.last_status = 2;
        editor.reset(ui.editor);
        return;
    }

    if (first_command_is(pipeline, "exit")) {
''', 'builtin redirection guard')
    return s


def executor_test(s: str) -> str:
    s = s.replace('        executor.LaunchResult.launch_failed(_) { trap; }\n        executor.LaunchResult.invalid(_) { trap; }',
                  '        executor.LaunchResult.launch_failed(_) { trap; }\n        executor.LaunchResult.redirection_failed(_) { trap; }\n        executor.LaunchResult.invalid(_) { trap; }')
    s = s.replace('        executor.ExecResult.launch_failed(_) { trap; }\n        executor.ExecResult.invalid(_) { trap; }',
                  '        executor.ExecResult.launch_failed(_) { trap; }\n        executor.ExecResult.redirection_failed(_) { trap; }\n        executor.ExecResult.invalid(_) { trap; }')
    s = s.replace('        executor.ExecResult.invalid(_) {}\n        executor.ExecResult.launch_failed(_) { trap; }\n        executor.ExecResult.ok(_) { trap; }',
                  '        executor.ExecResult.invalid(_) {}\n        executor.ExecResult.launch_failed(_) { trap; }\n        executor.ExecResult.redirection_failed(_) { trap; }\n        executor.ExecResult.ok(_) { trap; }')
    s = s.replace('        executor.LaunchResult.launch_failed(failure) { require(failure.error_number > 0); }\n        executor.LaunchResult.ok(_) { trap; }\n        executor.LaunchResult.invalid(_) { trap; }',
                  '        executor.LaunchResult.launch_failed(failure) { require(failure.error_number > 0); }\n        executor.LaunchResult.redirection_failed(_) { trap; }\n        executor.LaunchResult.ok(_) { trap; }\n        executor.LaunchResult.invalid(_) { trap; }')
    s = s.replace('        executor.LaunchResult.invalid(_) {}\n        executor.LaunchResult.launch_failed(_) { trap; }\n        executor.LaunchResult.ok(_) { trap; }',
                  '        executor.LaunchResult.invalid(_) {}\n        executor.LaunchResult.launch_failed(_) { trap; }\n        executor.LaunchResult.redirection_failed(_) { trap; }\n        executor.LaunchResult.ok(_) { trap; }')
    insert = r'''
fn test_output_redirection() {
    match (executor.run(parse_ready("/usr/bin/printf hello>/dev/null"))) {
        executor.ExecResult.ok(job) {
            require(len(job.processes) == 1);
            require_exited(job.processes[0], 0);
        }
        executor.ExecResult.launch_failed(_) { trap; }
        executor.ExecResult.redirection_failed(_) { trap; }
        executor.ExecResult.invalid(_) { trap; }
    }
}

fn test_redirection_failure_before_launch() {
    match (executor.launch(parse_ready("/usr/bin/cat</definitely/no-such-lsh-redirection-input"))) {
        executor.LaunchResult.redirection_failed(problem) {
            require(problem.error_number > 0);
        }
        executor.LaunchResult.launch_failed(_) { trap; }
        executor.LaunchResult.ok(_) { trap; }
        executor.LaunchResult.invalid(_) { trap; }
    }
}

fn test_pipeline_output_override() {
    match (executor.run(parse_ready("/usr/bin/printf hidden>/dev/null|/usr/bin/cat"))) {
        executor.ExecResult.ok(job) {
            require(len(job.processes) == 2);
            require_exited(job.processes[0], 0);
            require_exited(job.processes[1], 0);
        }
        executor.ExecResult.launch_failed(_) { trap; }
        executor.ExecResult.redirection_failed(_) { trap; }
        executor.ExecResult.invalid(_) { trap; }
    }
}

'''
    s = once(s, 'fn main() -> i64 {\n', insert + 'fn main() -> i64 {\n', 'executor redirection tests')
    s = once(s,
'''    test_partial_path_miss_rollback();
    return 0;
''',
'''    test_partial_path_miss_rollback();
    test_output_redirection();
    test_redirection_failure_before_launch();
    test_pipeline_output_override();
    return 0;
''', 'executor redirection test calls')
    return s


def shell_pty(s: str) -> str:
    needle = '''        # Ctrl-C is generated by the tty driver for the child's foreground pgrp;
'''
    block = '''        # Redirections are parsed as shell syntax even without surrounding
        # whitespace and lower directly to owned FDs, never through /bin/sh.
        transcript += send(fd, b"printf redir-one>redir.txt\\r")
        transcript += send(fd, b"printf +two>>redir.txt\\r")
        chunk = send(fd, b"cat<redir.txt\\r")
        transcript += chunk
        assert b"redir-one+two" in strip_control(chunk), strip_control(chunk[-3000:])

        # A command redirection overrides the pipeline's default stdout. The
        # downstream stage receives EOF while the redirected file gets bytes.
        chunk = send(fd, b"printf hidden>pipe.txt|wc -c\\r")
        transcript += chunk
        clean = strip_control(chunk)
        assert b"0" in clean, clean[-3000:]
        chunk = send(fd, b"cat<pipe.txt\\r")
        transcript += chunk
        assert b"hidden" in strip_control(chunk), strip_control(chunk[-3000:])

        # Redirection setup failures happen before foreground launch, so the
        # shell retains tty ownership and immediately remains usable.
        chunk = send(fd, b"cat</definitely/no-such-lsh-redirection-input\\r")
        transcript += chunk
        assert b"could not open" in strip_control(chunk), strip_control(chunk[-3000:])
        transcript += send(fd, b"true\\r")

'''
    return once(s, needle, block + needle, 'interactive redirection PTY tests')


edit('tools/shell/syntax.l', syntax_file)
edit('tools/shell/executor.l', executor_file)
edit('tools/shell/main.l', main_file)
edit('tools/shell/executor_test.l', executor_test)
edit('tests/shell_pty.py', shell_pty)
