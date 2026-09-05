import bytes;
import editor;
import presentation;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn main() -> i64 {
    var line = editor.create();
    require(len(line.buffer) == 0);
    require(line.cursor == 0);
    match (editor.enter(line)) {
        editor.EnterResult.empty {}
        _ { trap; }
    }

    editor.insert(line, "echo");
    require(bytes.equal(line.buffer, "echo"));
    require(line.cursor == 4);
    editor.set_suggestion(line, "echo hello world");
    require(bytes.equal(editor.suggestion_suffix(line), " hello world"));
    editor.accept_suggestion_word(line);
    require(bytes.equal(line.buffer, "echo hello"));
    require(bytes.equal(editor.suggestion_suffix(line), " world"));
    editor.accept_suggestion(line);
    require(bytes.equal(line.buffer, "echo hello world"));
    require(line.cursor == len(line.buffer));

    editor.move_word_left(line);
    require(line.cursor == 11);
    editor.move_word_left(line);
    require(line.cursor == 5);
    editor.move_word_right(line);
    require(line.cursor == 10);
    editor.move_word_right(line);
    require(line.cursor == 11);

    editor.set_suggestion(line, "echo hello world again");
    require(len(line.suggestion) == 0); // suggestions only appear at end-of-line
    editor.move_end(line);
    editor.set_suggestion(line, "echo hello world again");
    require(len(line.suggestion) != 0);
    editor.move_left(line);
    require(len(line.suggestion) == 0);

    // Enter follows the execution parser. A trailing pipeline becomes a
    // multiline buffer instead of a syntax error or accidental execution.
    editor.set_buffer(line, "printf x |");
    match (editor.enter(line)) {
        editor.EnterResult.continued {}
        _ { trap; }
    }
    require(bytes.equal(line.buffer, "printf x |\n"));
    require(line.analysis.needs_continuation);
    editor.insert(line, "wc -c");
    require(!line.analysis.needs_continuation);
    match (editor.enter(line)) {
        editor.EnterResult.execute(pipeline) {
            require(len(pipeline.commands) == 2);
        }
        _ { trap; }
    }

    // Quotes continue across the inserted newline and keep their exact source
    // span in the shared parser/presentation model.
    editor.set_buffer(line, "printf \"hello");
    match (editor.enter(line)) {
        editor.EnterResult.continued {}
        _ { trap; }
    }
    editor.insert(line, "world\"");
    require(!line.analysis.needs_continuation);

    editor.set_buffer(line, "| printf");
    match (editor.enter(line)) {
        editor.EnterResult.invalid(problem) {
            require(problem.kind == presentation.DiagnosticKind.error);
        }
        _ { trap; }
    }
    require(bytes.equal(line.buffer, "| printf"));

    // Valid UTF-8 scalars move atomically even though the canonical cursor is a
    // byte offset.
    editor.set_buffer(line, ['a', 0xf0, 0x9f, 0x98, 0x80, 'b']);
    require(line.cursor == 6);
    editor.move_left(line);
    require(line.cursor == 5);
    editor.move_left(line);
    require(line.cursor == 1);
    editor.move_right(line);
    require(line.cursor == 5);
    editor.delete_forward(line);
    require(bytes.equal(line.buffer, ['a', 0xf0, 0x9f, 0x98, 0x80]));

    // Malformed bytes are never swallowed as fake characters: each remains
    // independently reachable and deletable.
    editor.set_buffer(line, [0xc0, 0x80]);
    editor.backspace(line);
    require(bytes.equal(line.buffer, [0xc0]));
    require(line.cursor == 1);
    editor.backspace(line);
    require(len(line.buffer) == 0);
    require(line.cursor == 0);

    var before = line.revision;
    editor.insert(line, "abc");
    require(line.revision == before + 1);
    editor.reset(line);
    require(len(line.buffer) == 0);
    return 0;
}
