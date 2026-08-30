import bytes;
import lsp;
import utf8;

const SEM_NAMESPACE: u64 = 0;
const SEM_PROPERTY: u64 = 4;
const SEM_STRING: u64 = 6;
const SEM_NUMBER: u64 = 7;
const SEM_COMMENT: u64 = 8;
const SEM_OPERATOR: u64 = 9;

struct IToken {
    text: []u8,
    line: u64,
    start16: u64,
    length16: u64,
    start: u64,
    end: u64,
    semantic: u64,
}

struct Parsed {
    tokens: []IToken,
    diagnostics: []lsp.Diagnostic,
    symbols: []lsp.Symbol,
}

fn first_nonspace(line: []u8) -> u64 {
    var i: u64 = 0;
    while (i < len(line) && (line[i] == ' ' || line[i] == '\t' || line[i] == '\r')) { i += 1; }
    return i;
}

fn last_nonspace(line: []u8) -> u64 {
    var i = len(line);
    while (i > 0 && (line[i - 1] == ' ' || line[i - 1] == '\t' || line[i - 1] == '\r')) { i -= 1; }
    return i;
}

fn token_range(token: IToken) -> lsp.Range {
    return lsp.range(token.line, token.start16, token.line, token.start16 + token.length16);
}

fn add_diag(out: []lsp.Diagnostic, line_no: u64, start: u64, end: u64, message: []u8) {
    push(out, lsp.Diagnostic { range: lsp.range(line_no, start, line_no, end), message: bytes.clone(message), severity: 1 });
}

fn composite(section: []u8, key: []u8) -> []u8 {
    var out: []u8 = [];
    bytes.append(out, section); push(out, 0); bytes.append(out, key); return out;
}

fn seen_contains(seen: [][]u8, value: []u8) -> bool {
    for (item in seen) { if (bytes.equal(item, value)) { return true; } }
    return false;
}

fn numeric(value: []u8) -> bool {
    if (len(value) == 0) { return false; }
    var i: u64 = 0;
    if (value[0] == '-' || value[0] == '+') { i = 1; }
    if (i == len(value)) { return false; }
    while (i < len(value)) {
        var ch = value[i];
        if (!((ch >= '0' && ch <= '9') || ch == '.')) { return false; }
        i += 1;
    }
    return true;
}

fn parse(text: []u8) -> Parsed {
    var tokens: []IToken = [];
    var diags: []lsp.Diagnostic = [];
    var syms: []lsp.Symbol = [];
    var seen: [][]u8 = [];
    var section: []u8 = [];
    var pos: u64 = 0;
    var line_no: u64 = 0;
    while (pos <= len(text)) {
        var end = bytes.line_end(text, pos);
        var line = bytes.slice(text, pos, end);
        var first = first_nonspace(line);
        var last = last_nonspace(line);
        if (first < last) {
            var ch = line[first];
            if (ch == ';' || ch == '#') {
                var raw = bytes.slice(line, first, last);
                push(tokens, IToken { text: raw, line: line_no, start16: first, length16: utf8.utf16_len(raw), start: pos + first, end: pos + last, semantic: SEM_COMMENT });
            } else if (ch == '[') {
                if (last <= first + 2 || line[last - 1] != ']') {
                    add_diag(diags, line_no, first, last, "malformed section header");
                } else {
                    section = bytes.trim_ascii(bytes.slice(line, first + 1, last - 1));
                    var name_start = first + 1;
                    while (name_start < last - 1 && (line[name_start] == ' ' || line[name_start] == '\t')) { name_start += 1; }
                    var r = lsp.range(line_no, name_start, line_no, name_start + utf8.utf16_len(section));
                    push(tokens, IToken { text: bytes.clone(section), line: line_no, start16: name_start, length16: utf8.utf16_len(section), start: pos + name_start, end: pos + name_start + len(section), semantic: SEM_NAMESPACE });
                    push(syms, lsp.Symbol { name: bytes.clone(section), kind: 3, range: r, selection: r });
                }
            } else {
                var eq_opt = bytes.find_byte(line, '=', first);
                match (eq_opt) {
                    none { add_diag(diags, line_no, first, last, "expected key = value"); }
                    some(eq) {
                        var key = bytes.trim_ascii(bytes.slice(line, first, eq));
                        if (len(key) == 0) { add_diag(diags, line_no, first, eq, "empty key"); }
                        else {
                            var key_start = first;
                            while (key_start < eq && (line[key_start] == ' ' || line[key_start] == '\t')) { key_start += 1; }
                            var key_range = lsp.range(line_no, key_start, line_no, key_start + utf8.utf16_len(key));
                            push(tokens, IToken { text: bytes.clone(key), line: line_no, start16: key_start, length16: utf8.utf16_len(key), start: pos + key_start, end: pos + key_start + len(key), semantic: SEM_PROPERTY });
                            push(syms, lsp.Symbol { name: bytes.clone(key), kind: 20, range: key_range, selection: key_range });
                            var identity = composite(section, key);
                            if (seen_contains(seen, identity)) { add_diag(diags, line_no, key_start, key_start + len(key), "duplicate key in section"); }
                            else { push(seen, identity); }
                        }
                        var value = bytes.trim_ascii(bytes.slice(line, eq + 1, last));
                        var value_start = eq + 1;
                        while (value_start < last && (line[value_start] == ' ' || line[value_start] == '\t')) { value_start += 1; }
                        if (len(value) > 0) {
                            var sem = SEM_STRING; if (numeric(value)) { sem = SEM_NUMBER; }
                            push(tokens, IToken { text: value, line: line_no, start16: value_start, length16: utf8.utf16_len(value), start: pos + value_start, end: pos + value_start + len(value), semantic: sem });
                        }
                        push(tokens, IToken { text: "=", line: line_no, start16: eq, length16: 1, start: pos + eq, end: pos + eq + 1, semantic: SEM_OPERATOR });
                    }
                }
            }
        }
        if (end == len(text)) { break; }
        pos = end + 1; line_no += 1;
    }
    return Parsed { tokens: tokens, diagnostics: diags, symbols: syms };
}

