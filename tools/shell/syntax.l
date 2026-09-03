import bytes;

pub struct Span {
    pub start: u64,
    pub end: u64,
}

pub enum FragmentKind {
    bare,
    single_quoted,
    double_quoted,
}

pub struct Fragment {
    pub kind: FragmentKind,
    pub text: []u8,
    pub span: Span,
}

pub struct Word {
    pub value: []u8,
    pub fragments: []Fragment,
    pub span: Span,
}

pub struct Command {
    pub words: []Word,
    pub span: Span,
}

pub struct Pipeline {
    pub commands: []Command,
    // Pipe spans are retained for parser-backed highlighting. A complete
    // non-empty pipeline has one fewer pipe than command; a partial pipeline
    // ending in `|` has one pipe per completed command.
    pub pipes: []Span,
    pub span: Span,
}

pub enum IncompleteKind {
    single_quote,
    double_quote,
    pipeline,
}

pub struct Incomplete {
    pub kind: IncompleteKind,
    pub span: Span,
}

pub struct PartialParse {
    pub pipeline: Pipeline,
    pub reason: Incomplete,
}

pub struct ParseError {
    pub message: []u8,
    pub span: Span,
}

pub enum ParseResult {
    ready(Pipeline),
    incomplete(PartialParse),
    error(ParseError),
}

enum TokenKind {
    word,
    pipe,
}

struct Token {
    kind: TokenKind,
    word: ?Word,
    span: Span,
}

struct ScannedWord {
    word: Word,
    incomplete: ?Incomplete,
}

struct Lexed {
    tokens: []Token,
    incomplete: ?Incomplete,
}

fn append_bytes(dst: []u8, src: const []u8) {
    bytes.append(dst, src);
}

fn push_fragment(fragments: []Fragment, value: []u8, kind: FragmentKind, start: u64, end: u64) {
    push(fragments, Fragment {
        kind: kind,
        text: value,
        span: Span { start: start, end: end },
    });
}

fn scan_word(input: const []u8, start: u64) -> ScannedWord {
    var value: []u8 = [];
    var fragments: []Fragment = [];
    var i = start;
    var incomplete: ?Incomplete = none;

    while (i < len(input) && !bytes.is_ascii_space(input[i])) {
        if (input[i] == 39) {
            var quote_start = i;
            i += 1;
            var part: []u8 = [];
            while (i < len(input) && input[i] != 39) {
                push(part, input[i]);
                i += 1;
            }
            if (i >= len(input)) {
                append_bytes(value, part);
                push_fragment(fragments, part, FragmentKind.single_quoted, quote_start, len(input));
                incomplete = some(Incomplete {
                    kind: IncompleteKind.single_quote,
                    span: Span { start: quote_start, end: len(input) },
                });
                break;
            }
            i += 1;
            append_bytes(value, part);
            push_fragment(fragments, part, FragmentKind.single_quoted, quote_start, i);
            continue;
        }

        if (input[i] == '"') {
            var quote_start = i;
            i += 1;
            var part: []u8 = [];
            while (i < len(input) && input[i] != '"') {
                if (input[i] == '\\' && i + 1 < len(input) && (input[i + 1] == '"' || input[i + 1] == '\\')) {
                    push(part, input[i + 1]);
                    i += 2;
                } else {
                    push(part, input[i]);
                    i += 1;
                }
            }
            if (i >= len(input)) {
                append_bytes(value, part);
                push_fragment(fragments, part, FragmentKind.double_quoted, quote_start, len(input));
                incomplete = some(Incomplete {
                    kind: IncompleteKind.double_quote,
                    span: Span { start: quote_start, end: len(input) },
                });
                break;
            }
            i += 1;
            append_bytes(value, part);
            push_fragment(fragments, part, FragmentKind.double_quoted, quote_start, i);
            continue;
        }

        var bare_start = i;
        var part: []u8 = [];
        while (i < len(input) && !bytes.is_ascii_space(input[i]) && input[i] != 39 && input[i] != '"') {
            push(part, input[i]);
            i += 1;
        }
        append_bytes(value, part);
        push_fragment(fragments, part, FragmentKind.bare, bare_start, i);
    }

    return ScannedWord {
        word: Word {
            value: value,
            fragments: fragments,
            span: Span { start: start, end: i },
        },
        incomplete: incomplete,
    };
}

