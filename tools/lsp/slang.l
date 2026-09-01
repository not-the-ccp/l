import arrays;
import bytes;
import lsp;
import slang_syntax;
import utf8;

const SEM_NAMESPACE: u64 = 0;
const SEM_TYPE: u64 = 1;
const SEM_FUNCTION: u64 = 2;
const SEM_VARIABLE: u64 = 3;
const SEM_PROPERTY: u64 = 4;
const SEM_KEYWORD: u64 = 5;
const SEM_STRING: u64 = 6;
const SEM_NUMBER: u64 = 7;
const SEM_COMMENT: u64 = 8;
const SEM_OPERATOR: u64 = 9;
const SEM_ENUM_MEMBER: u64 = 10;

enum Kind {
    name,
    keyword,
    number,
    string,
    comment,
    operator,
    invalid,
}

struct Token {
    kind: Kind,
    text: []u8,
    start: u64,
    end: u64,
    line: u64,
    start16: u64,
    length16: u64,
    semantic: u64,
}

struct Definition {
    name: []u8,
    range: lsp.Range,
    offset: u64,
    detail: []u8,
}

struct Analysis {
    tokens: []Token,
    diagnostics: []lsp.Diagnostic,
    symbols: []lsp.Symbol,
    definitions: []Definition,
}

fn is_alpha(ch: u8) -> bool {
    return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_';
}

fn is_digit(ch: u8) -> bool { return ch >= '0' && ch <= '9'; }
fn is_name_char(ch: u8) -> bool { return is_alpha(ch) || is_digit(ch); }

fn is_keyword(text: []u8) -> bool {
    return bytes.equal(text, "import") || bytes.equal(text, "as") || bytes.equal(text, "pub") || bytes.equal(text, "const") ||
        bytes.equal(text, "struct") || bytes.equal(text, "enum") || bytes.equal(text, "fn") || bytes.equal(text, "var") ||
        bytes.equal(text, "if") || bytes.equal(text, "else") || bytes.equal(text, "while") || bytes.equal(text, "for") ||
        bytes.equal(text, "in") || bytes.equal(text, "match") || bytes.equal(text, "return") || bytes.equal(text, "break") ||
        bytes.equal(text, "continue") || bytes.equal(text, "trap") || bytes.equal(text, "true") || bytes.equal(text, "false") ||
        bytes.equal(text, "none") || bytes.equal(text, "some") || bytes.equal(text, "ref") || bytes.equal(text, "new") || bytes.equal(text, "is");
}

fn token_range(token: Token) -> lsp.Range {
    return lsp.range(token.line, token.start16, token.line, token.start16 + token.length16);
}

fn push_diag(out: []lsp.Diagnostic, text: []u8, start: u64, end: u64, message: []u8) {
    var a = lsp.position_from_offset(text, start);
    var b = lsp.position_from_offset(text, end);
    push(out, lsp.Diagnostic { range: lsp.Range { start: a, end: b }, message: bytes.clone(message), severity: 1 });
}

