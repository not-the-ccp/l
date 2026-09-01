import bytes;
import json;
import lsp;
import stdio;

pub struct Ops {
    pub name: []u8,
    pub token_types: [][]u8,
    pub diagnostics: fn([]u8) -> []lsp.Diagnostic,
    pub semantic: fn([]u8) -> []lsp.SemanticToken,
    pub symbols: fn([]u8) -> []lsp.Symbol,
    pub completion: fn([]u8, lsp.Position) -> [][]u8,
    pub definition: fn([]u8, lsp.Position) -> ?lsp.Range,
    pub hover: fn([]u8, lsp.Position) -> ?[]u8,
    pub format: fn([]u8) -> ?[]u8,
}

fn write_frame(data: []u8) {
    stdio.write(data);
}

const AUTO_ANALYZE_LIMIT: u64 = 131072;

fn publish(ops: Ops, uri: []u8, text: []u8) {
    if (len(text) <= AUTO_ANALYZE_LIMIT) {
        write_frame(lsp.publish_diagnostics(uri, ops.diagnostics(text)));
    }
}

fn open_document(store: ref lsp.Documents, params: json.Json, ops: Ops) {
    var td_opt = json.get(params, "textDocument");
    match (td_opt) {
        none { return; }
        some(td) {
            var uri_opt = json.get_string(td, "uri");
            var text_opt = json.get_string(td, "text");
            var version_opt = json.get_i64(td, "version");
            match (uri_opt) {
                none { return; }
                some(uri) {
                    match (text_opt) {
                        none { return; }
                        some(text) {
                            var version: i64 = 0;
                            match (version_opt) { none { } some(v) { version = v; } }
                            lsp.document_open(store, uri, text, version);
                            publish(ops, uri, text);
                        }
                    }
                }
            }
        }
    }
}

