import bytes;

pub enum Kind {
    name,
    number,
    string,
    byte,
    comment,
    symbol,
    invalid,
    eof,
}

pub struct Token {
    pub kind: Kind,
    pub text: []u8,
    pub start: u64,
    pub end: u64,
}

pub struct Error {
    pub start: u64,
    pub end: u64,
    pub message: []u8,
}

struct Parser {
    tokens: []Token,
    pos: u64,
    errors: []Error,
}

fn alpha(ch: u8) -> bool {
    return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_';
}
fn digit(ch: u8) -> bool { return ch >= '0' && ch <= '9'; }
fn hex_digit(ch: u8) -> bool {
    return digit(ch) || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
}
fn bin_digit(ch: u8) -> bool { return ch == '0' || ch == '1'; }
fn name_char(ch: u8) -> bool { return alpha(ch) || digit(ch); }

fn push_token(out: []Token, kind: Kind, text: []u8, start: u64, end: u64) {
    push(out, Token { kind: kind, text: text, start: start, end: end });
}

fn number_end(text: const []u8, start: u64) -> u64 {
    var i = start;
    if (i + 2 <= len(text) && text[i] == '0' && i + 1 < len(text) && (text[i + 1] == 'x' || text[i + 1] == 'X')) {
        i += 2;
        while (i < len(text) && (hex_digit(text[i]) || text[i] == '_')) { i += 1; }
        return i;
    }
    if (i + 2 <= len(text) && text[i] == '0' && i + 1 < len(text) && (text[i + 1] == 'b' || text[i + 1] == 'B')) {
        i += 2;
        while (i < len(text) && (bin_digit(text[i]) || text[i] == '_')) { i += 1; }
        return i;
    }
    while (i < len(text) && (digit(text[i]) || text[i] == '_')) { i += 1; }
    if (i < len(text) && text[i] == '.' && i + 1 < len(text) && digit(text[i + 1])) {
        i += 1;
        while (i < len(text) && (digit(text[i]) || text[i] == '_')) { i += 1; }
    }
    if (i < len(text) && (text[i] == 'e' || text[i] == 'E')) {
        var j = i + 1;
        if (j < len(text) && (text[j] == '+' || text[j] == '-')) { j += 1; }
        if (j < len(text) && digit(text[j])) {
            i = j + 1;
            while (i < len(text) && (digit(text[i]) || text[i] == '_')) { i += 1; }
        }
    }
    return i;
}

fn quoted_end(text: const []u8, start: u64, quote: u8) -> u64 {
    var i = start + 1;
    while (i < len(text) && text[i] != '\n') {
        if (text[i] == '\\') {
            i += 1;
            if (i < len(text) && text[i] != '\n') { i += 1; }
        } else if (text[i] == quote) {
            return i + 1;
        } else {
            i += 1;
        }
    }
    return i;
}

pub fn scan(text: const []u8) -> []Token {
    var out: []Token = [];
    var i: u64 = 0;
    while (i < len(text)) {
        var ch = text[i];
        if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') { i += 1; continue; }
        var start = i;
        if (ch == '/' && i + 1 < len(text) && text[i + 1] == '/') {
            i += 2;
            while (i < len(text) && text[i] != '\n') { i += 1; }
            push_token(out, Kind.comment, bytes.slice(text, start, i), start, i);
            continue;
        }
        if (alpha(ch)) {
            i += 1;
            while (i < len(text) && name_char(text[i])) { i += 1; }
            push_token(out, Kind.name, bytes.slice(text, start, i), start, i);
            continue;
        }
        if (digit(ch)) {
            i = number_end(text, start);
            push_token(out, Kind.number, bytes.slice(text, start, i), start, i);
            continue;
        }
        if (ch == '"') {
            i = quoted_end(text, start, '"');
            push_token(out, Kind.string, bytes.slice(text, start, i), start, i);
            continue;
        }
        if (ch == '\'') {
            i = quoted_end(text, start, '\'');
            push_token(out, Kind.byte, bytes.slice(text, start, i), start, i);
            continue;
        }
        var width: u64 = 1;
        if (i + 2 < len(text)) {
            var three = bytes.slice(text, i, i + 3);
            if (bytes.equal(three, "<<=") || bytes.equal(three, ">>=")) { width = 3; }
        }
        if (width == 1 && i + 1 < len(text)) {
            var two = bytes.slice(text, i, i + 2);
            if (bytes.equal(two, "==") || bytes.equal(two, "!=") || bytes.equal(two, "<=") || bytes.equal(two, ">=") ||
                bytes.equal(two, "&&") || bytes.equal(two, "||") || bytes.equal(two, "<<") || bytes.equal(two, ">>") ||
                bytes.equal(two, "+=") || bytes.equal(two, "-=") || bytes.equal(two, "*=") || bytes.equal(two, "/=") ||
                bytes.equal(two, "%=") || bytes.equal(two, "&=") || bytes.equal(two, "|=") || bytes.equal(two, "^=") ||
                bytes.equal(two, "->")) { width = 2; }
        }
        i += width;
        push_token(out, Kind.symbol, bytes.slice(text, start, i), start, i);
    }
    push_token(out, Kind.eof, [], len(text), len(text));
    return out;
}

