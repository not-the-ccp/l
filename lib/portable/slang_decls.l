import bytes;
import slang_syntax;

// Structured declarations, recursive type syntax, and function-body AST for
// the self-hosting frontend. Parsing remains syntax-only: semantic identity and
// typing live in later layers.

pub enum TypeKind {
    unit,
    named,
    optional,
    reference,
    array,
    const_array,
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

pub enum PatternKind {
    wildcard,
    binding,
    unit,
    none_value,
    some_value,
    boolean,
    integer,
    byte,
    constructor,
}

pub struct Pattern {
    pub kind: PatternKind,
    pub name: []u8,
    pub children: []ref Pattern,
    pub start: u64,
    pub end: u64,
}

pub enum ExprKind {
    unit,
    boolean,
    integer,
    float,
    string,
    byte,
    none_value,
    name,
    some_value,
    array,
    repeat,
    unary,
    binary,
    cast,
    call,
    index,
    field,
    dereference,
    allocate,
    struct_literal,
    anonymous_function,
    pattern_test,
}

pub struct NamedExpr {
    pub name: []u8,
    pub value: ref Expr,
    pub start: u64,
    pub end: u64,
}

pub struct Expr {
    pub kind: ExprKind,
    pub text: []u8,
    pub op: []u8,
    pub children: []ref Expr,
    pub fields: []NamedExpr,
    pub parameters: []Parameter,
    pub type: ?ref Type,
    pub body: []ref Stmt,
    pub pattern: ?ref Pattern,
    pub start: u64,
    pub end: u64,
}

pub enum StmtKind {
    variable,
    assignment,
    expression,
    conditional,
    while_loop,
    for_loop,
    for_in,
    match_stmt,
    return_stmt,
    break_stmt,
    continue_stmt,
    trap_stmt,
}

pub struct MatchArm {
    pub pattern: ref Pattern,
    pub body: []ref Stmt,
    pub start: u64,
    pub end: u64,
}

pub struct Stmt {
    pub kind: StmtKind,
    pub name: []u8,
    pub op: []u8,
    pub type: ?ref Type,
    pub expressions: []ref Expr,
    pub body: []ref Stmt,
    pub alternate: []ref Stmt,
    pub init: ?ref Stmt,
    pub step: ?ref Stmt,
    pub arms: []MatchArm,
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
    pub value: ?ref Expr,
    pub body: []ref Stmt,
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
    if (!at(parser, text)) { trap; }
    return advance(parser);
}

fn take_name(parser: ref Parser) -> slang_syntax.Token {
    var token = current(parser);
    if (!(token.kind is slang_syntax.Kind.name)) { trap; }
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
    if (at(parser, "?")) {
        var start = advance(parser).start;
        var inner = parse_type(parser);
        return new Type { kind: TypeKind.optional, name: [], children: [inner],
            parameter_count: 0, start: start, end: inner.end };
    }

    if (at(parser, "ref")) {
        var start = advance(parser).start;
        var inner = parse_type(parser);
        return new Type { kind: TypeKind.reference, name: [], children: [inner],
            parameter_count: 0, start: start, end: inner.end };
    }

    if (at(parser, "const")) {
        var start = advance(parser).start;
        take(parser, "[");
        take(parser, "]");
        var inner = parse_type(parser);
        return new Type { kind: TypeKind.const_array, name: [], children: [inner],
            parameter_count: 0, start: start, end: inner.end };
    }

    if (at(parser, "[")) {
        var start = advance(parser).start;
        take(parser, "]");
        var inner = parse_type(parser);
        return new Type { kind: TypeKind.array, name: [], children: [inner],
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
    if (!at(parser, "[")) { return out; }
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

fn parse_parameters(parser: ref Parser) -> []Parameter {
    var out: []Parameter = [];
    take(parser, "(");
    if (!at(parser, ")")) {
        while (true) {
            var name = take_name(parser);
            take(parser, ":");
            var type = parse_type(parser);
            push(out, Parameter { name: bytes.clone(name.text), type: type,
                start: name.start, end: type.end });
            if (!at(parser, ",")) { break; }
            advance(parser);
            if (at(parser, ")")) { break; }
        }
    }
    take(parser, ")");
    return out;
}

fn empty_expr(kind: ExprKind, start: u64, end: u64) -> ref Expr {
    return new Expr {
        kind: kind,
        text: [],
        op: [],
        children: [],
        fields: [],
        parameters: [],
        type: none,
        body: [],
        pattern: none,
        start: start,
        end: end,
    };
}

fn literal_expr(kind: ExprKind, token: slang_syntax.Token) -> ref Expr {
    var out = empty_expr(kind, token.start, token.end);
    out.text = bytes.clone(token.text);
    return out;
}

fn empty_pattern(kind: PatternKind, start: u64, end: u64) -> ref Pattern {
    return new Pattern { kind: kind, name: [], children: [], start: start, end: end };
}

fn binding_pattern(token: slang_syntax.Token) -> ref Pattern {
    var out = empty_pattern(PatternKind.binding, token.start, token.end);
    out.name = bytes.clone(token.text);
    return out;
}

fn parse_payload_pattern(parser: ref Parser) -> ref Pattern {
    if (at(parser, "_")) {
        var token = advance(parser);
        return empty_pattern(PatternKind.wildcard, token.start, token.end);
    }
    return binding_pattern(take_name(parser));
}

fn parse_pattern(parser: ref Parser) -> ref Pattern {
    var first = current(parser);
    if (at(parser, "_")) {
        var token = advance(parser);
        return empty_pattern(PatternKind.wildcard, token.start, token.end);
    }
    if (at(parser, "none")) {
        var token = advance(parser);
        return empty_pattern(PatternKind.none_value, token.start, token.end);
    }
    if (at(parser, "true") || at(parser, "false")) {
        var token = advance(parser);
        var out = empty_pattern(PatternKind.boolean, token.start, token.end);
        out.name = bytes.clone(token.text);
        return out;
    }
    if (at(parser, "some")) {
        var start = advance(parser).start;
        take(parser, "(");
        var child = parse_payload_pattern(parser);
        var end = take(parser, ")").end;
        var out = empty_pattern(PatternKind.some_value, start, end);
        out.children = [child];
        return out;
    }
    if (at(parser, "(")) {
        var start = advance(parser).start;
        var end = take(parser, ")").end;
        return empty_pattern(PatternKind.unit, start, end);
    }
    if (first.kind is slang_syntax.Kind.number) {
        var token = advance(parser);
        var out = empty_pattern(PatternKind.integer, token.start, token.end);
        out.name = bytes.clone(token.text);
        return out;
    }
    if (first.kind is slang_syntax.Kind.byte) {
        var token = advance(parser);
        var out = empty_pattern(PatternKind.byte, token.start, token.end);
        out.name = bytes.clone(token.text);
        return out;
    }

    var name = parse_qname(parser);
    var children: []ref Pattern = [];
    var end = name.end;
    if (at(parser, "(")) {
        advance(parser);
        if (!at(parser, ")")) {
            while (true) {
                push(children, parse_payload_pattern(parser));
                if (!at(parser, ",")) { break; }
                advance(parser);
                if (at(parser, ")")) { break; }
            }
        }
        end = take(parser, ")").end;
    }
    if (len(children) == 0 && bytes.find_byte(name.text, '.', 0) is none) {
        var out = empty_pattern(PatternKind.binding, name.start, end);
        out.name = name.text;
        return out;
    }
    var out = empty_pattern(PatternKind.constructor, name.start, end);
    out.name = name.text;
    out.children = children;
    return out;
}

fn precedence(op: []u8) -> u64 {
    if (bytes.equal(op, "||")) { return 1; }
    if (bytes.equal(op, "&&")) { return 2; }
    if (bytes.equal(op, "==") || bytes.equal(op, "!=") || bytes.equal(op, "<") ||
        bytes.equal(op, "<=") || bytes.equal(op, ">") || bytes.equal(op, ">=") || bytes.equal(op, "is")) { return 3; }
    if (bytes.equal(op, "|")) { return 4; }
    if (bytes.equal(op, "^")) { return 5; }
    if (bytes.equal(op, "&")) { return 6; }
    if (bytes.equal(op, "<<") || bytes.equal(op, ">>")) { return 7; }
    if (bytes.equal(op, "+") || bytes.equal(op, "-")) { return 8; }
    if (bytes.equal(op, "*") || bytes.equal(op, "/") || bytes.equal(op, "%")) { return 9; }
    return 0;
}

fn parse_block(parser: ref Parser) -> []ref Stmt {
    var out: []ref Stmt = [];
    take(parser, "{");
    while (!at(parser, "}")) { push(out, parse_stmt(parser)); }
    take(parser, "}");
    return out;
}

fn parse_expr(parser: ref Parser, min_precedence: u64) -> ref Expr {
    var first = current(parser);
    var value: ref Expr = empty_expr(ExprKind.unit, first.start, first.end);

    if (at(parser, "(")) {
        var start = advance(parser).start;
        if (at(parser, ")")) {
            var end = advance(parser).end;
            value = empty_expr(ExprKind.unit, start, end);
        } else {
            value = parse_expr(parser, 0);
            value.start = start;
            value.end = take(parser, ")").end;
        }
    } else if (first.kind is slang_syntax.Kind.number) {
        var token = advance(parser);
        var is_float = bytes.find_byte(token.text, '.', 0) is some(_);
        if (!is_float) {
            is_float = bytes.find_byte(token.text, 'e', 0) is some(_) || bytes.find_byte(token.text, 'E', 0) is some(_);
        }
        value = literal_expr(ExprKind.integer, token);
        if (is_float) { value.kind = ExprKind.float; }
    } else if (first.kind is slang_syntax.Kind.string) {
        value = literal_expr(ExprKind.string, advance(parser));
    } else if (first.kind is slang_syntax.Kind.byte) {
        value = literal_expr(ExprKind.byte, advance(parser));
    } else if (at(parser, "true") || at(parser, "false")) {
        value = literal_expr(ExprKind.boolean, advance(parser));
    } else if (at(parser, "none")) {
        var token = advance(parser);
        value = empty_expr(ExprKind.none_value, token.start, token.end);
    } else if (at(parser, "some")) {
        var start = advance(parser).start;
        take(parser, "(");
        var child = parse_expr(parser, 0);
        var end = take(parser, ")").end;
        value = empty_expr(ExprKind.some_value, start, end);
        value.children = [child];
    } else if (at(parser, "new")) {
        var start = advance(parser).start;
        var child = parse_expr(parser, 10);
        value = empty_expr(ExprKind.allocate, start, child.end);
        value.children = [child];
    } else if (at(parser, "fn")) {
        var start = advance(parser).start;
        var parameters = parse_parameters(parser);
        var result: ?ref Type = none;
        if (at(parser, "->")) {
            advance(parser);
            result = some(parse_type(parser));
        }
        var body = parse_block(parser);
        var end = current(parser).start;
        if (len(body) > 0) { end = body[len(body) - 1].end; }
        value = empty_expr(ExprKind.anonymous_function, start, end);
        value.parameters = parameters;
        value.type = result;
        value.body = body;
    } else if (at(parser, "[")) {
        var start = advance(parser).start;
        var children: []ref Expr = [];
        var repeated = false;
        if (!at(parser, "]")) {
            push(children, parse_expr(parser, 0));
            if (at(parser, ";")) {
                repeated = true;
                advance(parser);
                push(children, parse_expr(parser, 0));
            } else {
                while (at(parser, ",")) {
                    advance(parser);
                    if (at(parser, "]")) { break; }
                    push(children, parse_expr(parser, 0));
                }
            }
        }
        var end = take(parser, "]").end;
        value = empty_expr(ExprKind.array, start, end);
        if (repeated) { value.kind = ExprKind.repeat; }
        value.children = children;
    } else if (at(parser, "!") || at(parser, "~") || at(parser, "-") || at(parser, "*")) {
        var token = advance(parser);
        var child = parse_expr(parser, 10);
        if (bytes.equal(token.text, "*")) {
            value = empty_expr(ExprKind.dereference, token.start, child.end);
        } else {
            value = empty_expr(ExprKind.unary, token.start, child.end);
            value.op = bytes.clone(token.text);
        }
        value.children = [child];
    } else {
        var name = parse_qname(parser);
        value = empty_expr(ExprKind.name, name.start, name.end);
        value.text = name.text;
    }

    while (true) {
        if (at(parser, "(")) {
            advance(parser);
            var children: []ref Expr = [value];
            if (!at(parser, ")")) {
                while (true) {
                    push(children, parse_expr(parser, 0));
                    if (!at(parser, ",")) { break; }
                    advance(parser);
                    if (at(parser, ")")) { break; }
                }
            }
            var end = take(parser, ")").end;
            var call = empty_expr(ExprKind.call, value.start, end);
            call.children = children;
            value = call;
            continue;
        }
        if (at(parser, "[")) {
            advance(parser);
            var index = parse_expr(parser, 0);
            var end = take(parser, "]").end;
            var indexed = empty_expr(ExprKind.index, value.start, end);
            indexed.children = [value, index];
            value = indexed;
            continue;
        }
        if (at(parser, ".")) {
            advance(parser);
            var field = take_name(parser);
            var selected = empty_expr(ExprKind.field, value.start, field.end);
            selected.text = bytes.clone(field.text);
            selected.children = [value];
            value = selected;
            continue;
        }
        if (at(parser, "{")) {
            advance(parser);
            var fields: []NamedExpr = [];
            if (!at(parser, "}")) {
                while (true) {
                    var name = take_name(parser);
                    take(parser, ":");
                    var field_value = parse_expr(parser, 0);
                    push(fields, NamedExpr { name: bytes.clone(name.text), value: field_value,
                        start: name.start, end: field_value.end });
                    if (!at(parser, ",")) { break; }
                    advance(parser);
                    if (at(parser, "}")) { break; }
                }
            }
            var end = take(parser, "}").end;
            var structure = empty_expr(ExprKind.struct_literal, value.start, end);
            structure.children = [value];
            structure.fields = fields;
            value = structure;
            continue;
        }
        break;
    }

    if (at(parser, "as")) {
        advance(parser);
        var type = parse_type(parser);
        var cast = empty_expr(ExprKind.cast, value.start, type.end);
        cast.children = [value];
        cast.type = some(type);
        value = cast;
    }

    while (true) {
        var token = current(parser);
        var prec = precedence(token.text);
        if (prec == 0 || prec < min_precedence) { break; }
        advance(parser);
        if (bytes.equal(token.text, "is")) {
            var pattern = parse_pattern(parser);
            var tested = empty_expr(ExprKind.pattern_test, value.start, pattern.end);
            tested.children = [value];
            tested.pattern = some(pattern);
            value = tested;
        } else {
            var right = parse_expr(parser, prec + 1);
            var binary = empty_expr(ExprKind.binary, value.start, right.end);
            binary.op = bytes.clone(token.text);
            binary.children = [value, right];
            value = binary;
        }
    }

    return value;
}

fn assignment_op(text: []u8) -> bool {
    return bytes.equal(text, "=") || bytes.equal(text, "+=") || bytes.equal(text, "-=") ||
        bytes.equal(text, "*=") || bytes.equal(text, "/=") || bytes.equal(text, "%=") ||
        bytes.equal(text, "<<=") || bytes.equal(text, ">>=") || bytes.equal(text, "&=") ||
        bytes.equal(text, "|=") || bytes.equal(text, "^=");
}

fn empty_stmt(kind: StmtKind, start: u64, end: u64) -> ref Stmt {
    return new Stmt {
        kind: kind,
        name: [],
        op: [],
        type: none,
        expressions: [],
        body: [],
        alternate: [],
        init: none,
        step: none,
        arms: [],
        start: start,
        end: end,
    };
}

fn parse_assignment(parser: ref Parser) -> ref Stmt {
    var left = parse_expr(parser, 0);
    var operator = advance(parser);
    if (!assignment_op(operator.text)) { trap; }
    var right = parse_expr(parser, 0);
    var out = empty_stmt(StmtKind.assignment, left.start, right.end);
    out.op = bytes.clone(operator.text);
    out.expressions = [left, right];
    return out;
}

fn parse_variable(parser: ref Parser, start: u64, with_semicolon: bool) -> ref Stmt {
    var name = take_name(parser);
    var type: ?ref Type = none;
    if (at(parser, ":")) {
        advance(parser);
        type = some(parse_type(parser));
    }
    take(parser, "=");
    var value = parse_expr(parser, 0);
    var end = value.end;
    if (with_semicolon) { end = take(parser, ";").end; }
    var out = empty_stmt(StmtKind.variable, start, end);
    out.name = bytes.clone(name.text);
    out.type = type;
    out.expressions = [value];
    return out;
}

fn parse_stmt(parser: ref Parser) -> ref Stmt {
    var start = current(parser).start;

    if (at(parser, "var")) {
        advance(parser);
        return parse_variable(parser, start, true);
    }

    if (at(parser, "if")) {
        advance(parser);
        take(parser, "(");
        var condition = parse_expr(parser, 0);
        take(parser, ")");
        var body = parse_block(parser);
        var alternate: []ref Stmt = [];
        var end = condition.end;
        if (len(body) > 0) { end = body[len(body) - 1].end; }
        if (at(parser, "else")) {
            advance(parser);
            if (at(parser, "if")) {
                var nested = parse_stmt(parser);
                push(alternate, nested);
                end = nested.end;
            } else {
                alternate = parse_block(parser);
                if (len(alternate) > 0) { end = alternate[len(alternate) - 1].end; }
            }
        }
        var out = empty_stmt(StmtKind.conditional, start, end);
        out.expressions = [condition];
        out.body = body;
        out.alternate = alternate;
        return out;
    }

    if (at(parser, "while")) {
        advance(parser);
        take(parser, "(");
        var condition = parse_expr(parser, 0);
        take(parser, ")");
        var body = parse_block(parser);
        var end = condition.end;
        if (len(body) > 0) { end = body[len(body) - 1].end; }
        var out = empty_stmt(StmtKind.while_loop, start, end);
        out.expressions = [condition];
        out.body = body;
        return out;
    }

    if (at(parser, "for")) {
        advance(parser);
        take(parser, "(");
        if (current(parser).kind is slang_syntax.Kind.name) {
            var saved = parser.pos;
            var name = advance(parser);
            if (at(parser, "in")) {
                advance(parser);
                var iterable = parse_expr(parser, 0);
                take(parser, ")");
                var body = parse_block(parser);
                var end = iterable.end;
                if (len(body) > 0) { end = body[len(body) - 1].end; }
                var out = empty_stmt(StmtKind.for_in, start, end);
                out.name = bytes.clone(name.text);
                out.expressions = [iterable];
                out.body = body;
                return out;
            }
            parser.pos = saved;
        }

        var init: ?ref Stmt = none;
        if (!at(parser, ";")) {
            if (at(parser, "var")) {
                var init_start = advance(parser).start;
                init = some(parse_variable(parser, init_start, false));
            } else {
                init = some(parse_assignment(parser));
            }
        }
        take(parser, ";");
        var expressions: []ref Expr = [];
        if (!at(parser, ";")) { push(expressions, parse_expr(parser, 0)); }
        take(parser, ";");
        var step: ?ref Stmt = none;
        if (!at(parser, ")")) { step = some(parse_assignment(parser)); }
        take(parser, ")");
        var body = parse_block(parser);
        var end = current(parser).start;
        if (len(body) > 0) { end = body[len(body) - 1].end; }
        var out = empty_stmt(StmtKind.for_loop, start, end);
        out.init = init;
        out.expressions = expressions;
        out.step = step;
        out.body = body;
        return out;
    }

    if (at(parser, "match")) {
        advance(parser);
        take(parser, "(");
        var value = parse_expr(parser, 0);
        take(parser, ")");
        take(parser, "{");
        var arms: []MatchArm = [];
        var end = value.end;
        while (!at(parser, "}")) {
            var arm_start = current(parser).start;
            var pattern = parse_pattern(parser);
            var body = parse_block(parser);
            var arm_end = pattern.end;
            if (len(body) > 0) { arm_end = body[len(body) - 1].end; }
            push(arms, MatchArm { pattern: pattern, body: body, start: arm_start, end: arm_end });
            end = arm_end;
        }
        end = take(parser, "}").end;
        var out = empty_stmt(StmtKind.match_stmt, start, end);
        out.expressions = [value];
        out.arms = arms;
        return out;
    }

    if (at(parser, "return")) {
        advance(parser);
        var expressions: []ref Expr = [];
        if (!at(parser, ";")) { push(expressions, parse_expr(parser, 0)); }
        var end = take(parser, ";").end;
        var out = empty_stmt(StmtKind.return_stmt, start, end);
        out.expressions = expressions;
        return out;
    }

    if (at(parser, "break")) {
        advance(parser);
        return empty_stmt(StmtKind.break_stmt, start, take(parser, ";").end);
    }
    if (at(parser, "continue")) {
        advance(parser);
        return empty_stmt(StmtKind.continue_stmt, start, take(parser, ";").end);
    }
    if (at(parser, "trap")) {
        advance(parser);
        return empty_stmt(StmtKind.trap_stmt, start, take(parser, ";").end);
    }

    var left = parse_expr(parser, 0);
    if (assignment_op(current(parser).text)) {
        var operator = advance(parser);
        var right = parse_expr(parser, 0);
        var end = take(parser, ";").end;
        var assigned = empty_stmt(StmtKind.assignment, start, end);
        assigned.op = bytes.clone(operator.text);
        assigned.expressions = [left, right];
        return assigned;
    }
    var end = take(parser, ";").end;
    var out = empty_stmt(StmtKind.expression, start, end);
    out.expressions = [left];
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
        value: none,
        body: [],
        start: start,
        end: name.end,
    };
}

fn parse_const(parser: ref Parser, exported: bool, start: u64) -> Decl {
    var name = take_name(parser);
    take(parser, ":");
    var type = parse_type(parser);
    take(parser, "=");
    var value = parse_expr(parser, 0);
    var end = take(parser, ";").end;
    var decl = empty_decl(DeclKind.constant, name, exported, [], start);
    decl.value_type = some(type);
    decl.value = some(value);
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
        if (at(parser, "pub")) { field_exported = true; advance(parser); }
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
    decl.parameters = parse_parameters(parser);
    var close = current(parser).start;
    var result = empty_type(TypeKind.unit, close, close);
    if (at(parser, "->")) { advance(parser); result = parse_type(parser); }
    decl.return_type = some(result);
    decl.body = parse_block(parser);
    decl.end = current(parser).start;
    if (len(decl.body) > 0) { decl.end = decl.body[len(decl.body) - 1].end; }
    return decl;
}

pub fn parse(text: const []u8) -> Module {
    var errors = slang_syntax.errors(text);
    if (len(errors) > 0) { return Module { declarations: [], errors: errors }; }

    var parser = new Parser { tokens: slang_syntax.scan(text), pos: 0 };
    var declarations: []Decl = [];
    while (!eof(parser)) {
        var start = current(parser).start;
        var exported = false;
        if (at(parser, "pub")) { exported = true; advance(parser); }

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