fn change_document(store: ref lsp.Documents, params: json.Json, ops: Ops) {
    var uri_opt = lsp.get_uri(params);
    match (uri_opt) {
        none { return; }
        some(uri) {
            var doc_opt = lsp.document_get(store, uri);
            match (doc_opt) {
                none { return; }
                some(doc) {
                    var changes_opt = json.get(params, "contentChanges");
                    match (changes_opt) {
                        none { return; }
                        some(changes_json) {
                            var arr_opt = json.as_array(changes_json);
                            match (arr_opt) {
                                none { return; }
                                some(changes) {
                                    if (len(changes) == 0) { return; }
                                    for (change in changes) {
                                        var text_opt = json.get_string(change, "text");
                                        match (text_opt) {
                                            none { return; }
                                            some(text) {
                                                var range_opt = lsp.get_range(change);
                                                match (range_opt) {
                                                    // Full replacement remains accepted for compatibility with ordinary clients.
                                                    none { doc.text = bytes.clone(text); doc.lines = [0]; for (var i: u64 = 0; i < len(doc.text); i += 1) { if (doc.text[i] == '\n') { push(doc.lines, i + 1); } } }
                                                    some(value) {
                                                        lsp.document_apply_change(doc, value, text);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    var td_opt = json.get(params, "textDocument");
                                    match (td_opt) {
                                        none { }
                                        some(td) {
                                            var version_opt = json.get_i64(td, "version");
                                            match (version_opt) { none { } some(v) { doc.version = v; } }
                                        }
                                    }
                                    publish(ops, uri, doc.text);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

fn close_document(store: ref lsp.Documents, params: json.Json) {
    var uri_opt = lsp.get_uri(params);
    match (uri_opt) { none { } some(uri) { lsp.document_close(store, uri); } }
}

fn document_for(store: ref lsp.Documents, params: json.Json) -> ?ref lsp.Document {
    var uri_opt = lsp.get_uri(params);
    match (uri_opt) { none { return none; } some(uri) { return lsp.document_get(store, uri); } }
}

fn completion_result(labels: [][]u8) -> json.Json {
    var out = json.array();
    for (label in labels) {
        var item = json.object();
        json.put(item, "label", json.Json.string(label));
        json.put(item, "kind", json.u64_value(14));
        json.append(out, item);
    }
    return out;
}

fn symbols_result(symbols: []lsp.Symbol) -> json.Json {
    var out = json.array();
    for (symbol in symbols) { json.append(out, lsp.symbol_json(symbol)); }
    return out;
}

fn location_result(uri: []u8, value: lsp.Range) -> json.Json {
    var out = json.object();
    json.put(out, "uri", json.Json.string(uri));
    json.put(out, "range", lsp.range_json(value));
    return out;
}

fn hover_result(text: []u8) -> json.Json {
    var contents = json.object();
    json.put(contents, "kind", json.Json.string("plaintext"));
    json.put(contents, "value", json.Json.string(text));
    var out = json.object();
    json.put(out, "contents", contents);
    return out;
}

fn formatting_result(old_text: []u8, new_text: []u8) -> json.Json {
    var edit = json.object();
    var end = lsp.position_from_offset(old_text, len(old_text));
    json.put(edit, "range", lsp.range_json(lsp.Range { start: lsp.position(0, 0), end: end }));
    json.put(edit, "newText", json.Json.string(new_text));
    var out = json.array();
    json.append(out, edit);
    return out;
}


fn semantic_range(ops: Ops, doc: ref lsp.Document, value: lsp.Range) -> []lsp.SemanticToken {
    var start_line = value.start.line;
    var end_line = value.end.line;
    if (end_line < start_line) { end_line = start_line; }
    var start = lsp.document_offset(doc, lsp.Position { line: start_line, character: 0 });
    var end = lsp.document_offset(doc, lsp.Position { line: end_line, character: 0 });
    if (end < start) { end = start; }
    var part = bytes.slice(doc.text, start, end);
    var tokens = ops.semantic(part);
    for (var i: u64 = 0; i < len(tokens); i += 1) { tokens[i].line += start_line; }
    return tokens;
}

fn handle_request(store: ref lsp.Documents, ops: Ops, id: json.Json, method: []u8, params: json.Json) -> bool {
    if (bytes.equal(method, "initialize")) {
        write_frame(lsp.response(id, lsp.initialize_result(ops.name, ops.token_types, true, true, true, true, true)));
        return true;
    }
    if (bytes.equal(method, "shutdown")) {
        write_frame(lsp.response(id, json.Json.null));
        return true;
    }
    var doc_opt = document_for(store, params);
    match (doc_opt) {
        none {
            write_frame(lsp.error_response(id, -32602, "document not open"));
            return true;
        }
        some(doc) {
            if (bytes.equal(method, "textDocument/semanticTokens/full")) {
                write_frame(lsp.response(id, lsp.semantic_data(ops.semantic(doc.text))));
                return true;
            }
            if (bytes.equal(method, "textDocument/semanticTokens/range")) {
                var range_opt = lsp.get_range(params);
                match (range_opt) {
                    none { write_frame(lsp.response(id, lsp.semantic_data([]))); }
                    some(value) { write_frame(lsp.response(id, lsp.semantic_data(semantic_range(ops, doc, value)))); }
                }
                return true;
            }
            if (bytes.equal(method, "textDocument/documentSymbol")) {
                write_frame(lsp.response(id, symbols_result(ops.symbols(doc.text))));
                return true;
            }
            if (bytes.equal(method, "textDocument/completion")) {
                var pos_opt = lsp.get_position(params);
                match (pos_opt) {
                    none { write_frame(lsp.response(id, json.array())); }
                    some(pos) { write_frame(lsp.response(id, completion_result(ops.completion(doc.text, pos)))); }
                }
                return true;
            }
            if (bytes.equal(method, "textDocument/definition")) {
                var pos_opt = lsp.get_position(params);
                match (pos_opt) {
                    none { write_frame(lsp.response(id, json.Json.null)); }
                    some(pos) {
                        var def_opt = ops.definition(doc.text, pos);
                        match (def_opt) {
                            none { write_frame(lsp.response(id, json.Json.null)); }
                            some(def_range) { write_frame(lsp.response(id, location_result(doc.uri, def_range))); }
                        }
                    }
                }
                return true;
            }
            if (bytes.equal(method, "textDocument/hover")) {
                var pos_opt = lsp.get_position(params);
                match (pos_opt) {
                    none { write_frame(lsp.response(id, json.Json.null)); }
                    some(pos) {
                        var text_opt = ops.hover(doc.text, pos);
                        match (text_opt) {
                            none { write_frame(lsp.response(id, json.Json.null)); }
                            some(text) { write_frame(lsp.response(id, hover_result(text))); }
                        }
                    }
                }
                return true;
            }
            if (bytes.equal(method, "textDocument/formatting")) {
                var formatted = ops.format(doc.text);
                match (formatted) {
                    none { write_frame(lsp.response(id, json.array())); }
                    some(text) { write_frame(lsp.response(id, formatting_result(doc.text, text))); }
                }
                return true;
            }
        }
    }
    write_frame(lsp.error_response(id, -32601, "method not found"));
    return true;
}

fn handle_notification(store: ref lsp.Documents, ops: Ops, method: []u8, params: json.Json) -> bool {
    if (bytes.equal(method, "initialized")) { return true; }
    if (bytes.equal(method, "textDocument/didOpen")) { open_document(store, params, ops); return true; }
    if (bytes.equal(method, "textDocument/didChange")) { change_document(store, params, ops); return true; }
    if (bytes.equal(method, "textDocument/didClose")) { close_document(store, params); return true; }
    if (bytes.equal(method, "exit")) { return false; }
    return true;
}

pub fn run(ops: Ops) {
    var reader = lsp.frame_buffer();
    var store = lsp.documents();
    var running = true;
    while (running) {
        var body_opt = lsp.frame_take(reader);
        match (body_opt) {
            none {
                var chunk_opt = stdio.read(4096);
                match (chunk_opt) {
                    none { return; }
                    some(chunk) { lsp.frame_feed(reader, chunk); }
                }
            }
            some(body) {
                var message = lsp.parse_message(body);
                match (message) {
                    lsp.Message.request(id, method, params) { running = handle_request(store, ops, id, method, params); }
                    lsp.Message.notification(method, params) { running = handle_notification(store, ops, method, params); }
                    lsp.Message.response(_, _) { }
                    lsp.Message.invalid(_) { }
                }
            }
        }
    }
}
