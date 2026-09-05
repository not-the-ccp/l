import bytes;
import presentation;
import syntax;
import utf8;

pub struct Editor {
    pub buffer: []u8,
    // Cursor offsets are bytes because Unix arguments and paths are bytes. The
    // movement helpers treat valid UTF-8 scalars atomically while malformed
    // bytes remain individually editable.
    pub cursor: u64,
    pub parsed: syntax.ParseResult,
    pub analysis: presentation.Analysis,
    pub revision: u64,
    // A suggestion is the complete proposed line, not terminal ghost text.
    // Rendering derives the suffix from the current buffer.
    pub suggestion: []u8,
}

pub enum EnterResult {
    execute(syntax.Pipeline),
    continued,
    invalid(presentation.Diagnostic),
    empty,
}

fn refresh(editor: ref Editor) {
    var parsed = syntax.parse(editor.buffer);
    editor.parsed = parsed;
    editor.analysis = presentation.analyze(parsed);
    if (len(editor.suggestion) != 0 && (!bytes.starts_with(editor.suggestion, editor.buffer) || editor.cursor != len(editor.buffer))) {
        editor.suggestion = [];
    }
}

pub fn create() -> ref Editor {
    var buffer: []u8 = [];
    var parsed = syntax.parse(buffer);
    return new Editor {
        buffer: buffer,
        cursor: 0,
        parsed: parsed,
        analysis: presentation.analyze(parsed),
        revision: 0,
        suggestion: [],
    };
}

pub fn set_buffer(editor: ref Editor, value: const []u8) {
    editor.buffer = bytes.clone(value);
    editor.cursor = len(editor.buffer);
    editor.revision += 1;
    editor.suggestion = [];
    refresh(editor);
}

pub fn reset(editor: ref Editor) {
    set_buffer(editor, []);
}

fn replace(editor: ref Editor, start: u64, end: u64, value: const []u8, cursor_after: u64) {
    if (start > end || end > len(editor.buffer) || cursor_after > len(editor.buffer) - (end - start) + len(value)) {
        trap;
    }
    bytes.replace_range(editor.buffer, start, end, value);
    editor.cursor = cursor_after;
    editor.revision += 1;
    refresh(editor);
}

pub fn insert(editor: ref Editor, value: const []u8) {
    var start = editor.cursor;
    replace(editor, start, start, value, start + len(value));
}

pub fn insert_byte(editor: ref Editor, value: u8) {
    insert(editor, [value]);
}

pub fn backspace(editor: ref Editor) {
    if (editor.cursor == 0) {
        return;
    }
    var start = utf8.previous_boundary(editor.buffer, editor.cursor);
    replace(editor, start, editor.cursor, [], start);
}

pub fn delete_forward(editor: ref Editor) {
    if (editor.cursor >= len(editor.buffer)) {
        return;
    }
    var end = utf8.next_boundary(editor.buffer, editor.cursor);
    replace(editor, editor.cursor, end, [], editor.cursor);
}

pub fn move_left(editor: ref Editor) {
    editor.cursor = utf8.previous_boundary(editor.buffer, editor.cursor);
    refresh(editor);
}

pub fn move_right(editor: ref Editor) {
    editor.cursor = utf8.next_boundary(editor.buffer, editor.cursor);
    refresh(editor);
}

pub fn move_home(editor: ref Editor) {
    editor.cursor = bytes.line_start(editor.buffer, editor.cursor);
    refresh(editor);
}

pub fn move_end(editor: ref Editor) {
    editor.cursor = bytes.line_end(editor.buffer, editor.cursor);
    refresh(editor);
}

fn word_left_pipeline(pipeline: syntax.Pipeline, cursor: u64) -> u64 {
    var best: u64 = 0;
    var found = false;
    for (command in pipeline.commands) {
        for (word in command.words) {
            if (cursor > word.span.start && cursor <= word.span.end) {
                return word.span.start;
            }
            if (word.span.start < cursor) {
                best = word.span.start;
                found = true;
            }
        }
    }
    if (found) {
        return best;
    }
    return 0;
}

