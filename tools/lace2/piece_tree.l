import arrays;
import bytes;

const CHUNK_BYTES: u64 = 4096;

pub enum Source { original, added }

struct Piece {
    source: Source,
    start: u64,
    length: u64,
    newlines: u64,
}

struct Node {
    piece: Piece,
    left: ?ref Node,
    right: ?ref Node,
    byte_len: u64,
    newline_count: u64,
    height: u64,
}

pub struct Snapshot {
    root: ?ref Node,
}

pub struct Text {
    original: []u8,
    added: []u8,
    root: ?ref Node,
}

struct Split {
    left: ?ref Node,
    right: ?ref Node,
}

struct PopFirst {
    piece: Piece,
    rest: ?ref Node,
}

fn max_u64(a: u64, b: u64) -> u64 {
    if (a > b) { return a; }
    return b;
}

fn node_height(node_opt: ?ref Node) -> u64 {
    match (node_opt) {
        none { return 0; }
        some(node) { return node.height; }
    }
}

fn node_bytes(node_opt: ?ref Node) -> u64 {
    match (node_opt) {
        none { return 0; }
        some(node) { return node.byte_len; }
    }
}

fn node_newlines(node_opt: ?ref Node) -> u64 {
    match (node_opt) {
        none { return 0; }
        some(node) { return node.newline_count; }
    }
}

fn make_node(piece: Piece, left: ?ref Node, right: ?ref Node) -> ref Node {
    return new Node {
        piece: piece,
        left: left,
        right: right,
        byte_len: node_bytes(left) + piece.length + node_bytes(right),
        newline_count: node_newlines(left) + piece.newlines + node_newlines(right),
        height: 1 + max_u64(node_height(left), node_height(right)),
    };
}

fn piece_source(text: ref Text, source: Source) -> []u8 {
    if (source is Source.original) { return text.original; }
    return text.added;
}

fn count_newlines(src: []u8, start: u64, length: u64) -> u64 {
    if (start > len(src) || length > len(src) - start) { trap; }
    var count: u64 = 0;
    for (var i = start; i < start + length; i += 1) {
        if (src[i] == '\n') { count += 1; }
    }
    return count;
}

fn make_piece(text: ref Text, source: Source, start: u64, length: u64) -> Piece {
    var src = piece_source(text, source);
    return Piece {
        source: source,
        start: start,
        length: length,
        newlines: count_newlines(src, start, length),
    };
}

fn build_balanced(pieces: []Piece, start: u64, end: u64) -> ?ref Node {
    if (start >= end) { return none; }
    var mid = start + (end - start) / 2;
    var left = build_balanced(pieces, start, mid);
    var right = build_balanced(pieces, mid + 1, end);
    return some(make_node(pieces[mid], left, right));
}

fn tree_for_range(text: ref Text, source: Source, start: u64, length: u64) -> ?ref Node {
    if (length == 0) { return none; }
    var pieces: []Piece = [];
    var pos = start;
    var remaining = length;
    while (remaining > 0) {
        var take = remaining;
        if (take > CHUNK_BYTES) { take = CHUNK_BYTES; }
        push(pieces, make_piece(text, source, pos, take));
        pos += take;
        remaining -= take;
    }
    return build_balanced(pieces, 0, len(pieces));
}

fn join(left: ?ref Node, piece: Piece, right: ?ref Node) -> ref Node {
    var lh = node_height(left);
    var rh = node_height(right);
    if (lh > rh + 1) {
        match (left) {
            none { trap; }
            some(root) {
                var joined = join(root.right, piece, right);
                return make_node(root.piece, root.left, some(joined));
            }
        }
    }
    if (rh > lh + 1) {
        match (right) {
            none { trap; }
            some(root) {
                var joined = join(left, piece, root.left);
                return make_node(root.piece, some(joined), root.right);
            }
        }
    }
    return make_node(piece, left, right);
}

fn pop_first(root: ref Node) -> PopFirst {
    match (root.left) {
        none {
            return PopFirst { piece: root.piece, rest: root.right };
        }
        some(left) {
            var first = pop_first(left);
            var rest = join(first.rest, root.piece, root.right);
            return PopFirst { piece: first.piece, rest: some(rest) };
        }
    }
}

fn concat(left: ?ref Node, right: ?ref Node) -> ?ref Node {
    match (left) {
        none { return right; }
        some(_) { }
    }
    match (right) {
        none { return left; }
        some(root) {
            var first = pop_first(root);
            return some(join(left, first.piece, first.rest));
        }
    }
}

