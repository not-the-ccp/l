import bytes;
import presentation;

fn require(ok: bool) {
    if (!ok) {
        trap;
    }
}

fn require_span(span_start: u64, span_end: u64, expected_start: u64, expected_end: u64) {
    require(span_start == expected_start);
    require(span_end == expected_end);
}

fn main() -> i64 {
    var basic = presentation.analyze_input("printf \"hello world\" | wc -c");
    require(!basic.needs_continuation);
    require(len(basic.highlights) == 5);
    require(basic.highlights[0].role == presentation.HighlightRole.command);
    require_span(basic.highlights[0].span.start, basic.highlights[0].span.end, 0, 6);
    require(basic.highlights[1].role == presentation.HighlightRole.quoted_argument);
    require_span(basic.highlights[1].span.start, basic.highlights[1].span.end, 7, 20);
    require(basic.highlights[2].role == presentation.HighlightRole.command);
    require(basic.highlights[3].role == presentation.HighlightRole.argument);
    require(basic.highlights[4].role == presentation.HighlightRole.pipe);
    match (basic.diagnostic) {
        none {}
        some(_) { trap; }
    }

    var partial = presentation.analyze_input("printf x | grep \"need");
    require(partial.needs_continuation);
    require(len(partial.highlights) == 5);
    match (partial.diagnostic) {
        some(problem) {
            require(problem.kind == presentation.DiagnosticKind.incomplete);
            require(bytes.equal(problem.message, "close double quote"));
            require_span(problem.span.start, problem.span.end, 16, 21);
        }
        none { trap; }
    }

    var trailing = presentation.analyze_input("printf x |");
    require(trailing.needs_continuation);
    match (trailing.diagnostic) {
        some(problem) {
            require(bytes.equal(problem.message, "continue pipeline"));
        }
        none { trap; }
    }

    var bad = presentation.analyze_input("| printf");
    require(!bad.needs_continuation);
    match (bad.diagnostic) {
        some(problem) {
            require(problem.kind == presentation.DiagnosticKind.error);
        }
        none { trap; }
    }
    return 0;
}