fn skip_comments(p: ref Parser) {
    while (p.pos < len(p.tokens) && p.tokens[p.pos].kind is Kind.comment) { p.pos += 1; }
}
fn current(p: ref Parser) -> Token { skip_comments(p); return p.tokens[p.pos]; }
fn at(p: ref Parser, text: const []u8) -> bool { return bytes.equal(current(p).text, text); }
fn at_kind(p: ref Parser, kind: Kind) -> bool { return current(p).kind == kind; }
fn eof(p: ref Parser) -> bool { return at_kind(p, Kind.eof); }
fn advance(p: ref Parser) -> Token {
    var token = current(p);
    if (!(token.kind is Kind.eof)) { p.pos += 1; skip_comments(p); }
    return token;
}
fn report(p: ref Parser, token: Token, message: const []u8) {
    push(p.errors, Error { start: token.start, end: token.end, message: bytes.clone(message) });
}
fn need(p: ref Parser, text: const []u8) -> bool {
    if (at(p, text)) { advance(p); return true; }
    var token = current(p); report(p, token, "expected token");
    if (!eof(p)) { advance(p); }
    return false;
}
fn need_name(p: ref Parser) -> bool {
    if (at_kind(p, Kind.name)) { advance(p); return true; }
    var token = current(p); report(p, token, "expected name");
    if (!eof(p)) { advance(p); }
    return false;
}

fn parse_qname(p: ref Parser) -> bool {
    if (!need_name(p)) { return false; }
    while (at(p, ".")) { advance(p); need_name(p); }
    return true;
}

fn parse_type(p: ref Parser) -> bool {
    if (at(p, "?")) { advance(p); return parse_type(p); }
    if (at(p, "ref")) { advance(p); return parse_type(p); }
    if (at(p, "const")) { advance(p); need(p, "["); need(p, "]"); return parse_type(p); }
    if (at(p, "[")) { advance(p); need(p, "]"); return parse_type(p); }
    if (at(p, "(")) { advance(p); need(p, ")"); return true; }
    if (at(p, "fn")) {
        advance(p); need(p, "(");
        if (!at(p, ")")) {
            while (true) {
                parse_type(p);
                if (!at(p, ",")) { break; }
                advance(p); if (at(p, ")")) { break; }
            }
        }
        need(p, ")");
        if (at(p, "->")) { advance(p); parse_type(p); }
        return true;
    }
    if (!parse_qname(p)) { return false; }
    if (at(p, "[")) {
        advance(p);
        if (!at(p, "]")) {
            while (true) {
                parse_type(p);
                if (!at(p, ",")) { break; }
                advance(p); if (at(p, "]")) { break; }
            }
        }
        need(p, "]");
    }
    return true;
}

fn parse_type_params(p: ref Parser) {
    if (!at(p, "[")) { return; }
    advance(p);
    if (!at(p, "]")) {
        while (true) {
            need_name(p);
            if (!at(p, ",")) { break; }
            advance(p); if (at(p, "]")) { break; }
        }
    }
    need(p, "]");
}

fn parse_params(p: ref Parser) {
    need(p, "(");
    if (!at(p, ")")) {
        while (true) {
            need_name(p); need(p, ":"); parse_type(p);
            if (!at(p, ",")) { break; }
            advance(p); if (at(p, ")")) { break; }
        }
    }
    need(p, ")");
}

fn precedence(token: const []u8) -> u64 {
    if (bytes.equal(token, "||")) { return 1; }
    if (bytes.equal(token, "&&")) { return 2; }
    if (bytes.equal(token, "==") || bytes.equal(token, "!=") || bytes.equal(token, "<") || bytes.equal(token, "<=") || bytes.equal(token, ">") || bytes.equal(token, ">=") || bytes.equal(token, "is")) { return 3; }
    if (bytes.equal(token, "|")) { return 4; }
    if (bytes.equal(token, "^")) { return 5; }
    if (bytes.equal(token, "&")) { return 6; }
    if (bytes.equal(token, "<<") || bytes.equal(token, ">>")) { return 7; }
    if (bytes.equal(token, "+") || bytes.equal(token, "-")) { return 8; }
    if (bytes.equal(token, "*") || bytes.equal(token, "/") || bytes.equal(token, "%")) { return 9; }
    return 0;
}

fn parse_payload_pattern(p: ref Parser) {
    if (at(p, "_")) { advance(p); return; }
    need_name(p);
}