fn split_node(text: ref Text, root_opt: ?ref Node, offset: u64) -> Split {
    match (root_opt) {
        none {
            if (offset != 0) { trap; }
            return Split { left: none, right: none };
        }
        some(root) {
            if (offset > root.byte_len) { trap; }
            var left_len = node_bytes(root.left);
            var piece_end = left_len + root.piece.length;

            if (offset < left_len) {
                var part = split_node(text, root.left, offset);
                var right = join(part.right, root.piece, root.right);
                return Split { left: part.left, right: some(right) };
            }
            if (offset > piece_end) {
                var part = split_node(text, root.right, offset - piece_end);
                var left = join(root.left, root.piece, part.left);
                return Split { left: some(left), right: part.right };
            }
            if (offset == left_len) {
                var right = join(none, root.piece, root.right);
                return Split { left: root.left, right: some(right) };
            }
            if (offset == piece_end) {
                var left = join(root.left, root.piece, none);
                return Split { left: some(left), right: root.right };
            }

            var in_piece = offset - left_len;
            var left_piece = make_piece(text, root.piece.source, root.piece.start, in_piece);
            var right_piece = make_piece(
                text,
                root.piece.source,
                root.piece.start + in_piece,
                root.piece.length - in_piece
            );
            var left_tree = join(root.left, left_piece, none);
            var right_tree = join(none, right_piece, root.right);
            return Split { left: some(left_tree), right: some(right_tree) };
        }
    }
}

fn append_piece_bytes(text: ref Text, piece: Piece, start: u64, end: u64, out: []u8) {
    if (start > end || end > piece.length) { trap; }
    var src = piece_source(text, piece.source);
    for (var i = piece.start + start; i < piece.start + end; i += 1) {
        push(out, src[i]);
    }
}

fn collect_range(text: ref Text, root_opt: ?ref Node, start: u64, end: u64, out: []u8) {
    if (start >= end) { return; }
    match (root_opt) {
        none { trap; }
        some(root) {
            if (end > root.byte_len) { trap; }
            var left_len = node_bytes(root.left);
            var piece_end = left_len + root.piece.length;

            if (start < left_len) {
                var left_end = end;
                if (left_end > left_len) { left_end = left_len; }
                collect_range(text, root.left, start, left_end, out);
            }

            if (end > left_len && start < piece_end) {
                var piece_start: u64 = 0;
                if (start > left_len) { piece_start = start - left_len; }
                var piece_stop = root.piece.length;
                if (end < piece_end) { piece_stop = end - left_len; }
                append_piece_bytes(text, root.piece, piece_start, piece_stop, out);
            }

            if (end > piece_end) {
                var right_start: u64 = 0;
                if (start > piece_end) { right_start = start - piece_end; }
                collect_range(text, root.right, right_start, end - piece_end, out);
            }
        }
    }
}

pub fn from_bytes(data: []u8) -> ref Text {
    var text = new Text {
        original: bytes.clone(data),
        added: [],
        root: none,
    };
    text.root = tree_for_range(text, Source.original, 0, len(text.original));
    return text;
}

pub fn byte_len(text: ref Text) -> u64 {
    return node_bytes(text.root);
}

pub fn newline_count(text: ref Text) -> u64 {
    return node_newlines(text.root);
}

pub fn slice(text: ref Text, start: u64, end: u64) -> []u8 {
    if (start > end || end > byte_len(text)) { trap; }
    var out: []u8 = [];
    if (start < end) { collect_range(text, text.root, start, end, out); }
    return out;
}

pub fn to_bytes(text: ref Text) -> []u8 {
    return slice(text, 0, byte_len(text));
}

pub fn byte_at(text: ref Text, offset: u64) -> u8 {
    if (offset >= byte_len(text)) { trap; }
    var root_opt = text.root;
    var pos = offset;
    while (true) {
        match (root_opt) {
            none { trap; }
            some(root) {
                var left_len = node_bytes(root.left);
                if (pos < left_len) {
                    root_opt = root.left;
                } else if (pos < left_len + root.piece.length) {
                    var src = piece_source(text, root.piece.source);
                    return src[root.piece.start + pos - left_len];
                } else {
                    pos -= left_len + root.piece.length;
                    root_opt = root.right;
                }
            }
        }
    }
    trap;
}

pub fn replace(text: ref Text, start: u64, end: u64, replacement: []u8) {
    if (start > end || end > byte_len(text)) { trap; }

    var first = split_node(text, text.root, start);
    var second = split_node(text, first.right, end - start);
    var inserted: ?ref Node = none;

    if (len(replacement) > 0) {
        var added_start = len(text.added);
        bytes.append(text.added, replacement);
        inserted = tree_for_range(text, Source.added, added_start, len(replacement));
    }

    text.root = concat(concat(first.left, inserted), second.right);
}

pub fn snapshot(text: ref Text) -> ref Snapshot {
    return new Snapshot { root: text.root };
}

pub fn restore(text: ref Text, state: ref Snapshot) {
    text.root = state.root;
}
