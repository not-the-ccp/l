import bytes;

pub enum RedirectKind {
    out,
    err,
    all,
}

pub struct Redirect {
    pub kind: RedirectKind,
    pub path: []u8,
}

pub struct Command {
    pub argv: [][]u8,
    pub redirects: []Redirect,
}

pub struct Pipeline {
    pub commands: []Command,
    pub background: bool,
}

pub enum ParseResult {
    ok(Pipeline),
    error([]u8),
}

enum TokenKind {
    word,
    pipe,
    redirect_out,
    redirect_err,
    redirect_all,
    background,
}

struct Token {
    kind: TokenKind,
    text: []u8,
    start: u64,
    end: u64,
}

enum LexResult {
    ok([]Token),
    error([]u8),
}

fn at(input: []u8, start: u64, text: []u8) -> bool {
    if (start + len(text) > len(input)) {
        return false;
    }
    for (var i: u64 = 0; i < len(text); i += 1) {
        if (input[start + i] != text[i]) {
            return false;
        }
    }
    return true;
}

fn push_operator(tokens: []Token, kind: TokenKind, start: u64, end: u64) {
    push(tokens, Token { kind: kind, text: [], start: start, end: end });
}

fn lex(input: []u8) -> LexResult {
    var tokens: []Token = [];
    var i: u64 = 0;

    while (i < len(input)) {
        while (i < len(input) && bytes.is_ascii_space(input[i])) {
            i += 1;
        }
        if (i >= len(input)) {
            break;
        }

        var start = i;
        if (at(input, i, "err>")) {
            push_operator(tokens, TokenKind.redirect_err, i, i + 4);
            i += 4;
            continue;
        }
        if (at(input, i, "all>")) {
            push_operator(tokens, TokenKind.redirect_all, i, i + 4);
            i += 4;
            continue;
        }
        if (input[i] == '>') {
            push_operator(tokens, TokenKind.redirect_out, i, i + 1);
            i += 1;
            continue;
        }
        if (input[i] == '|') {
            push_operator(tokens, TokenKind.pipe, i, i + 1);
            i += 1;
            continue;
        }
        if (input[i] == '&') {
            push_operator(tokens, TokenKind.background, i, i + 1);
            i += 1;
            continue;
        }

        var word: []u8 = [];
        var saw = false;
        while (i < len(input)) {
            if (bytes.is_ascii_space(input[i]) || input[i] == '|' || input[i] == '&' || input[i] == '>') {
                break;
            }

            if (input[i] == '"') {
                saw = true;
                i += 1;
                var closed = false;
                while (i < len(input)) {
                    if (input[i] == '"') {
                        i += 1;
                        closed = true;
                        break;
                    }
                    if (input[i] == '\\' && i + 1 < len(input) && (input[i + 1] == '"' || input[i + 1] == '\\')) {
                        push(word, input[i + 1]);
                        i += 2;
                    } else {
                        push(word, input[i]);
                        i += 1;
                    }
                }
                if (!closed) {
                    return LexResult.error("unterminated quoted argument");
                }
                continue;
            }

            saw = true;
            push(word, input[i]);
            i += 1;
        }

        if (!saw) {
            return LexResult.error("unexpected shell syntax");
        }
        push(tokens, Token { kind: TokenKind.word, text: word, start: start, end: i });
    }

    return LexResult.ok(tokens);
}

fn redirect_kind(kind: TokenKind) -> RedirectKind {
    if (kind == TokenKind.redirect_out) {
        return RedirectKind.out;
    }
    if (kind == TokenKind.redirect_err) {
        return RedirectKind.err;
    }
    if (kind == TokenKind.redirect_all) {
        return RedirectKind.all;
    }
    trap;
}

