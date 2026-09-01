import bytes;
import slang_syntax;

// A deliberately small structured view of an L source module. This is not yet
// the compiler AST: it gives tools and the future self-hosted resolver stable
// declaration/import identities and source extents without duplicating a
// top-level scanner.

pub enum DeclKind {
    constant,
    structure,
    enumeration,
    function,
}

pub struct Import {
    pub path: []u8,
    pub alias: ?[]u8,
    pub start: u64,
    pub end: u64,
}

pub struct Decl {
    pub kind: DeclKind,
    pub name: []u8,
    pub exported: bool,
    pub start: u64,
    pub end: u64,
}

pub struct ModuleIndex {
    pub imports: []Import,
    pub declarations: []Decl,
    pub errors: []slang_syntax.Error,
}

struct Indexer {
    tokens: []slang_syntax.Token,
    pos: u64,
}

fn skip_comments(indexer: ref Indexer) {
    while (indexer.pos < len(indexer.tokens) && indexer.tokens[indexer.pos].kind is slang_syntax.Kind.comment) {
        indexer.pos += 1;
    }
}

fn current(indexer: ref Indexer) -> slang_syntax.Token {
    skip_comments(indexer);
    return indexer.tokens[indexer.pos];
}

fn eof(indexer: ref Indexer) -> bool {
    return current(indexer).kind is slang_syntax.Kind.eof;
}

fn at(indexer: ref Indexer, text: []u8) -> bool {
    return bytes.equal(current(indexer).text, text);
}

fn advance(indexer: ref Indexer) -> slang_syntax.Token {
    var token = current(indexer);
    if (!(token.kind is slang_syntax.Kind.eof)) {
        indexer.pos += 1;
        skip_comments(indexer);
    }
    return token;
}

fn take_name(indexer: ref Indexer) -> ?slang_syntax.Token {
    var token = current(indexer);
    if (token.kind is slang_syntax.Kind.name) {
        advance(indexer);
        return some(token);
    }
    return none;
}

fn skip_to_semicolon(indexer: ref Indexer) -> u64 {
    var end = current(indexer).start;
    var paren: u64 = 0;
    var bracket: u64 = 0;
    while (!eof(indexer)) {
        var token = advance(indexer);
        end = token.end;
        if (bytes.equal(token.text, "(")) { paren += 1; }
        else if (bytes.equal(token.text, ")") && paren > 0) { paren -= 1; }
        else if (bytes.equal(token.text, "[")) { bracket += 1; }
        else if (bytes.equal(token.text, "]") && bracket > 0) { bracket -= 1; }
        else if (bytes.equal(token.text, ";") && paren == 0 && bracket == 0) { return end; }
    }
    return end;
}

fn skip_braced(indexer: ref Indexer) -> u64 {
    while (!eof(indexer) && !at(indexer, "{")) {
        advance(indexer);
    }
    if (eof(indexer)) {
        return current(indexer).end;
    }

    var depth: u64 = 0;
    var end = current(indexer).end;
    while (!eof(indexer)) {
        var token = advance(indexer);
        end = token.end;
        if (bytes.equal(token.text, "{")) {
            depth += 1;
        } else if (bytes.equal(token.text, "}")) {
            if (depth > 0) { depth -= 1; }
            if (depth == 0) { return end; }
        }
    }
    return end;
}

fn parse_import(indexer: ref Indexer, start: u64) -> Import {
    // `import` has already been consumed.
    var path: []u8 = [];
    var alias: ?[]u8 = none;
    var end = start;
    while (!eof(indexer) && !at(indexer, ";")) {
        if (at(indexer, "as")) {
            advance(indexer);
            var alias_token = take_name(indexer);
            match (alias_token) {
                none { }
                some(token) { alias = some(bytes.clone(token.text)); }
            }
            continue;
        }
        var token = advance(indexer);
        bytes.append(path, token.text);
        end = token.end;
    }
    if (at(indexer, ";")) {
        end = advance(indexer).end;
    }
    return Import { path: path, alias: alias, start: start, end: end };
}

fn push_decl(out: []Decl, kind: DeclKind, name: slang_syntax.Token, exported: bool, start: u64, end: u64) {
    push(out, Decl {
        kind: kind,
        name: bytes.clone(name.text),
        exported: exported,
        start: start,
        end: end,
    });
}

pub fn index(text: []u8) -> ModuleIndex {
    var errors = slang_syntax.errors(text);
    var indexer = new Indexer { tokens: slang_syntax.scan(text), pos: 0 };
    var imports: []Import = [];
    var declarations: []Decl = [];

    while (!eof(indexer)) {
        var first = current(indexer);
        var start = first.start;
        var exported = false;
        if (at(indexer, "pub")) {
            exported = true;
            start = advance(indexer).start;
        }

        if (at(indexer, "import")) {
            advance(indexer);
            push(imports, parse_import(indexer, start));
            continue;
        }

        if (at(indexer, "const")) {
            advance(indexer);
            var name = take_name(indexer);
            var end = skip_to_semicolon(indexer);
            match (name) {
                none { }
                some(token) { push_decl(declarations, DeclKind.constant, token, exported, start, end); }
            }
            continue;
        }

        if (at(indexer, "struct")) {
            advance(indexer);
            var name = take_name(indexer);
            var end = skip_braced(indexer);
            match (name) {
                none { }
                some(token) { push_decl(declarations, DeclKind.structure, token, exported, start, end); }
            }
            continue;
        }

        if (at(indexer, "enum")) {
            advance(indexer);
            var name = take_name(indexer);
            var end = skip_braced(indexer);
            match (name) {
                none { }
                some(token) { push_decl(declarations, DeclKind.enumeration, token, exported, start, end); }
            }
            continue;
        }

        if (at(indexer, "fn")) {
            advance(indexer);
            var name = take_name(indexer);
            var end = skip_braced(indexer);
            match (name) {
                none { }
                some(token) { push_decl(declarations, DeclKind.function, token, exported, start, end); }
            }
            continue;
        }

        // The full parser owns recovery. The index stays best-effort so editors
        // can still get declarations around an incomplete top-level construct.
        if (indexer.pos == 0 || current(indexer).start == first.start) {
            advance(indexer);
        }
    }

    return ModuleIndex { imports: imports, declarations: declarations, errors: errors };
}
