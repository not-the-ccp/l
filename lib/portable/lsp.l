import arrays;
import bytes;
import json;
import strconv;
import utf8;

pub struct FrameBuffer {
    data: []u8,
}

pub struct Position {
    pub line: u64,
    pub character: u64,
}

pub struct Range {
    pub start: Position,
    pub end: Position,
}

pub struct Diagnostic {
    pub range: Range,
    pub message: []u8,
    pub severity: u64,
}

pub struct SemanticToken {
    pub line: u64,
    pub start: u64,
    pub length: u64,
    pub token_type: u64,
}

pub struct Symbol {
    pub name: []u8,
    pub kind: u64,
    pub range: Range,
    pub selection: Range,
}

pub struct Document {
    pub uri: []u8,
    pub text: []u8,
    pub lines: []u64,
    pub version: i64,
}

pub struct Documents {
    docs: []ref Document,
}

pub enum Message {
    request(json.Json, []u8, json.Json),
    notification([]u8, json.Json),
    response(json.Json, json.Json),
    invalid([]u8),
}

pub fn frame_buffer() -> ref FrameBuffer {
    return new FrameBuffer { data: [] };
}

pub fn frame_feed(reader: ref FrameBuffer, chunk: []u8) {
    bytes.append(reader.data, chunk);
}

fn header_length(header: []u8) -> ?u64 {
    var line_start: u64 = 0;
    while (line_start < len(header)) {
        var line_end_opt = bytes.find(header, "\r\n", line_start);
        var line_end = len(header);
        match (line_end_opt) {
            none { }
            some(value) { line_end = value; }
        }
        var line = bytes.slice(header, line_start, line_end);
        if (bytes.starts_with(line, "Content-Length:")) {
            var raw = bytes.trim_ascii(bytes.slice(line, 15, len(line)));
            return strconv.parse_u64(raw);
        }
        if (line_end == len(header)) { break; }
        line_start = line_end + 2;
    }
    return none;
}

pub fn frame_take(reader: ref FrameBuffer) -> ?[]u8 {
    var sep_opt = bytes.find(reader.data, "\r\n\r\n", 0);
    match (sep_opt) {
        none { return none; }
        some(sep) {
            var header = bytes.slice(reader.data, 0, sep);
            var length_opt = header_length(header);
            match (length_opt) {
                none { trap; }
                some(body_length) {
                    var body_start = sep + 4;
                    if (body_start + body_length > len(reader.data)) { return none; }
                    var body = bytes.slice(reader.data, body_start, body_start + body_length);
                    var rest = bytes.slice(reader.data, body_start + body_length, len(reader.data));
                    arrays.clear(reader.data);
                    bytes.append(reader.data, rest);
                    return some(body);
                }
            }
        }
    }
}

pub fn frame_encode(body: []u8) -> []u8 {
    var out: []u8 = [];
    bytes.append(out, "Content-Length: ");
    strconv.append_u64(out, len(body));
    bytes.append(out, "\r\n\r\n");
    bytes.append(out, body);
    return out;
}

pub fn documents() -> ref Documents {
    return new Documents { docs: [] };
}

fn find_doc_index(store: ref Documents, uri: []u8) -> ?u64 {
    for (var i: u64 = 0; i < len(store.docs); i += 1) {
        if (bytes.equal(store.docs[i].uri, uri)) { return some(i); }
    }
    return none;
}

pub fn document_get(store: ref Documents, uri: []u8) -> ?ref Document {
    var index_opt = find_doc_index(store, uri);
    match (index_opt) {
        none { return none; }
        some(index) { return some(store.docs[index]); }
    }
}

fn line_index(text: []u8) -> []u64 {
    var lines: []u64 = [0];
    for (var i: u64 = 0; i < len(text); i += 1) {
        if (text[i] == '\n') { push(lines, i + 1); }
    }
    return lines;
}