fn scan(text: []u8) -> Analysis {
    var tokens: []Token = [];
    var diags: []lsp.Diagnostic = [];
    var opens: []u8 = [];
    var open_offsets: []u64 = [];
    var i: u64 = 0;
    var line: u64 = 0;
    var col16: u64 = 0;
    while (i < len(text)) {
        var ch = text[i];
        if (ch == ' ' || ch == '\t' || ch == '\r') { i += 1; col16 += 1; continue; }
        if (ch == '\n') { i += 1; line += 1; col16 = 0; continue; }
        var start = i;
        var start16 = col16;
        if (ch == '/' && i + 1 < len(text) && text[i + 1] == '/') {
            i += 2;
            while (i < len(text) && text[i] != '\n') { i += 1; }
            var raw = bytes.slice(text, start, i);
            var width = utf8.utf16_len(raw);
            push(tokens, Token { kind: Kind.comment, text: raw, start: start, end: i, line: line, start16: start16, length16: width, semantic: SEM_COMMENT });
            col16 += width;
            continue;
        }
        if (is_alpha(ch)) {
            i += 1;
            while (i < len(text) && is_name_char(text[i])) { i += 1; }
            var raw = bytes.slice(text, start, i);
            var width = i - start;
            var kind = Kind.name;
            var sem = SEM_VARIABLE;
            if (is_keyword(raw)) { kind = Kind.keyword; sem = SEM_KEYWORD; }
            push(tokens, Token { kind: kind, text: raw, start: start, end: i, line: line, start16: start16, length16: width, semantic: sem });
            col16 += width;
            continue;
        }
        if (is_digit(ch)) {
            i += 1;
            while (i < len(text) && (is_name_char(text[i]) || text[i] == '.' || text[i] == '+' || text[i] == '-')) { i += 1; }
            var raw = bytes.slice(text, start, i);
            var width = i - start;
            push(tokens, Token { kind: Kind.number, text: raw, start: start, end: i, line: line, start16: start16, length16: width, semantic: SEM_NUMBER });
            col16 += width;
            continue;
        }
        if (ch == '"' || ch == '\'') {
            var quote = ch;
            i += 1;
            var closed = false;
            while (i < len(text) && text[i] != '\n') {
                if (text[i] == '\\') {
                    i += 1;
                    if (i < len(text) && text[i] != '\n') { i += 1; }
                } else if (text[i] == quote) {
                    i += 1; closed = true; break;
                } else { i += 1; }
            }
            var raw = bytes.slice(text, start, i);
            var width = utf8.utf16_len(raw);
            push(tokens, Token { kind: Kind.string, text: raw, start: start, end: i, line: line, start16: start16, length16: width, semantic: SEM_STRING });
            if (!closed) { push_diag(diags, text, start, i, "unterminated literal"); }
            col16 += width;
            continue;
        }
        var two = false;
        if (i + 1 < len(text)) {
            var a = text[i]; var b = text[i + 1];
            two = (a == '=' && b == '=') || (a == '!' && b == '=') || (a == '<' && (b == '=' || b == '<')) ||
                (a == '>' && (b == '=' || b == '>')) || (a == '&' && b == '&') || (a == '|' && b == '|') ||
                (a == '+' && b == '=') || (a == '-' && (b == '=' || b == '>')) || (a == '*' && b == '=') ||
                (a == '/' && b == '=') || (a == '%' && b == '=') || (a == '&' && b == '=') || (a == '|' && b == '=') || (a == '^' && b == '=');
        }
        var width_bytes: u64 = 1;
        if (two) { width_bytes = 2; }
        var op = bytes.slice(text, i, i + width_bytes);
        push(tokens, Token { kind: Kind.operator, text: op, start: start, end: start + width_bytes, line: line, start16: start16, length16: width_bytes, semantic: SEM_OPERATOR });
        if (ch == '(' || ch == '[' || ch == '{') {
            push(opens, ch); push(open_offsets, start);
        } else if (ch == ')' || ch == ']' || ch == '}') {
            if (len(opens) == 0) {
                push_diag(diags, text, start, start + 1, "unmatched closing delimiter");
            } else {
                var want: u8 = '(';
                if (ch == ']') { want = '['; }
                if (ch == '}') { want = '{'; }
                if (opens[len(opens) - 1] != want) {
                    push_diag(diags, text, start, start + 1, "mismatched closing delimiter");
                } else {
                    pop(opens); pop(open_offsets);
                }
            }
        }
        i += width_bytes; col16 += width_bytes;
    }
    while (len(opens) > 0) {
        var off = pop(open_offsets); pop(opens);
        push_diag(diags, text, off, off + 1, "unclosed delimiter");
    }
    return Analysis { tokens: tokens, diagnostics: diags, symbols: [], definitions: [] };
}

fn add_definition(analysis: ref Analysis, token_index: u64, kind: u64, detail: []u8, top_level: bool) {
    var token = analysis.tokens[token_index];
    var value_range = token_range(token);
    push(analysis.definitions, Definition { name: bytes.clone(token.text), range: value_range, offset: token.start, detail: bytes.clone(detail) });
    if (top_level) {
        for (symbol in analysis.symbols) {
            if (bytes.equal(symbol.name, token.text)) {
                push(analysis.diagnostics, lsp.Diagnostic { range: value_range, message: "duplicate top-level declaration", severity: 1 });
                break;
            }
        }
        push(analysis.symbols, lsp.Symbol { name: bytes.clone(token.text), kind: kind, range: value_range, selection: value_range });
    }
}

