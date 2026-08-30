enum Token {
    number(i64);
    plus;
    star;
    lparen;
    rparen;
    eof;
}

enum Expr {
    number(i64);
    add(ref Expr, ref Expr);
    mul(ref Expr, ref Expr);
}

struct Parser {
    tokens: []Token;
    pos: u64;
}

fn is_digit(b: u8) -> bool {
    return b >= '0' && b <= '9';
}

fn tokenize(src: []u8) -> []Token {
    var out: []Token = [];
    var i: u64 = 0;
    while (i < len(src)) {
        var b = src[i];
        if (b == ' ' || b == '\t' || b == '\n') {
            i += 1;
            continue;
        }
        if (is_digit(b)) {
            var n: i64 = 0;
            while (i < len(src) && is_digit(src[i])) {
                n = n * 10 + ((src[i] - '0') as i64);
                i += 1;
            }
            push(out, Token.number(n));
            continue;
        }
        if (b == '+') { push(out, Token.plus()); }
        else if (b == '*') { push(out, Token.star()); }
        else if (b == '(') { push(out, Token.lparen()); }
        else if (b == ')') { push(out, Token.rparen()); }
        else { trap; }
        i += 1;
    }
    push(out, Token.eof());
    return out;
}

fn peek(p: ref Parser) -> Token {
    return p.tokens[p.pos];
}

fn take(p: ref Parser) -> Token {
    var t = p.tokens[p.pos];
    p.pos += 1;
    return t;
}

fn parse_primary(p: ref Parser) -> ref Expr {
    var t = take(p);
    match (t) {
        Token.number(n) {
            return new Expr.number(n);
        }
        Token.lparen {
            var e = parse_expr(p);
            match (take(p)) {
                Token.rparen { return e; }
                _ { trap; }
            }
        }
        _ { trap; }
    }
}

fn parse_term(p: ref Parser) -> ref Expr {
    var left = parse_primary(p);
    while (peek(p) is Token.star) {
        take(p);
        var right = parse_primary(p);
        left = new Expr.mul(left, right);
    }
    return left;
}

fn parse_expr(p: ref Parser) -> ref Expr {
    var left = parse_term(p);
    while (peek(p) is Token.plus) {
        take(p);
        var right = parse_term(p);
        left = new Expr.add(left, right);
    }
    return left;
}

fn eval(e: ref Expr) -> i64 {
    match (*e) {
        Expr.number(n) { return n; }
        Expr.add(a, b) { return eval(a) + eval(b); }
        Expr.mul(a, b) { return eval(a) * eval(b); }
    }
}

fn test() -> i64 {
    var tokens = tokenize("2 + 3 * (4 + 5)");
    var p = new Parser { tokens: tokens, pos: 0 };
    var e = parse_expr(p);
    match (peek(p)) {
        Token.eof { return eval(e); }
        _ { trap; }
    }
}