fn parse_pattern(p: ref Parser) {
    if (at(p, "_") || at(p, "none") || at(p, "true") || at(p, "false")) { advance(p); return; }
    if (at(p, "some")) { advance(p); need(p, "("); parse_payload_pattern(p); need(p, ")"); return; }
    if (at(p, "(")) { advance(p); need(p, ")"); return; }
    if (at_kind(p, Kind.number) || at_kind(p, Kind.byte)) { advance(p); return; }
    if (at_kind(p, Kind.name)) {
        parse_qname(p);
        if (at(p, "(")) {
            advance(p);
            if (!at(p, ")")) {
                while (true) {
                    parse_payload_pattern(p);
                    if (!at(p, ",")) { break; }
                    advance(p); if (at(p, ")")) { break; }
                }
            }
            need(p, ")");
        }
        return;
    }
    var token = current(p); report(p, token, "expected pattern"); if (!eof(p)) { advance(p); }
}

fn parse_expr(p: ref Parser, min_prec: u64) {
    var token = current(p);
    if (at(p, "(")) {
        advance(p);
        if (at(p, ")")) { advance(p); }
        else { parse_expr(p, 0); need(p, ")"); }
    } else if (at_kind(p, Kind.number) || at_kind(p, Kind.string) || at_kind(p, Kind.byte) ||
        at(p, "true") || at(p, "false") || at(p, "none")) {
        advance(p);
    } else if (at(p, "some")) {
        advance(p); need(p, "("); parse_expr(p, 0); need(p, ")");
    } else if (at(p, "new")) {
        advance(p); parse_expr(p, 10);
    } else if (at(p, "fn")) {
        advance(p); parse_params(p);
        if (at(p, "->")) { advance(p); parse_type(p); }
        parse_block(p);
    } else if (at(p, "[")) {
        advance(p);
        if (!at(p, "]")) {
            parse_expr(p, 0);
            if (at(p, ";")) { advance(p); parse_expr(p, 0); }
            else {
                while (at(p, ",")) { advance(p); if (at(p, "]")) { break; } parse_expr(p, 0); }
            }
        }
        need(p, "]");
    } else if (at_kind(p, Kind.name)) {
        parse_qname(p);
    } else if (at(p, "!") || at(p, "~") || at(p, "-") || at(p, "*")) {
        advance(p); parse_expr(p, 10);
    } else {
        report(p, token, "expected expression"); if (!eof(p)) { advance(p); } return;
    }

    while (true) {
        if (at(p, "(")) {
            advance(p);
            if (!at(p, ")")) {
                while (true) {
                    parse_expr(p, 0);
                    if (!at(p, ",")) { break; }
                    advance(p); if (at(p, ")")) { break; }
                }
            }
            need(p, ")"); continue;
        }
        if (at(p, "[")) { advance(p); parse_expr(p, 0); need(p, "]"); continue; }
        if (at(p, ".")) { advance(p); need_name(p); continue; }
        if (at(p, "{")) {
            advance(p);
            if (!at(p, "}")) {
                while (true) {
                    need_name(p); need(p, ":"); parse_expr(p, 0);
                    if (!at(p, ",")) { break; }
                    advance(p); if (at(p, "}")) { break; }
                }
            }
            need(p, "}"); continue;
        }
        break;
    }
    if (at(p, "as")) { advance(p); parse_type(p); }

    var used_compare = false;
    while (true) {
        var op = current(p).text;
        var prec = precedence(op);
        if (prec == 0 || prec < min_prec) { break; }
        var compare = prec == 3;
        if (compare && used_compare) { report(p, current(p), "comparison operators do not chain"); }
        if (compare) { used_compare = true; }
        advance(p);
        if (bytes.equal(op, "is")) { parse_pattern(p); }
        else { parse_expr(p, prec + 1); }
    }
}

fn assignment_op(text: const []u8) -> bool {
    return bytes.equal(text, "=") || bytes.equal(text, "+=") || bytes.equal(text, "-=") || bytes.equal(text, "*=") ||
        bytes.equal(text, "/=") || bytes.equal(text, "%=") || bytes.equal(text, "<<=") || bytes.equal(text, ">>=") ||
        bytes.equal(text, "&=") || bytes.equal(text, "|=") || bytes.equal(text, "^=");
}

fn parse_assignment(p: ref Parser) {
    parse_expr(p, 0);
    if (assignment_op(current(p).text)) { advance(p); parse_expr(p, 0); }
    else { report(p, current(p), "expected assignment"); }
}

fn parse_block(p: ref Parser) {
    if (!need(p, "{")) { return; }
    while (!eof(p) && !at(p, "}")) {
        var before = p.pos;
        parse_stmt(p);
        if (p.pos == before && !eof(p)) { advance(p); }
    }
    need(p, "}");
}

