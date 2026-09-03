import bytes;
import syntax;

pub enum HighlightRole {
    command,
    argument,
    quoted_argument,
    pipe,
}

pub struct Highlight {
    pub role: HighlightRole,
    pub span: syntax.Span,
}

pub enum DiagnosticKind {
    incomplete,
    error,
}

pub struct Diagnostic {
    pub kind: DiagnosticKind,
    pub span: syntax.Span,
    pub message: []u8,
}

pub struct Analysis {
    pub highlights: []Highlight,
    pub diagnostic: ?Diagnostic,
    pub needs_continuation: bool,
}

fn add_word(out: []Highlight, word: syntax.Word, command_name: bool) {
    for (fragment in word.fragments) {
        var role = HighlightRole.argument;
        if (command_name) {
            role = HighlightRole.command;
        } else if (fragment.kind != syntax.FragmentKind.bare) {
            role = HighlightRole.quoted_argument;
        }
        push(out, Highlight { role: role, span: fragment.span });
    }
}

fn add_pipeline(out: []Highlight, pipeline: syntax.Pipeline) {
    for (command in pipeline.commands) {
        for (var i: u64 = 0; i < len(command.words); i += 1) {
            add_word(out, command.words[i], i == 0);
        }
    }
    for (span in pipeline.pipes) {
        push(out, Highlight { role: HighlightRole.pipe, span: span });
    }
}

fn incomplete_message(kind: syntax.IncompleteKind) -> []u8 {
    if (kind == syntax.IncompleteKind.single_quote) {
        return "close single quote";
    }
    if (kind == syntax.IncompleteKind.double_quote) {
        return "close double quote";
    }
    return "continue pipeline";
}

pub fn analyze(result: syntax.ParseResult) -> Analysis {
    var highlights: []Highlight = [];
    match (result) {
        syntax.ParseResult.ready(pipeline) {
            add_pipeline(highlights, pipeline);
            return Analysis {
                highlights: highlights,
                diagnostic: none,
                needs_continuation: false,
            };
        }
        syntax.ParseResult.incomplete(partial) {
            add_pipeline(highlights, partial.pipeline);
            return Analysis {
                highlights: highlights,
                diagnostic: some(Diagnostic {
                    kind: DiagnosticKind.incomplete,
                    span: partial.reason.span,
                    message: incomplete_message(partial.reason.kind),
                }),
                needs_continuation: true,
            };
        }
        syntax.ParseResult.error(problem) {
            return Analysis {
                highlights: highlights,
                diagnostic: some(Diagnostic {
                    kind: DiagnosticKind.error,
                    span: problem.span,
                    message: bytes.clone(problem.message),
                }),
                needs_continuation: false,
            };
        }
    }
}

pub fn analyze_input(input: const []u8) -> Analysis {
    return analyze(syntax.parse(input));
}
