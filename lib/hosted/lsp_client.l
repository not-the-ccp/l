import arrays;
import bytes;
import json;
import lsp;
import proc;

pub struct Client {
    process: proc.Process,
    reader: ref lsp.FrameBuffer,
    next_id: i64,
    pending: []lsp.Message,
    alive: bool,
}

pub struct TextChange {
    pub range: lsp.Range,
    pub text: []u8,
}

pub fn start(argv: [][]u8) -> ref Client {
    return new Client { process: proc.spawn(argv), reader: lsp.frame_buffer(), next_id: 1, pending: [], alive: true };
}

fn send(client: ref Client, data: []u8) -> bool {
    if (!client.alive) { return false; }
    if (!proc.write_try(client.process, data)) { client.alive = false; return false; }
    return true;
}

pub fn is_alive(client: ref Client) -> bool {
    if (client.alive && !proc.alive(client.process)) { client.alive = false; }
    return client.alive;
}

fn read_one(client: ref Client) -> ?lsp.Message {
    while (true) {
        var body_opt = lsp.frame_take(client.reader);
        match (body_opt) {
            some(body) { return some(lsp.parse_message(body)); }
            none {
                var chunk_opt = proc.read(client.process, 4096);
                match (chunk_opt) {
                    none { return none; }
                    some(chunk) { lsp.frame_feed(client.reader, chunk); }
                }
            }
        }
    }
}

fn request_frame(id: i64, method: []u8, params: json.Json) -> []u8 {
    var obj = json.object();
    json.put(obj, "jsonrpc", json.Json.string("2.0"));
    json.put(obj, "id", json.i64_value(id));
    json.put(obj, "method", json.Json.string(method));
    json.put(obj, "params", params);
    return lsp.frame_encode(json.stringify(obj));
}

pub fn notify(client: ref Client, method: []u8, params: json.Json) {
    send(client, lsp.notification(method, params));
}

pub fn request(client: ref Client, method: []u8, params: json.Json) -> ?json.Json {
    if (!is_alive(client)) { return none; }
    var id = client.next_id;
    client.next_id += 1;
    if (!send(client, request_frame(id, method, params))) { return none; }
    while (true) {
        var message_opt = read_one(client);
        match (message_opt) {
            none { return none; }
            some(message) {
                match (message) {
                    lsp.Message.response(response_id, result) {
                        var id_opt = json.as_i64(response_id);
                        match (id_opt) {
                            some(value) { if (value == id) { return some(result); } }
                            none { }
                        }
                        push(client.pending, message);
                    }
                    lsp.Message.notification(_, _) { push(client.pending, message); }
                    lsp.Message.request(_, _, _) { push(client.pending, message); }
                    lsp.Message.invalid(_) { }
                }
            }
        }
    }
}

pub fn take_notification(client: ref Client, method: []u8) -> ?json.Json {
    var i: u64 = 0;
    while (i < len(client.pending)) {
        var message = client.pending[i];
        match (message) {
            lsp.Message.notification(name, params) {
                if (bytes.equal(name, method)) {
                    arrays.remove(client.pending, i);
                    return some(params);
                }
            }
            _ { }
        }
        i += 1;
    }
    return none;
}


pub fn poll(client: ref Client, timeout_ms: u64) {
    if (!is_alive(client)) { return; }
    var first = true;
    while (true) {
        while (true) {
            var body_opt = lsp.frame_take(client.reader);
            match (body_opt) {
                none { break; }
                some(body) { push(client.pending, lsp.parse_message(body)); }
            }
        }
        var wait: u64 = 0;
        if (first) { wait = timeout_ms; }
        var chunk_opt = proc.read_timeout(client.process, 4096, wait);
        match (chunk_opt) {
            none { return; }
            some(chunk) { lsp.frame_feed(client.reader, chunk); }
        }
        first = false;
    }
}

pub fn request_async(client: ref Client, method: []u8, params: json.Json) -> i64 {
    if (!is_alive(client)) { return 0; }
    var id = client.next_id;
    client.next_id += 1;
    if (!send(client, request_frame(id, method, params))) { return 0; }
    return id;
}