pub fn document_offset(doc: ref Document, pos: Position) -> u64 {
    if (pos.line >= len(doc.lines)) { return len(doc.text); }
    var start = doc.lines[pos.line];
    var end = len(doc.text);
    if (pos.line + 1 < len(doc.lines)) {
        end = doc.lines[pos.line + 1];
        if (end > start && doc.text[end - 1] == '\n') { end -= 1; }
    }
    var line = bytes.slice(doc.text, start, end);
    return start + utf8.utf16_to_byte(line, pos.character);
}

pub fn document_apply_change(doc: ref Document, value: Range, replacement: []u8) {
    var start = document_offset(doc, value.start);
    var end = document_offset(doc, value.end);
    if (start > end || end > len(doc.text)) { trap; }
    var start_line = value.start.line;
    if (start_line >= len(doc.lines)) { start_line = len(doc.lines) - 1; }
    var old_len = end - start;
    var new_len = len(replacement);

    var remove_from = start_line + 1;
    var remove_to = remove_from;
    while (remove_to < len(doc.lines) && doc.lines[remove_to] <= end) { remove_to += 1; }

    var inserted: []u64 = [];
    for (var i: u64 = 0; i < new_len; i += 1) {
        if (replacement[i] == '\n') { push(inserted, start + i + 1); }
    }

    splice(doc.text, start, end, replacement);
    splice(doc.lines, remove_from, remove_to, inserted);
    var first_shift = remove_from + len(inserted);
    if (new_len >= old_len) {
        var delta = new_len - old_len;
        while (first_shift < len(doc.lines)) { doc.lines[first_shift] += delta; first_shift += 1; }
    } else {
        var delta = old_len - new_len;
        while (first_shift < len(doc.lines)) { doc.lines[first_shift] -= delta; first_shift += 1; }
    }
}

pub fn document_open(store: ref Documents, uri: []u8, text: []u8, version: i64) -> ref Document {
    var existing = document_get(store, uri);
    match (existing) {
        some(doc) {
            doc.text = bytes.clone(text);
            doc.lines = line_index(doc.text);
            doc.version = version;
            return doc;
        }
        none {
            var copy = bytes.clone(text);
            var doc = new Document { uri: bytes.clone(uri), text: copy, lines: line_index(copy), version: version };
            push(store.docs, doc);
            return doc;
        }
    }
}

pub fn document_close(store: ref Documents, uri: []u8) {
    var index_opt = find_doc_index(store, uri);
    match (index_opt) {
        none { return; }
        some(index) { arrays.remove(store.docs, index); }
    }
}

pub fn position(line: u64, character: u64) -> Position {
    return Position { line: line, character: character };
}

pub fn range(start_line: u64, start_char: u64, end_line: u64, end_char: u64) -> Range {
    return Range { start: position(start_line, start_char), end: position(end_line, end_char) };
}