fn classify(analysis: ref Analysis) {
    var depth: u64 = 0;
    var i: u64 = 0;
    while (i < len(analysis.tokens)) {
        var token = analysis.tokens[i];
        if (token.kind is Kind.operator) {
            if (bytes.equal(token.text, "{")) { depth += 1; }
            else if (bytes.equal(token.text, "}") && depth > 0) { depth -= 1; }
        }
        if (token.kind is Kind.keyword && i + 1 < len(analysis.tokens) && analysis.tokens[i + 1].kind is Kind.name) {
            var next_index = i + 1;
            if (bytes.equal(token.text, "fn")) {
                analysis.tokens[next_index].semantic = SEM_FUNCTION;
                add_definition(analysis, next_index, 12, "function", depth == 0);
            } else if (bytes.equal(token.text, "struct")) {
                analysis.tokens[next_index].semantic = SEM_TYPE;
                add_definition(analysis, next_index, 23, "struct", depth == 0);
            } else if (bytes.equal(token.text, "enum")) {
                analysis.tokens[next_index].semantic = SEM_TYPE;
                add_definition(analysis, next_index, 10, "enum", depth == 0);
            } else if (bytes.equal(token.text, "const")) {
                analysis.tokens[next_index].semantic = SEM_VARIABLE;
                add_definition(analysis, next_index, 14, "constant", depth == 0);
            } else if (bytes.equal(token.text, "var")) {
                analysis.tokens[next_index].semantic = SEM_VARIABLE;
                add_definition(analysis, next_index, 13, "variable", false);
            }
        }
        if (token.kind is Kind.name && i + 1 < len(analysis.tokens) && bytes.equal(analysis.tokens[i + 1].text, ":")) {
            token.semantic = SEM_PROPERTY;
            analysis.tokens[i].semantic = SEM_PROPERTY;
        }
        i += 1;
    }
}

fn analyze(text: []u8) -> ref Analysis {
    var result = new scan(text);
    classify(result);
    return result;
}

pub fn diagnostics(text: []u8) -> []lsp.Diagnostic {
    var analysis = analyze(text);
    for (error in slang_syntax.errors(text)) {
        push_diag(analysis.diagnostics, text, error.start, error.end, error.message);
    }
    return analysis.diagnostics;
}

pub fn semantic(text: []u8) -> []lsp.SemanticToken {
    var analysis = analyze(text);
    var out: []lsp.SemanticToken = [];
    for (token in analysis.tokens) {
        push(out, lsp.SemanticToken { line: token.line, start: token.start16, length: token.length16, token_type: token.semantic });
    }
    return out;
}

pub fn symbols(text: []u8) -> []lsp.Symbol { return analyze(text).symbols; }

fn token_at(analysis: ref Analysis, offset: u64) -> ?Token {
    for (token in analysis.tokens) {
        if (offset >= token.start && offset <= token.end && token.kind is Kind.name) { return some(token); }
    }
    return none;
}

pub fn completion(text: []u8, pos: lsp.Position) -> [][]u8 {
    var out: [][]u8 = ["fn", "struct", "enum", "var", "if", "else", "while", "for", "match", "return", "ref", "new", "none", "some"];
    var analysis = analyze(text);
    for (def in analysis.definitions) { push(out, bytes.clone(def.name)); }
    return out;
}

pub fn definition(text: []u8, pos: lsp.Position) -> ?lsp.Range {
    var analysis = analyze(text);
    var offset = lsp.offset_from_position(text, pos);
    var token_opt = token_at(analysis, offset);
    match (token_opt) {
        none { return none; }
        some(token) {
            var best: ?lsp.Range = none;
            var best_offset: u64 = 0;
            for (def in analysis.definitions) {
                if (bytes.equal(def.name, token.text)) {
                    if (def.offset <= token.start && (best is none || def.offset >= best_offset)) {
                        best = some(def.range); best_offset = def.offset;
                    }
                }
            }
            match (best) { some(_) { return best; } none { } }
            for (def in analysis.definitions) { if (bytes.equal(def.name, token.text)) { return some(def.range); } }
            return none;
        }
    }
}

pub fn hover(text: []u8, pos: lsp.Position) -> ?[]u8 {
    var analysis = analyze(text);
    var offset = lsp.offset_from_position(text, pos);
    var token_opt = token_at(analysis, offset);
    match (token_opt) {
        none { return none; }
        some(token) {
            for (def in analysis.definitions) {
                if (bytes.equal(def.name, token.text)) {
                    var out: []u8 = [];
                    bytes.append(out, def.detail); bytes.append(out, " "); bytes.append(out, def.name);
                    return some(out);
                }
            }
            return some(token.text);
        }
    }
}

fn append_indent(out: []u8, count: u64) {
    for (var i: u64 = 0; i < count * 4; i += 1) { push(out, ' '); }
}

pub fn format(text: []u8) -> ?[]u8 {
    var out: []u8 = [];
    var pos: u64 = 0;
    var indent: u64 = 0;
    while (pos <= len(text)) {
        var end = bytes.line_end(text, pos);
        var raw = bytes.slice(text, pos, end);
        var line = bytes.trim_ascii(raw);
        if (len(line) > 0 && line[0] == '}' && indent > 0) { indent -= 1; }
        if (len(line) > 0) { append_indent(out, indent); bytes.append(out, line); }
        if (end < len(text)) { push(out, '\n'); }
        if (len(line) > 0 && line[len(line) - 1] == '{') { indent += 1; }
        if (end == len(text)) { break; }
        pos = end + 1;
    }
    return some(out);
}