fn word_right_pipeline(pipeline: syntax.Pipeline, cursor: u64, length: u64) -> u64 {
    for (command in pipeline.commands) {
        for (word in command.words) {
            if (cursor < word.span.start) {
                return word.span.start;
            }
            if (cursor >= word.span.start && cursor < word.span.end) {
                return word.span.end;
            }
        }
    }
    return length;
}

pub fn move_word_left(editor: ref Editor) {
    match (editor.parsed) {
        syntax.ParseResult.ready(pipeline) {
            editor.cursor = word_left_pipeline(pipeline, editor.cursor);
        }
        syntax.ParseResult.incomplete(partial) {
            editor.cursor = word_left_pipeline(partial.pipeline, editor.cursor);
        }
        syntax.ParseResult.error(_) {
            editor.cursor = utf8.previous_boundary(editor.buffer, editor.cursor);
        }
    }
    refresh(editor);
}

pub fn move_word_right(editor: ref Editor) {
    match (editor.parsed) {
        syntax.ParseResult.ready(pipeline) {
            editor.cursor = word_right_pipeline(pipeline, editor.cursor, len(editor.buffer));
        }
        syntax.ParseResult.incomplete(partial) {
            editor.cursor = word_right_pipeline(partial.pipeline, editor.cursor, len(editor.buffer));
        }
        syntax.ParseResult.error(_) {
            editor.cursor = utf8.next_boundary(editor.buffer, editor.cursor);
        }
    }
    refresh(editor);
}

pub fn set_suggestion(editor: ref Editor, value: const []u8) {
    if (editor.cursor != len(editor.buffer) || len(value) <= len(editor.buffer) || !bytes.starts_with(value, editor.buffer)) {
        editor.suggestion = [];
        return;
    }
    editor.suggestion = bytes.clone(value);
}

pub fn suggestion_suffix(editor: ref Editor) -> []u8 {
    if (len(editor.suggestion) == 0 || !bytes.starts_with(editor.suggestion, editor.buffer)) {
        return [];
    }
    return bytes.slice(editor.suggestion, len(editor.buffer), len(editor.suggestion));
}

pub fn accept_suggestion(editor: ref Editor) {
    if (len(editor.suggestion) == 0) {
        return;
    }
    var value = bytes.clone(editor.suggestion);
    set_buffer(editor, value);
}

pub fn accept_suggestion_word(editor: ref Editor) {
    if (len(editor.suggestion) == 0 || !bytes.starts_with(editor.suggestion, editor.buffer) || editor.cursor != len(editor.buffer)) {
        return;
    }
    var end = len(editor.buffer);
    while (end < len(editor.suggestion) && bytes.is_ascii_space(editor.suggestion[end])) {
        end += 1;
    }
    while (end < len(editor.suggestion) && !bytes.is_ascii_space(editor.suggestion[end])) {
        end += 1;
    }
    var prefix = bytes.slice(editor.suggestion, 0, end);
    // Preserve the full suggestion so repeated word acceptance can continue.
    var full = bytes.clone(editor.suggestion);
    set_buffer(editor, prefix);
    if (len(full) > len(editor.buffer) && bytes.starts_with(full, editor.buffer)) {
        editor.suggestion = full;
    }
}

// Enter is parser-driven. Complete input is returned for execution, incomplete
// input becomes a real multiline buffer, and syntax errors remain editable
// rather than executing a best-effort interpretation.
pub fn enter(editor: ref Editor) -> EnterResult {
    match (editor.parsed) {
        syntax.ParseResult.ready(pipeline) {
            if (len(pipeline.commands) == 0) {
                return EnterResult.empty;
            }
            return EnterResult.execute(pipeline);
        }
        syntax.ParseResult.incomplete(_) {
            insert_byte(editor, '\n');
            return EnterResult.continued;
        }
        syntax.ParseResult.error(_) {
            match (editor.analysis.diagnostic) {
                some(problem) {
                    return EnterResult.invalid(problem);
                }
                none { trap; }
            }
        }
    }
}