pub fn position_from_offset(text: []u8, offset: u64) -> Position {
    if (offset > len(text)) { trap; }
    var line: u64 = 0;
    var line_start: u64 = 0;
    var i: u64 = 0;
    while (i < offset) {
        if (text[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
        i += 1;
    }
    var prefix = bytes.slice(text, line_start, offset);
    return position(line, utf8.utf16_len(prefix));
}

pub fn offset_from_position(text: []u8, pos: Position) -> u64 {
    var line: u64 = 0;
    var start: u64 = 0;
    while (line < pos.line && start < len(text)) {
        var nl_opt = bytes.find_byte(text, '\n', start);
        match (nl_opt) {
            none { return len(text); }
            some(nl) { start = nl + 1; line += 1; }
        }
    }
    if (line != pos.line) { return len(text); }
    var end = bytes.line_end(text, start);
    var line_bytes = bytes.slice(text, start, end);
    return start + utf8.utf16_to_byte(line_bytes, pos.character);
}

pub fn position_json(pos: Position) -> json.Json {
    var obj = json.object();
    json.put(obj, "line", json.u64_value(pos.line));
    json.put(obj, "character", json.u64_value(pos.character));
    return obj;
}

pub fn range_json(value: Range) -> json.Json {
    var obj = json.object();
    json.put(obj, "start", position_json(value.start));
    json.put(obj, "end", position_json(value.end));
    return obj;
}

pub fn diagnostic_json(value: Diagnostic) -> json.Json {
    var obj = json.object();
    json.put(obj, "range", range_json(value.range));
    json.put(obj, "severity", json.u64_value(value.severity));
    json.put(obj, "message", json.Json.string(value.message));
    return obj;
}

pub fn symbol_json(value: Symbol) -> json.Json {
    var obj = json.object();
    json.put(obj, "name", json.Json.string(value.name));
    json.put(obj, "kind", json.u64_value(value.kind));
    json.put(obj, "range", range_json(value.range));
    json.put(obj, "selectionRange", range_json(value.selection));
    return obj;
}

pub fn semantic_data(tokens: []SemanticToken) -> json.Json {
    var data = json.array();
    var prev_line: u64 = 0;
    var prev_start: u64 = 0;
    for (var i: u64 = 0; i < len(tokens); i += 1) {
        var line_delta = tokens[i].line - prev_line;
        var start_delta = tokens[i].start;
        if (line_delta == 0) { start_delta = tokens[i].start - prev_start; }
        json.append(data, json.u64_value(line_delta));
        json.append(data, json.u64_value(start_delta));
        json.append(data, json.u64_value(tokens[i].length));
        json.append(data, json.u64_value(tokens[i].token_type));
        json.append(data, json.u64_value(0));
        prev_line = tokens[i].line;
        prev_start = tokens[i].start;
    }
    var result = json.object();
    json.put(result, "data", data);
    return result;
}

pub fn parse_message(body: []u8) -> Message {
    var parsed = json.parse(body);
    var root = json.Json.null;
    match (parsed) {
        json.Parse.error(err) { return Message.invalid(err.message); }
        json.Parse.ok(value) { root = value; }
    }
    var method_value = json.get(root, "method");
    var method: []u8 = [];
    match (method_value) {
        none {
            var id_opt = json.get(root, "id");
            var result_opt = json.get(root, "result");
            match (id_opt) {
                none { return Message.invalid("message has neither method nor id"); }
                some(id) {
                    match (result_opt) {
                        none { return Message.response(id, json.Json.null); }
                        some(result) { return Message.response(id, result); }
                    }
                }
            }
        }
        some(method_json) {
            var method_opt = json.as_string(method_json);
            match (method_opt) {
                none { return Message.invalid("method is not a string"); }
                some(text) { method = text; }
            }
        }
    }
    var params = json.Json.null;
    var params_opt = json.get(root, "params");
    match (params_opt) { none { } some(value) { params = value; } }
    var id_opt2 = json.get(root, "id");
    match (id_opt2) {
        none { return Message.notification(method, params); }
        some(id2) { return Message.request(id2, method, params); }
    }
}

fn base_message() -> json.Json {
    var obj = json.object();
    json.put(obj, "jsonrpc", json.Json.string("2.0"));
    return obj;
}

pub fn response(id: json.Json, result: json.Json) -> []u8 {
    var obj = base_message();
    json.put(obj, "id", id);
    json.put(obj, "result", result);
    return frame_encode(json.stringify(obj));
}

pub fn error_response(id: json.Json, code: i64, message: []u8) -> []u8 {
    var err = json.object();
    json.put(err, "code", json.i64_value(code));
    json.put(err, "message", json.Json.string(message));
    var obj = base_message();
    json.put(obj, "id", id);
    json.put(obj, "error", err);
    return frame_encode(json.stringify(obj));
}

pub fn notification(method: []u8, params: json.Json) -> []u8 {
    var obj = base_message();
    json.put(obj, "method", json.Json.string(method));
    json.put(obj, "params", params);
    return frame_encode(json.stringify(obj));
}

pub fn publish_diagnostics(uri: []u8, diagnostics: []Diagnostic) -> []u8 {
    var params = json.object();
    json.put(params, "uri", json.Json.string(uri));
    var items = json.array();
    for (item in diagnostics) { json.append(items, diagnostic_json(item)); }
    json.put(params, "diagnostics", items);
    return notification("textDocument/publishDiagnostics", params);
}

pub fn get_uri(params: json.Json) -> ?[]u8 {
    var td_opt = json.get(params, "textDocument");
    match (td_opt) {
        none { return none; }
        some(td) {
            var uri_opt = json.get(td, "uri");
            match (uri_opt) {
                none { return none; }
                some(uri_json) { return json.as_string(uri_json); }
            }
        }
    }
}

pub fn get_position(params: json.Json) -> ?Position {
    var pos_opt = json.get(params, "position");
    match (pos_opt) {
        none { return none; }
        some(pos_json) {
            var line_opt = json.get(pos_json, "line");
            var char_opt = json.get(pos_json, "character");
            var line: u64 = 0;
            var character: u64 = 0;
            match (line_opt) { none { return none; } some(v) { var n = json.as_u64(v); match (n) { none { return none; } some(x) { line = x; } } } }
            match (char_opt) { none { return none; } some(v) { var n = json.as_u64(v); match (n) { none { return none; } some(x) { character = x; } } } }
            return some(Position { line: line, character: character });
        }
    }
}


pub fn get_range(params: json.Json) -> ?Range {
    var range_opt = json.get(params, "range");
    match (range_opt) {
        none { return none; }
        some(range_value) {
            var start_opt = json.get(range_value, "start");
            var end_opt = json.get(range_value, "end");
            var start = Position { line: 0, character: 0 };
            var end = Position { line: 0, character: 0 };
            match (start_opt) {
                none { return none; }
                some(value) {
                    var line_opt = json.get_u64(value, "line"); var char_opt = json.get_u64(value, "character");
                    match (line_opt) { none { return none; } some(v) { start.line = v; } }
                    match (char_opt) { none { return none; } some(v) { start.character = v; } }
                }
            }
            match (end_opt) {
                none { return none; }
                some(value) {
                    var line_opt = json.get_u64(value, "line"); var char_opt = json.get_u64(value, "character");
                    match (line_opt) { none { return none; } some(v) { end.line = v; } }
                    match (char_opt) { none { return none; } some(v) { end.character = v; } }
                }
            }
            return some(Range { start: start, end: end });
        }
    }
}

pub fn initialize_result(server_name: []u8, semantic_types: [][]u8, formatting: bool, definition: bool, hover: bool, completion: bool, symbols: bool) -> json.Json {
    var caps = json.object();
    json.put(caps, "positionEncoding", json.Json.string("utf-16"));
    json.put(caps, "textDocumentSync", json.u64_value(2));
    if (definition) { json.put(caps, "definitionProvider", json.Json.boolean(true)); }
    if (hover) { json.put(caps, "hoverProvider", json.Json.boolean(true)); }
    if (formatting) { json.put(caps, "documentFormattingProvider", json.Json.boolean(true)); }
    if (symbols) { json.put(caps, "documentSymbolProvider", json.Json.boolean(true)); }
    if (completion) { json.put(caps, "completionProvider", json.object()); }
    var legend = json.object();
    var types = json.array();
    for (name in semantic_types) { json.append(types, json.Json.string(name)); }
    json.put(legend, "tokenTypes", types);
    json.put(legend, "tokenModifiers", json.array());
    var semantic = json.object();
    json.put(semantic, "legend", legend);
    json.put(semantic, "full", json.Json.boolean(true));
    json.put(semantic, "range", json.Json.boolean(true));
    json.put(caps, "semanticTokensProvider", semantic);
    var info = json.object();
    json.put(info, "name", json.Json.string(server_name));
    json.put(info, "version", json.Json.string("0.1"));
    var result = json.object();
    json.put(result, "capabilities", caps);
    json.put(result, "serverInfo", info);
    return result;
}