fn parse_tokens(tokens: []Token) -> ParseResult {
    if (len(tokens) == 0) {
        return ParseResult.error("empty command");
    }

    var commands: []Command = [];
    var background = false;
    var i: u64 = 0;

    while (i < len(tokens)) {
        var argv: [][]u8 = [];
        var redirects: []Redirect = [];

        while (i < len(tokens) && tokens[i].kind != TokenKind.pipe && tokens[i].kind != TokenKind.background) {
            var token = tokens[i];
            if (token.kind == TokenKind.word) {
                push(argv, token.text);
                i += 1;
                continue;
            }

            if (token.kind == TokenKind.redirect_out || token.kind == TokenKind.redirect_err || token.kind == TokenKind.redirect_all) {
                if (i + 1 >= len(tokens) || tokens[i + 1].kind != TokenKind.word) {
                    return ParseResult.error("redirection requires one path argument");
                }
                push(redirects, Redirect { kind: redirect_kind(token.kind), path: tokens[i + 1].text });
                i += 2;
                continue;
            }

            return ParseResult.error("unexpected token in command");
        }

        if (len(argv) == 0) {
            return ParseResult.error("pipeline contains an empty command");
        }
        push(commands, Command { argv: argv, redirects: redirects });

        if (i >= len(tokens)) {
            break;
        }
        if (tokens[i].kind == TokenKind.pipe) {
            i += 1;
            if (i >= len(tokens)) {
                return ParseResult.error("pipeline cannot end with '|'");
            }
            continue;
        }
        if (tokens[i].kind == TokenKind.background) {
            background = true;
            i += 1;
            if (i != len(tokens)) {
                return ParseResult.error("'&' is only valid at the end of a job");
            }
            break;
        }
    }

    return ParseResult.ok(Pipeline { commands: commands, background: background });
}

pub fn parse(input: []u8) -> ParseResult {
    var result = lex(input);
    match (result) {
        LexResult.error(message) {
            return ParseResult.error(message);
        }
        LexResult.ok(tokens) {
            return parse_tokens(tokens);
        }
    }
}

fn append_word(out: []u8, word: []u8) {
    push(out, '[');
    bytes.append(out, word);
    push(out, ']');
}

fn append_redirect(out: []u8, redirect: Redirect) {
    if (redirect.kind == RedirectKind.out) {
        bytes.append(out, " > ");
    } else {
        if (redirect.kind == RedirectKind.err) {
            bytes.append(out, " err> ");
        } else {
            bytes.append(out, " all> ");
        }
    }
    append_word(out, redirect.path);
}

pub fn describe(pipeline: Pipeline) -> []u8 {
    var out: []u8 = [];
    if (pipeline.background) {
        bytes.append(out, "background: ");
    } else {
        bytes.append(out, "foreground: ");
    }

    for (var ci: u64 = 0; ci < len(pipeline.commands); ci += 1) {
        if (ci != 0) {
            bytes.append(out, " | ");
        }
        var command = pipeline.commands[ci];
        for (var ai: u64 = 0; ai < len(command.argv); ai += 1) {
            if (ai != 0) {
                push(out, ' ');
            }
            append_word(out, command.argv[ai]);
        }
        for (redirect in command.redirects) {
            append_redirect(out, redirect);
        }
    }
    return out;
}

fn require(value: bool) {
    if (!value) {
        trap;
    }
}

fn require_bytes(actual: []u8, expected: []u8) {
    require(bytes.equal(actual, expected));
}

fn expect_ok(input: []u8) -> Pipeline {
    var result = parse(input);
    match (result) {
        ParseResult.ok(value) {
            return value;
        }
        ParseResult.error(_) {
            trap;
        }
    }
}

fn expect_error(input: []u8) {
    var result = parse(input);
    match (result) {
        ParseResult.ok(_) {
            trap;
        }
        ParseResult.error(_) {
            return;
        }
    }
}

pub fn self_test() {
    var simple = expect_ok("git status");
    require(len(simple.commands) == 1);
    require(!simple.background);
    require(len(simple.commands[0].argv) == 2);
    require_bytes(simple.commands[0].argv[0], "git");
    require_bytes(simple.commands[0].argv[1], "status");

    var quoted = expect_ok("printf \"hello world\"|wc -c");
    require(len(quoted.commands) == 2);
    require_bytes(quoted.commands[0].argv[1], "hello world");
    require_bytes(quoted.commands[1].argv[0], "wc");
    require_bytes(quoted.commands[1].argv[1], "-c");

    var joined = expect_ok("echo pre\"middle space\"post");
    require(len(joined.commands[0].argv) == 2);
    require_bytes(joined.commands[0].argv[1], "premiddle spacepost");

    var redirected = expect_ok("build err>errors.log all>everything.log >output.log &");
    require(redirected.background);
    require(len(redirected.commands[0].redirects) == 3);
    require(redirected.commands[0].redirects[0].kind == RedirectKind.err);
    require_bytes(redirected.commands[0].redirects[0].path, "errors.log");
    require(redirected.commands[0].redirects[1].kind == RedirectKind.all);
    require(redirected.commands[0].redirects[2].kind == RedirectKind.out);

    var escaped = expect_ok("echo \"a\\\"b\\\\c\"");
    require_bytes(escaped.commands[0].argv[1], "a\"b\\c");

    expect_error("");
    expect_error("| cat");
    expect_error("cat |");
    expect_error("cat >");
    expect_error("cat & next");
    expect_error("echo \"unterminated");
}
