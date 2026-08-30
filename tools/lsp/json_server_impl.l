import bytes;
import json;
import lsp;
import utf8;

const SEM_PROPERTY: u64 = 4;
const SEM_KEYWORD: u64 = 5;
const SEM_STRING: u64 = 6;
const SEM_NUMBER: u64 = 7;
const SEM_OPERATOR: u64 = 9;

struct JToken {
    text: []u8,
    start: u64,
    end: u64,
    line: u64,
    start16: u64,
    length16: u64,
    semantic: u64,
}

fn skip_ws(text: []u8, pos: u64) -> u64 {
    var p = pos;
    while (p < len(text) && (text[p] == ' ' || text[p] == '\t' || text[p] == '\r' || text[p] == '\n')) { p += 1; }
    return p;
}

fn scan(text: []u8) -> []JToken {
    var out: []JToken = [];
    var i: u64 = 0;
    var line: u64 = 0;
    var col16: u64 = 0;
    while (i < len(text)) {
        var ch = text[i];
        if (ch == ' ' || ch == '\t' || ch == '\r') { i += 1; col16 += 1; continue; }
        if (ch == '\n') { i += 1; line += 1; col16 = 0; continue; }
        var start = i; var start16 = col16; var sem = SEM_OPERATOR;
        if (ch == '"') {
            i += 1;
            while (i < len(text) && text[i] != '\n') {
                if (text[i] == '\\') { i += 1; if (i < len(text)) { i += 1; } }
                else if (text[i] == '"') { i += 1; break; }
                else { i += 1; }
            }
            var next = skip_ws(text, i);
            sem = SEM_STRING;
            if (next < len(text) && text[next] == ':') { sem = SEM_PROPERTY; }
        } else if ((ch >= '0' && ch <= '9') || ch == '-') {
            i += 1;
            while (i < len(text) && ((text[i] >= '0' && text[i] <= '9') || text[i] == '.' || text[i] == 'e' || text[i] == 'E' || text[i] == '+' || text[i] == '-')) { i += 1; }
            sem = SEM_NUMBER;
        } else if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
            i += 1;
            while (i < len(text) && ((text[i] >= 'a' && text[i] <= 'z') || (text[i] >= 'A' && text[i] <= 'Z'))) { i += 1; }
            sem = SEM_KEYWORD;
        } else {
            i += 1;
            sem = SEM_OPERATOR;
        }
        var raw = bytes.slice(text, start, i);
        var width = utf8.utf16_len(raw);
        push(out, JToken { text: raw, start: start, end: i, line: line, start16: start16, length16: width, semantic: sem });
        col16 += width;
    }
    return out;
}

pub fn diagnostics(text: []u8) -> []lsp.Diagnostic {
    var out: []lsp.Diagnostic = [];
    var parsed = json.parse(text);
    match (parsed) {
        json.Parse.ok(_) { }
        json.Parse.error(err) {
            var start = lsp.position_from_offset(text, err.offset);
            var end_offset = err.offset;
            if (end_offset < len(text)) { end_offset += 1; }
            var finish = lsp.position_from_offset(text, end_offset);
            push(out, lsp.Diagnostic { range: lsp.Range { start: start, end: finish }, message: err.message, severity: 1 });
        }
    }
    return out;
}

pub fn semantic(text: []u8) -> []lsp.SemanticToken {
    var out: []lsp.SemanticToken = [];
    for (token in scan(text)) {
        push(out, lsp.SemanticToken { line: token.line, start: token.start16, length: token.length16, token_type: token.semantic });
    }
    return out;
}

fn unquote(raw: []u8) -> []u8 {
    if (len(raw) >= 2) { return bytes.slice(raw, 1, len(raw) - 1); }
    return raw;
}

pub fn symbols(text: []u8) -> []lsp.Symbol {
    var out: []lsp.Symbol = [];
    for (token in scan(text)) {
        if (token.semantic == SEM_PROPERTY) {
            var r = lsp.range(token.line, token.start16, token.line, token.start16 + token.length16);
            push(out, lsp.Symbol { name: unquote(token.text), kind: 20, range: r, selection: r });
        }
    }
    return out;
}

pub fn completion(text: []u8, pos: lsp.Position) -> [][]u8 {
    return ["null", "true", "false", "{}", "[]", "\"\""];
}

pub fn definition(text: []u8, pos: lsp.Position) -> ?lsp.Range { return none; }

pub fn hover(text: []u8, pos: lsp.Position) -> ?[]u8 {
    var off = lsp.offset_from_position(text, pos);
    for (token in scan(text)) {
        if (off >= token.start && off <= token.end) {
            if (token.semantic == SEM_PROPERTY) { return some("JSON property"); }
            if (token.semantic == SEM_STRING) { return some("JSON string"); }
            if (token.semantic == SEM_NUMBER) { return some("JSON number"); }
            if (token.semantic == SEM_KEYWORD) { return some("JSON literal"); }
            return some("JSON punctuation");
        }
    }
    return none;
}

fn indent(out: []u8, level: u64) {
    for (var i: u64 = 0; i < level * 2; i += 1) { push(out, ' '); }
}

fn pretty(out: []u8, value: json.Json, level: u64) {
    match (value) {
        json.Json.array(values) {
            if (len(values) == 0) { bytes.append(out, "[]"); return; }
            bytes.append(out, "[\n");
            for (var i: u64 = 0; i < len(values); i += 1) {
                indent(out, level + 1); pretty(out, values[i], level + 1);
                if (i + 1 < len(values)) { push(out, ','); }
                push(out, '\n');
            }
            indent(out, level); push(out, ']');
        }
        json.Json.object(members) {
            if (len(members) == 0) { bytes.append(out, "{}"); return; }
            bytes.append(out, "{\n");
            for (var i: u64 = 0; i < len(members); i += 1) {
                indent(out, level + 1);
                bytes.append(out, json.stringify(json.Json.string(members[i].key)));
                bytes.append(out, ": ");
                pretty(out, members[i].value, level + 1);
                if (i + 1 < len(members)) { push(out, ','); }
                push(out, '\n');
            }
            indent(out, level); push(out, '}');
        }
        _ { bytes.append(out, json.stringify(value)); }
    }
}

pub fn format(text: []u8) -> ?[]u8 {
    var parsed = json.parse(text);
    match (parsed) {
        json.Parse.error(_) { return none; }
        json.Parse.ok(value) {
            var out: []u8 = [];
            pretty(out, value, 0); push(out, '\n');
            return some(out);
        }
    }
}
