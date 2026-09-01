import bytes;
import slang_syntax;

// Structured top-level declarations and recursive type syntax for the
// self-hosting frontend. Function bodies are deliberately left opaque here;
// body AST construction is a later layer.

pub enum TypeKind {
    unit,
    named,
    optional,
    reference,
    array,
    function,
}

pub struct Type {
    pub kind: TypeKind,
    pub name: []u8,
    pub children: []ref Type,
    pub parameter_count: u64,
    pub start: u64,
    pub end: u64,
}

pub struct GenericParam {
    pub name: []u8,
    pub start: u64,
    pub end: u64,
}

pub struct Field {
    pub name: []u8,
    pub exported: bool,
    pub type: ref Type,
    pub start: u64,
    pub end: u64,
}

pub struct Variant {
    pub name: []u8,
    pub payload: []ref Type,
    pub start: u64,
    pub end: u64,
}

pub struct Parameter {
    pub name: []u8,
    pub type: ref Type,
    pub start: u64,
    pub end: u64,
}

pub enum DeclKind {
    constant,
    structure,
    enumeration,
    function,
}

pub struct Decl {
    pub kind: DeclKind,
    pub name: []u8,
    pub exported: bool,
    pub generics: []GenericParam,
    pub fields: []Field,
    pub variants: []Variant,
    pub parameters: []Parameter,
    pub value_type: ?ref Type,
    pub return_type: ?ref Type,
    pub start: u64,
    pub end: u64,
}

pub struct Module {
    pub declarations: []Decl,
    pub errors: []slang_syntax.Error,
}

struct Name {
    text: []u8,
    start: u64,
    end: u64,
}

struct Parser {
    tokens: []slang_syntax.Token,
    pos: u64,
}

fn skip_comments(parser: ref Parser) {
    while (parser.pos < len(parser.tokens) && parser.tokens[parser.pos].kind is slang_syntax.Kind.comment) {
        parser.pos += 1;
    }
}

fn current(parser: ref Parser) -> slang_syntax.Token {
    skip_comments(parser);
    return parser.tokens[parser.pos];
}

fn at(parser: ref Parser, text: []u8) -> bool {
    return bytes.equal(current(parser).text, text);
}

fn eof(parser: ref Parser) -> bool {
    return current(parser).kind is slang_syntax.Kind.eof;
}

fn advance(parser: ref Parser) -> slang_syntax.Token {
    var token = current(parser);
    if (!(token.kind is slang_syntax.Kind.eof)) {
        parser.pos += 1;
        skip_comments(parser);
    }
    return token;
}

fn take(parser: ref Parser, text: []u8) -> slang_syntax.Token {
    if (!at(parser, text)) {
        trap;
    }
    return advance(parser);
}

fn take_name(parser: ref Parser) -> slang_syntax.Token {
    var token = current(parser);
    if (!(token.kind is slang_syntax.Kind.name)) {
        trap;
    }
    advance(parser);
    return token;
}

fn empty_type(kind: TypeKind, start: u64, end: u64) -> ref Type {
    return new Type {
        kind: kind,
        name: [],
        children: [],
        parameter_count: 0,
        start: start,
        end: end,
    };
}

fn parse_qname(parser: ref Parser) -> Name {
    var first = take_name(parser);
    var text = bytes.clone(first.text);
    var end = first.end;
    while (at(parser, ".")) {
        advance(parser);
        var part = take_name(parser);
        bytes.append(text, ".");
        bytes.append(text, part.text);
        end = part.end;
    }
    return Name { text: text, start: first.start, end: end };
}