pub fn diagnostics(text: []u8) -> []lsp.Diagnostic { return parse(text).diagnostics; }

pub fn semantic(text: []u8) -> []lsp.SemanticToken {
    var out: []lsp.SemanticToken = [];
    for (token in parse(text).tokens) {
        push(out, lsp.SemanticToken { line: token.line, start: token.start16, length: token.length16, token_type: token.semantic });
    }
    return out;
}

pub fn symbols(text: []u8) -> []lsp.Symbol { return parse(text).symbols; }

pub fn completion(text: []u8, pos: lsp.Position) -> [][]u8 {
    var out: [][]u8 = ["[section]", "key = value"];
    for (symbol in parse(text).symbols) { push(out, bytes.clone(symbol.name)); }
    return out;
}

fn token_at(text: []u8, pos: lsp.Position) -> ?IToken {
    var offset = lsp.offset_from_position(text, pos);
    for (token in parse(text).tokens) { if (offset >= token.start && offset <= token.end) { return some(token); } }
    return none;
}

pub fn definition(text: []u8, pos: lsp.Position) -> ?lsp.Range {
    var here = token_at(text, pos);
    match (here) {
        none { return none; }
        some(token) {
            for (candidate in parse(text).tokens) {
                if (candidate.start < token.start && candidate.semantic == token.semantic && bytes.equal(candidate.text, token.text)) { return some(token_range(candidate)); }
            }
            return none;
        }
    }
}

pub fn hover(text: []u8, pos: lsp.Position) -> ?[]u8 {
    var here = token_at(text, pos);
    match (here) {
        none { return none; }
        some(token) {
            if (token.semantic == SEM_NAMESPACE) { return some("INI section"); }
            if (token.semantic == SEM_PROPERTY) { return some("INI key"); }
            if (token.semantic == SEM_NUMBER) { return some("INI numeric value"); }
            if (token.semantic == SEM_COMMENT) { return some("INI comment"); }
            return some("INI value");
        }
    }
}

pub fn format(text: []u8) -> ?[]u8 {
    var out: []u8 = [];
    var pos: u64 = 0;
    while (pos <= len(text)) {
        var end = bytes.line_end(text, pos);
        var line = bytes.trim_ascii(bytes.slice(text, pos, end));
        if (len(line) > 0 && line[0] != ';' && line[0] != '#' && line[0] != '[') {
            var eq_opt = bytes.find_byte(line, '=', 0);
            match (eq_opt) {
                none { bytes.append(out, line); }
                some(eq) {
                    bytes.append(out, bytes.trim_ascii(bytes.slice(line, 0, eq)));
                    bytes.append(out, " = ");
                    bytes.append(out, bytes.trim_ascii(bytes.slice(line, eq + 1, len(line))));
                }
            }
        } else { bytes.append(out, line); }
        if (end < len(text)) { push(out, '\n'); }
        if (end == len(text)) { break; }
        pos = end + 1;
    }
    return some(out);
}
