import bytes;
import tools.lace2.editor_model as model;
import tools.lace2.piece_tree as text;

fn expect(ok: bool) {
    if (!ok) { trap; }
}

fn expect_slice(editor: ref model.Editor, span_opt: ?model.Span, wanted: const []u8) {
    match (span_opt) {
        none { trap; }
        some(span) {
            if (!bytes.equal(text.slice(editor.doc, span.start, span.end), wanted)) { trap; }
        }
    }
}

fn main() {
    var words = model.create("one two three four\n");
    expect_slice(words, model.motion_span_count(words, 'w', 1), "one ");
    expect_slice(words, model.motion_span_count(words, 'w', 2), "one two ");
    expect_slice(words, model.motion_span_count(words, 'e', 2), "one two");
    expect_slice(words, model.change_motion_span(words, 'w', 1), "one");
    expect_slice(words, model.change_motion_span(words, 'w', 2), "one two");

    var spaces = model.create("  one two\n");
    expect_slice(spaces, model.change_motion_span(spaces, 'w', 1), "  ");
    expect_slice(spaces, model.change_motion_span(spaces, 'w', 2), "  one ");

    var lines = model.create("1\n2\n3\n4\n");
    var two = model.line_count_span(lines, 2);
    expect(bytes.equal(text.slice(lines.doc, two.start, two.end), "1\n2\n"));
    var all = model.line_count_span(lines, 999);
    expect(bytes.equal(text.slice(lines.doc, all.start, all.end), "1\n2\n3\n4\n"));

    // Counted `$` extends through the requested target line but preserves that
    // target line's terminator, matching an operator's half-open range.
    var dollars = model.create("abc\ndef\nghi\n");
    model.set_cursor(dollars, 1);
    expect_slice(dollars, model.motion_span_count(dollars, '$', 2), "bc\ndef");
}