fn parse_type(parser: ref Parser) -> ref Type {
    var first = current(parser);

    if (at(parser, "?")) {
        var start = advance(parser).start;
        var inner = parse_type(parser);
        var children: []ref Type = [inner];
        return new Type { kind: TypeKind.optional, name: [], children: children,
            parameter_count: 0, start: start, end: inner.end };
    }

    if (at(parser, "ref")) {
        var start = advance(parser).start;
        var inner = parse_type(parser);
        var children: []ref Type = [inner];
        return new Type { kind: TypeKind.reference, name: [], children: children,
            parameter_count: 0, start: start, end: inner.end };
    }

    if (at(parser, "[")) {
        var start = advance(parser).start;
        take(parser, "]");
        var inner = parse_type(parser);
        var children: []ref Type = [inner];
        return new Type { kind: TypeKind.array, name: [], children: children,
            parameter_count: 0, start: start, end: inner.end };
    }

    if (at(parser, "(")) {
        var start = advance(parser).start;
        var end = take(parser, ")").end;
        return empty_type(TypeKind.unit, start, end);
    }

    if (at(parser, "fn")) {
        var start = advance(parser).start;
        take(parser, "(");
        var children: []ref Type = [];
        var parameter_count: u64 = 0;
        if (!at(parser, ")")) {
            while (true) {
                push(children, parse_type(parser));
                parameter_count += 1;
                if (!at(parser, ",")) { break; }
                advance(parser);
                if (at(parser, ")")) { break; }
            }
        }
        var close = take(parser, ")");
        var result = empty_type(TypeKind.unit, close.end, close.end);
        if (at(parser, "->")) {
            advance(parser);
            result = parse_type(parser);
        }
        push(children, result);
        return new Type { kind: TypeKind.function, name: [], children: children,
            parameter_count: parameter_count, start: start, end: result.end };
    }

    var name = parse_qname(parser);
    var arguments: []ref Type = [];
    var end = name.end;
    if (at(parser, "[")) {
        advance(parser);
        if (!at(parser, "]")) {
            while (true) {
                var argument = parse_type(parser);
                push(arguments, argument);
                end = argument.end;
                if (!at(parser, ",")) { break; }
                advance(parser);
                if (at(parser, "]")) { break; }
            }
        }
        end = take(parser, "]").end;
    }
    return new Type { kind: TypeKind.named, name: name.text, children: arguments,
        parameter_count: 0, start: name.start, end: end };
}

fn parse_generics(parser: ref Parser) -> []GenericParam {
    var out: []GenericParam = [];
    if (!at(parser, "[")) {
        return out;
    }
    advance(parser);
    if (!at(parser, "]")) {
        while (true) {
            var token = take_name(parser);
            push(out, GenericParam { name: bytes.clone(token.text), start: token.start, end: token.end });
            if (!at(parser, ",")) { break; }
            advance(parser);
            if (at(parser, "]")) { break; }
        }
    }
    take(parser, "]");
    return out;
}

fn skip_semicolon(parser: ref Parser) -> u64 {
    var paren: u64 = 0;
    var bracket: u64 = 0;
    var brace: u64 = 0;
    var end = current(parser).start;
    while (!eof(parser)) {
        var token = advance(parser);
        end = token.end;
        if (bytes.equal(token.text, "(")) { paren += 1; }
        else if (bytes.equal(token.text, ")") && paren > 0) { paren -= 1; }
        else if (bytes.equal(token.text, "[")) { bracket += 1; }
        else if (bytes.equal(token.text, "]") && bracket > 0) { bracket -= 1; }
        else if (bytes.equal(token.text, "{")) { brace += 1; }
        else if (bytes.equal(token.text, "}") && brace > 0) { brace -= 1; }
        else if (bytes.equal(token.text, ";") && paren == 0 && bracket == 0 && brace == 0) { return end; }
    }
    return end;
}

fn skip_braced(parser: ref Parser) -> u64 {
    take(parser, "{");
    var depth: u64 = 1;
    var end = current(parser).start;
    while (depth > 0 && !eof(parser)) {
        var token = advance(parser);
        end = token.end;
        if (bytes.equal(token.text, "{")) { depth += 1; }
        else if (bytes.equal(token.text, "}")) { depth -= 1; }
    }
    return end;
}

fn empty_decl(kind: DeclKind, name: slang_syntax.Token, exported: bool, generics: []GenericParam, start: u64) -> Decl {
    return Decl {
        kind: kind,
        name: bytes.clone(name.text),
        exported: exported,
        generics: generics,
        fields: [],
        variants: [],
        parameters: [],
        value_type: none,
        return_type: none,
        start: start,
        end: name.end,
    };
}

fn parse_const(parser: ref Parser, exported: bool, start: u64) -> Decl {
    var name = take_name(parser);
    take(parser, ":");
    var type = parse_type(parser);
    take(parser, "=");
    var end = skip_semicolon(parser);
    var decl = empty_decl(DeclKind.constant, name, exported, [], start);
    decl.value_type = some(type);
    decl.end = end;
    return decl;
}

