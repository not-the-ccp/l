from pathlib import Path

p = Path('tools/lace2/kernel_test.l')
s = p.read_text()

anchor = '''fn test_piece_tree_random_edits() {
'''
insert = '''fn flat_next_newline(value: const []u8, start: u64) -> ?u64 {
    var i = start;
    while (i < len(value)) {
        if (value[i] == '\\n') { return some(i); }
        i += 1;
    }
    return none;
}

fn flat_previous_newline(value: const []u8, before: u64) -> ?u64 {
    var i = before;
    while (i > 0) {
        i -= 1;
        if (value[i] == '\\n') { return some(i); }
    }
    return none;
}

fn expect_optional_offset(actual: ?u64, expected: ?u64) {
    match (actual) {
        none { if (!(expected is none)) { trap; } }
        some(got) {
            match (expected) {
                none { trap; }
                some(want) { expect(got == want); }
            }
        }
    }
}

fn check_newline_index(doc: ref text.Text, flat: const []u8, state: ref u64) {
    // Probe arbitrary positions rather than only edit boundaries. This catches
    // relative-offset mistakes in both left/right subtree traversal and pieces
    // produced by splits/merges.
    for (var probe: u64 = 0; probe < 24; probe += 1) {
        var pos = rng_next(state) % (len(flat) + 1);
        expect_optional_offset(text.next_newline(doc, pos), flat_next_newline(flat, pos));
        expect_optional_offset(text.previous_newline(doc, pos), flat_previous_newline(flat, pos));
    }
}

fn test_piece_tree_random_edits() {
'''
if s.count(anchor) != 1:
    raise SystemExit('random edit test anchor changed')
s = s.replace(anchor, insert, 1)

old = '''        if (step % 31 == 0) {
            expect_bytes(text.to_bytes(doc), flat);
            expect(text.byte_len(doc) == len(flat));
            text.validate(doc);
        }
'''
new = '''        if (step % 31 == 0) {
            expect_bytes(text.to_bytes(doc), flat);
            expect(text.byte_len(doc) == len(flat));
            text.validate(doc);
            check_newline_index(doc, flat, state);
        }
'''
if s.count(old) != 1:
    raise SystemExit('random edit checkpoint changed')
s = s.replace(old, new, 1)

old = '''    expect_bytes(text.to_bytes(doc), flat);
    text.validate(doc);
}

fn test_transaction_and_bias() {
'''
new = '''    expect_bytes(text.to_bytes(doc), flat);
    text.validate(doc);
    check_newline_index(doc, flat, state);
}

fn test_transaction_and_bias() {
'''
if s.count(old) != 1:
    raise SystemExit('random edit final checkpoint changed')
s = s.replace(old, new, 1)

p.write_text(s)