fn parse_stmt(p: ref Parser) {
    if (at(p, "var")) {
        advance(p); need_name(p);
        if (at(p, ":")) { advance(p); parse_type(p); }
        need(p, "="); parse_expr(p, 0); need(p, ";"); return;
    }
    if (at(p, "if")) {
        advance(p); need(p, "("); parse_expr(p, 0); need(p, ")"); parse_block(p);
        if (at(p, "else")) { advance(p); if (at(p, "if")) { parse_stmt(p); } else { parse_block(p); } }
        return;
    }
    if (at(p, "while")) { advance(p); need(p, "("); parse_expr(p, 0); need(p, ")"); parse_block(p); return; }
    if (at(p, "for")) {
        advance(p); need(p, "(");
        if (at_kind(p, Kind.name)) {
            var saved = p.pos; advance(p);
            if (at(p, "in")) { advance(p); parse_expr(p, 0); need(p, ")"); parse_block(p); return; }
            p.pos = saved;
        }
        if (!at(p, ";")) {
            if (at(p, "var")) {
                advance(p); need_name(p); if (at(p, ":")) { advance(p); parse_type(p); } need(p, "="); parse_expr(p, 0);
            } else { parse_assignment(p); }
        }
        need(p, ";");
        if (!at(p, ";")) { parse_expr(p, 0); }
        need(p, ";");
        if (!at(p, ")")) { parse_assignment(p); }
        need(p, ")"); parse_block(p); return;
    }
    if (at(p, "match")) {
        advance(p); need(p, "("); parse_expr(p, 0); need(p, ")"); need(p, "{");
        while (!eof(p) && !at(p, "}")) { parse_pattern(p); parse_block(p); }
        need(p, "}"); return;
    }
    if (at(p, "return")) { advance(p); if (!at(p, ";")) { parse_expr(p, 0); } need(p, ";"); return; }
    if (at(p, "break") || at(p, "continue") || at(p, "trap")) { advance(p); need(p, ";"); return; }
    parse_expr(p, 0);
    if (assignment_op(current(p).text)) { advance(p); parse_expr(p, 0); }
    need(p, ";");
}

fn sync_decl(p: ref Parser) {
    var depth: u64 = 0;
    while (!eof(p)) {
        if (at(p, "{")) { depth += 1; advance(p); continue; }
        if (at(p, "}")) { if (depth > 0) { depth -= 1; } advance(p); continue; }
        if (depth == 0 && (at(p, "pub") || at(p, "import") || at(p, "const") || at(p, "struct") || at(p, "enum") || at(p, "fn"))) { return; }
        advance(p);
    }
}

fn parse_decl(p: ref Parser) {
    if (at(p, "pub")) { advance(p); }
    if (at(p, "import")) {
        advance(p); parse_qname(p); if (at(p, "as")) { advance(p); need_name(p); } need(p, ";"); return;
    }
    if (at(p, "const")) {
        advance(p); need_name(p); need(p, ":"); parse_type(p); need(p, "="); parse_expr(p, 0); need(p, ";"); return;
    }
    if (at(p, "struct")) {
        advance(p); need_name(p); parse_type_params(p); need(p, "{");
        if (!at(p, "}")) {
            while (true) {
                if (at(p, "pub")) { advance(p); }
                need_name(p); need(p, ":"); parse_type(p);
                if (!at(p, ",")) { break; }
                advance(p); if (at(p, "}")) { break; }
            }
        }
        need(p, "}"); return;
    }
    if (at(p, "enum")) {
        advance(p); need_name(p); parse_type_params(p); need(p, "{");
        if (!at(p, "}")) {
            while (true) {
                need_name(p);
                if (at(p, "(")) {
                    advance(p);
                    if (!at(p, ")")) {
                        while (true) {
                            parse_type(p);
                            if (!at(p, ",")) { break; }
                            advance(p); if (at(p, ")")) { break; }
                        }
                    }
                    need(p, ")");
                }
                if (!at(p, ",")) { break; }
                advance(p); if (at(p, "}")) { break; }
            }
        }
        need(p, "}"); return;
    }
    if (at(p, "fn")) {
        advance(p); need_name(p); parse_type_params(p); parse_params(p);
        if (at(p, "->")) { advance(p); parse_type(p); }
        parse_block(p); return;
    }
    var token = current(p); report(p, token, "expected declaration"); if (!eof(p)) { advance(p); }
}

pub fn errors(text: const []u8) -> []Error {
    var p = new Parser { tokens: scan(text), pos: 0, errors: [] };
    while (!eof(p)) {
        var before = p.pos;
        parse_decl(p);
        if (p.pos == before) { sync_decl(p); if (p.pos == before && !eof(p)) { advance(p); } }
    }
    return p.errors;
}