fn parse_struct(parser: ref Parser, exported: bool, start: u64) -> Decl {
    var name = take_name(parser);
    var generics = parse_generics(parser);
    var decl = empty_decl(DeclKind.structure, name, exported, generics, start);
    take(parser, "{");
    while (!at(parser, "}")) {
        var field_start = current(parser).start;
        var field_exported = false;
        if (at(parser, "pub")) {
            field_exported = true;
            advance(parser);
        }
        var field_name = take_name(parser);
        take(parser, ":");
        var field_type = parse_type(parser);
        push(decl.fields, Field { name: bytes.clone(field_name.text), exported: field_exported,
            type: field_type, start: field_start, end: field_type.end });
        if (!at(parser, ",")) { break; }
        advance(parser);
        if (at(parser, "}")) { break; }
    }
    decl.end = take(parser, "}").end;
    return decl;
}

fn parse_enum(parser: ref Parser, exported: bool, start: u64) -> Decl {
    var name = take_name(parser);
    var generics = parse_generics(parser);
    var decl = empty_decl(DeclKind.enumeration, name, exported, generics, start);
    take(parser, "{");
    while (!at(parser, "}")) {
        var variant_name = take_name(parser);
        var payload: []ref Type = [];
        var end = variant_name.end;
        if (at(parser, "(")) {
            advance(parser);
            if (!at(parser, ")")) {
                while (true) {
                    var type = parse_type(parser);
                    push(payload, type);
                    end = type.end;
                    if (!at(parser, ",")) { break; }
                    advance(parser);
                    if (at(parser, ")")) { break; }
                }
            }
            end = take(parser, ")").end;
        }
        push(decl.variants, Variant { name: bytes.clone(variant_name.text), payload: payload,
            start: variant_name.start, end: end });
        if (!at(parser, ",")) { break; }
        advance(parser);
        if (at(parser, "}")) { break; }
    }
    decl.end = take(parser, "}").end;
    return decl;
}

fn parse_function(parser: ref Parser, exported: bool, start: u64) -> Decl {
    var name = take_name(parser);
    var generics = parse_generics(parser);
    var decl = empty_decl(DeclKind.function, name, exported, generics, start);
    take(parser, "(");
    if (!at(parser, ")")) {
        while (true) {
            var parameter_name = take_name(parser);
            take(parser, ":");
            var parameter_type = parse_type(parser);
            push(decl.parameters, Parameter { name: bytes.clone(parameter_name.text), type: parameter_type,
                start: parameter_name.start, end: parameter_type.end });
            if (!at(parser, ",")) { break; }
            advance(parser);
            if (at(parser, ")")) { break; }
        }
    }
    var close = take(parser, ")");
    var result = empty_type(TypeKind.unit, close.end, close.end);
    if (at(parser, "->")) {
        advance(parser);
        result = parse_type(parser);
    }
    decl.return_type = some(result);
    decl.end = skip_braced(parser);
    return decl;
}

pub fn parse(text: []u8) -> Module {
    var errors = slang_syntax.errors(text);
    if (len(errors) > 0) {
        return Module { declarations: [], errors: errors };
    }

    var parser = new Parser { tokens: slang_syntax.scan(text), pos: 0 };
    var declarations: []Decl = [];
    while (!eof(parser)) {
        var start = current(parser).start;
        var exported = false;
        if (at(parser, "pub")) {
            exported = true;
            advance(parser);
        }

        if (at(parser, "import")) {
            advance(parser);
            skip_semicolon(parser);
            continue;
        }
        if (at(parser, "const")) {
            advance(parser);
            push(declarations, parse_const(parser, exported, start));
            continue;
        }
        if (at(parser, "struct")) {
            advance(parser);
            push(declarations, parse_struct(parser, exported, start));
            continue;
        }
        if (at(parser, "enum")) {
            advance(parser);
            push(declarations, parse_enum(parser, exported, start));
            continue;
        }
        if (at(parser, "fn")) {
            advance(parser);
            push(declarations, parse_function(parser, exported, start));
            continue;
        }
        trap;
    }

    return Module { declarations: declarations, errors: errors };
}