fn word_token(word: Word) -> Token {
    if (len(word.fragments) == 1 && word.fragments[0].kind == FragmentKind.bare && bytes.equal(word.value, "|")) {
        return Token { kind: TokenKind.pipe, word: none, span: word.span };
    }
    return Token { kind: TokenKind.word, word: some(word), span: word.span };
}

fn lex(input: const []u8) -> Lexed {
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

        var scanned = scan_word(input, i);
        push(tokens, word_token(scanned.word));
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

fn token_word(token: Token) -> Word {
    match (token.word) {
        some(word) {
            return word;
        }
        none {
            trap;
        }
    }
}

fn partial(pipeline: Pipeline, reason: Incomplete) -> ParseResult {
    return ParseResult.incomplete(PartialParse {
        pipeline: pipeline,
        reason: reason,
    });
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
    var command_start: u64 = 0;

    for (var i: u64 = 0; i < len(tokens); i += 1) {
        var token = tokens[i];
        if (token.kind == TokenKind.word) {
            var word = token_word(token);
            if (len(words) == 0) {
                command_start = word.span.start;
            }
            push(words, word);
            continue;
        }

        if (len(words) == 0) {
            return ParseResult.error(ParseError {
                message: "pipeline contains an empty command",
                span: token.span,
            });
        }

        push(commands, Command {
            words: words,
            span: Span { start: command_start, end: words[len(words) - 1].span.end },
        });
        push(pipes, token.span);
        words = [];

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
        trap;
    }
    push(commands, Command {
        words: words,
        span: Span { start: command_start, end: words[len(words) - 1].span.end },
    });
    return ParseResult.ready(Pipeline {
        commands: commands,
        pipes: pipes,
        span: Span { start: tokens[0].span.start, end: tokens[len(tokens) - 1].span.end },
    });
}

pub fn parse(input: const []u8) -> ParseResult {
    var lexed = lex(input);
    var structural = parse_tokens(lexed.tokens, len(input));

    match (structural) {
        ParseResult.error(problem) {
            return ParseResult.error(problem);
        }
        ParseResult.incomplete(value) {
            // Structural incompleteness (currently a trailing pipe) already
            // carries the useful partial pipeline. A lexical incomplete after
            // it is impossible because an unfinished word would follow the pipe.
            return ParseResult.incomplete(value);
        }
        ParseResult.ready(pipeline) {
            match (lexed.incomplete) {
                some(reason) {
                    return partial(pipeline, reason);
                }
                none {
                    return ParseResult.ready(pipeline);
                }
            }
        }
    }
}

fn require(ok: bool) {
    if (!ok) {
        trap;
    }
}

fn require_bytes(actual: const []u8, expected: const []u8) {
    require(bytes.equal(actual, expected));
}

fn expect_ready(input: const []u8) -> Pipeline {
    match (parse(input)) {
        ParseResult.ready(value) {
            return value;
        }
        ParseResult.incomplete(_) {
            trap;
        }
        ParseResult.error(_) {
            trap;
        }
    }
}

fn expect_incomplete(input: const []u8, kind: IncompleteKind) -> PartialParse {
    match (parse(input)) {
        ParseResult.incomplete(value) {
            require(value.reason.kind == kind);
            return value;
        }
        ParseResult.ready(_) {
            trap;
        }
        ParseResult.error(_) {
            trap;
        }
    }
}

fn expect_error(input: const []u8) {
    match (parse(input)) {
        ParseResult.error(_) {}
        ParseResult.ready(_) {
            trap;
        }
        ParseResult.incomplete(_) {
            trap;
        }
    }
}

pub fn self_test() {
    var empty = expect_ready("   \n\t");
    require(len(empty.commands) == 0);
    require(len(empty.pipes) == 0);

    var simple = expect_ready("git status");
    require(len(simple.commands) == 1);
    require(len(simple.pipes) == 0);
    require(len(simple.commands[0].words) == 2);
    require_bytes(simple.commands[0].words[0].value, "git");
    require_bytes(simple.commands[0].words[1].value, "status");
    require(simple.commands[0].words[0].span.start == 0);
    require(simple.commands[0].words[0].span.end == 3);

    var pipeline = expect_ready("printf \"hello world\" | wc -c");
    require(len(pipeline.commands) == 2);
    require(len(pipeline.pipes) == 1);
    require_bytes(pipeline.commands[0].words[1].value, "hello world");
    require(pipeline.commands[0].words[1].fragments[0].kind == FragmentKind.double_quoted);
    require(pipeline.commands[0].words[1].fragments[0].span.start == 7);
    require(pipeline.commands[0].words[1].fragments[0].span.end == 20);
    require(pipeline.pipes[0].start == 21);
    require(pipeline.pipes[0].end == 22);

    var joined = expect_ready("echo pre\"middle space\"post");
    require_bytes(joined.commands[0].words[1].value, "premiddle spacepost");
    require(len(joined.commands[0].words[1].fragments) == 3);
    require(joined.commands[0].words[1].fragments[0].kind == FragmentKind.bare);
    require(joined.commands[0].words[1].fragments[1].kind == FragmentKind.double_quoted);
    require(joined.commands[0].words[1].fragments[2].kind == FragmentKind.bare);

    var raw = expect_ready("jq '.foo | .bar > \"x\"' data.json");
    require(len(raw.commands) == 1);
    require_bytes(raw.commands[0].words[1].value, ".foo | .bar > \"x\"");
    require(raw.commands[0].words[1].fragments[0].kind == FragmentKind.single_quoted);

    var punctuation = expect_ready("echo a|b x>y foo&bar >output");
    require(len(punctuation.commands) == 1);
    require_bytes(punctuation.commands[0].words[1].value, "a|b");
    require_bytes(punctuation.commands[0].words[2].value, "x>y");
    require_bytes(punctuation.commands[0].words[3].value, "foo&bar");
    require_bytes(punctuation.commands[0].words[4].value, ">output");

    var quoted_pipe = expect_ready("echo \"|\" '|'");
    require(len(quoted_pipe.commands) == 1);
    require_bytes(quoted_pipe.commands[0].words[1].value, "|");
    require_bytes(quoted_pipe.commands[0].words[2].value, "|");

    var escaped = expect_ready("echo \"a\\\"b\\\\c\"");
    require_bytes(escaped.commands[0].words[1].value, "a\"b\\c");

    var single_partial = expect_incomplete("echo 'unterminated", IncompleteKind.single_quote);
    require(len(single_partial.pipeline.commands) == 1);
    require(len(single_partial.pipeline.commands[0].words) == 2);
    require_bytes(single_partial.pipeline.commands[0].words[1].value, "unterminated");
    require(single_partial.pipeline.commands[0].words[1].fragments[0].kind == FragmentKind.single_quoted);

    var double_partial = expect_incomplete("printf x | grep \"needle", IncompleteKind.double_quote);
    require(len(double_partial.pipeline.commands) == 2);
    require(len(double_partial.pipeline.pipes) == 1);
    require_bytes(double_partial.pipeline.commands[1].words[1].value, "needle");

    var pipe_partial = expect_incomplete("cat |   \n", IncompleteKind.pipeline);
    require(len(pipe_partial.pipeline.commands) == 1);
    require(len(pipe_partial.pipeline.pipes) == 1);
    require_bytes(pipe_partial.pipeline.commands[0].words[0].value, "cat");

    expect_error("| cat");
    expect_error("cat | | wc");
}