pub fn take_response(client: ref Client, id: i64) -> ?json.Json {
    var i: u64 = 0;
    while (i < len(client.pending)) {
        var message = client.pending[i];
        match (message) {
            lsp.Message.response(response_id, result) {
                var id_opt = json.as_i64(response_id);
                match (id_opt) {
                    some(value) {
                        if (value == id) {
                            arrays.remove(client.pending, i);
                            return some(result);
                        }
                    }
                    none { }
                }
            }
            _ { }
        }
        i += 1;
    }
    return none;
}

pub fn semantic_async(client: ref Client, uri: []u8) -> i64 {
    return request_async(client, "textDocument/semanticTokens/full", text_document_params(uri));
}

pub fn semantic_range_async(client: ref Client, uri: []u8, start_line: u64, end_line: u64) -> i64 {
    var params = text_document_params(uri);
    json.put(params, "range", lsp.range_json(lsp.Range {
        start: lsp.Position { line: start_line, character: 0 },
        end: lsp.Position { line: end_line, character: 0 },
    }));
    return request_async(client, "textDocument/semanticTokens/range", params);
}

pub fn initialize(client: ref Client) -> bool {
    var capabilities = json.object();
    var general = json.object();
    var encodings = json.array(); json.append(encodings, json.Json.string("utf-16"));
    json.put(general, "positionEncodings", encodings); json.put(capabilities, "general", general);
    var params = json.object(); json.put(params, "capabilities", capabilities);
    var result = request(client, "initialize", params);
    match (result) { none { return false; } some(_) { notify(client, "initialized", json.object()); return true; } }
}

pub fn did_open(client: ref Client, uri: []u8, text: []u8, version: i64, language_id: []u8) {
    var td = json.object();
    json.put(td, "uri", json.Json.string(uri));
    json.put(td, "languageId", json.Json.string(language_id));
    json.put(td, "version", json.i64_value(version));
    json.put(td, "text", json.Json.string(text));
    var params = json.object(); json.put(params, "textDocument", td);
    notify(client, "textDocument/didOpen", params);
}

pub fn did_change(client: ref Client, uri: []u8, edits: []TextChange, version: i64) {
    if (len(edits) == 0) { return; }
    var td = json.object(); json.put(td, "uri", json.Json.string(uri)); json.put(td, "version", json.i64_value(version));
    var changes = json.array();
    for (edit in edits) {
        var change = json.object();
        json.put(change, "range", lsp.range_json(edit.range));
        json.put(change, "text", json.Json.string(edit.text));
        json.append(changes, change);
    }
    var params = json.object(); json.put(params, "textDocument", td); json.put(params, "contentChanges", changes);
    notify(client, "textDocument/didChange", params);
}

fn text_document_params(uri: []u8) -> json.Json {
    var td = json.object(); json.put(td, "uri", json.Json.string(uri));
    var params = json.object(); json.put(params, "textDocument", td); return params;
}

fn position_params(uri: []u8, pos: lsp.Position) -> json.Json {
    var params = text_document_params(uri); json.put(params, "position", lsp.position_json(pos)); return params;
}

pub fn semantic(client: ref Client, uri: []u8) -> ?json.Json { return request(client, "textDocument/semanticTokens/full", text_document_params(uri)); }
pub fn symbols(client: ref Client, uri: []u8) -> ?json.Json { return request(client, "textDocument/documentSymbol", text_document_params(uri)); }
pub fn completion(client: ref Client, uri: []u8, pos: lsp.Position) -> ?json.Json { return request(client, "textDocument/completion", position_params(uri, pos)); }
pub fn definition(client: ref Client, uri: []u8, pos: lsp.Position) -> ?json.Json { return request(client, "textDocument/definition", position_params(uri, pos)); }
pub fn hover(client: ref Client, uri: []u8, pos: lsp.Position) -> ?json.Json { return request(client, "textDocument/hover", position_params(uri, pos)); }

pub fn formatting(client: ref Client, uri: []u8) -> ?json.Json {
    var params = text_document_params(uri);
    var options = json.object(); json.put(options, "tabSize", json.u64_value(4)); json.put(options, "insertSpaces", json.Json.boolean(true));
    json.put(params, "options", options); return request(client, "textDocument/formatting", params);
}

pub fn stop(client: ref Client) {
    if (is_alive(client)) { request_async(client, "shutdown", json.Json.null); notify(client, "exit", json.Json.null); }
    proc.close(client.process); client.alive = false;
}
