import bytes;
import byte_display as display;
import tools.lace2.history as history;
import tools.lace2.piece_tree as text;
import tools.lace2.selection as selection;
import tools.lace2.transaction as transaction;

fn expect(ok: bool) {
    if (!ok) { trap; }
}

fn expect_bytes(actual: []u8, expected: []u8) {
    if (!bytes.equal(actual, expected)) { trap; }
}

fn test_round_trip_bytes() {
    var raw: []u8 = [0x00, 0x01, 0x09, 0x0a, 0x1b, 0x7f, 0x80, 0xff];
    var doc = text.from_bytes(raw);
    expect(text.byte_len(doc) == len(raw));
    expect(text.newline_count(doc) == 1);
    expect_bytes(text.to_bytes(doc), raw);
    for (var i: u64 = 0; i < len(raw); i += 1) {
        expect(text.byte_at(doc, i) == raw[i]);
    }
    text.validate(doc);

    expect_bytes(display.render_safe(raw), "^@^A<TAB><LF>^[^?<80><FF>");
}

fn test_strict_utf8_units() {
    var euro: []u8 = [0xe2, 0x82, 0xac];
    var unit = display.next_unit(euro, 0);
    expect(unit.kind is display.UnitKind.text);
    expect(unit.start == 0 && unit.end == 3);
    expect(unit.codepoint == 0x20ac);
    expect_bytes(display.representation(euro, unit), euro);

    var invalid: []u8 = [0xc0, 0x80, 0xed, 0xa0, 0x80, 0xf4, 0x90, 0x80, 0x80];
    var pos: u64 = 0;
    while (pos < len(invalid)) {
        var bad = display.next_unit(invalid, pos);
        expect(bad.kind is display.UnitKind.invalid_byte);
        expect(bad.end == pos + 1);
        pos = bad.end;
    }

    var bidi: []u8 = [0xe2, 0x80, 0xae];
    var bidi_unit = display.next_unit(bidi, 0);
    expect(bidi_unit.kind is display.UnitKind.unicode_control);
    expect_bytes(display.representation(bidi, bidi_unit), "<U+202E>");

    var parsed = display.parse_byte_hex("fF");
    match (parsed) {
        none { trap; }
        some(value) { expect(value == 0xff); }
    }
    expect(display.parse_byte_hex("GG") is none);
}

fn test_piece_tree_basic() {
    var doc = text.from_bytes("abcdef\n012345\nxyz");
    text.replace(doc, 2, 5, "Q");
    expect_bytes(text.to_bytes(doc), "abQf\n012345\nxyz");

    text.replace(doc, 2, 2, [0xff, 0x00]);
    expect_bytes(text.to_bytes(doc), ['a', 'b', 0xff, 0x00, 'Q', 'f', '\n', '0', '1', '2', '3', '4', '5', '\n', 'x', 'y', 'z']);

    text.replace(doc, 2, 4, []);
    expect_bytes(text.to_bytes(doc), "abQf\n012345\nxyz");
    text.validate(doc);
}

fn test_piece_tree_sequential_appends() {
    var doc = text.from_bytes([]);
    for (var i: u64 = 0; i < 10000; i += 1) {
        var value: []u8 = [(i & 0xff) as u8];
        text.replace(doc, text.byte_len(doc), text.byte_len(doc), value);
        if (i % 97 == 0) { text.validate(doc); }
    }
    text.validate(doc);
    var stats = text.stats(doc);
    expect(stats.byte_len == 10000);
    expect(stats.pieces == 10000);
    expect(stats.height < 32);
}

fn rng_next(state: ref u64) -> u64 {
    *state = (*state * 6364136223846793005) + 1442695040888963407;
    return *state;
}

fn random_bytes(state: ref u64, max_len: u64) -> []u8 {
    var n = rng_next(state) % (max_len + 1);
    var out: []u8 = [];
    for (var i: u64 = 0; i < n; i += 1) {
        push(out, (rng_next(state) & 0xff) as u8);
    }
    return out;
}

fn flat_next_newline(value: const []u8, start: u64) -> ?u64 {
    var i = start;
    while (i < len(value)) {
        if (value[i] == '\n') { return some(i); }
        i += 1;
    }
    return none;
}

fn flat_previous_newline(value: const []u8, before: u64) -> ?u64 {
    var i = before;
    while (i > 0) {
        i -= 1;
        if (value[i] == '\n') { return some(i); }
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
    var initial: []u8 = [];
    for (var i: u64 = 0; i < 20000; i += 1) {
        var value = ((i * 17) & 0xff) as u8;
        if (i % 79 == 0) { value = '\n'; }
        push(initial, value);
    }

    var flat = bytes.clone(initial);
    var doc = text.from_bytes(initial);
    var state: ref u64 = new 0x123456789abcdef0;

    for (var step: u64 = 0; step < 5000; step += 1) {
        var start: u64 = 0;
        if (len(flat) > 0) { start = rng_next(state) % (len(flat) + 1); }
        var max_remove = len(flat) - start;
        if (max_remove > 19) { max_remove = 19; }
        var remove_len: u64 = 0;
        if (max_remove > 0) { remove_len = rng_next(state) % (max_remove + 1); }
        var replacement = random_bytes(state, 23);

        splice(flat, start, start + remove_len, replacement);
        text.replace(doc, start, start + remove_len, replacement);

        if (step % 31 == 0) {
            expect_bytes(text.to_bytes(doc), flat);
            expect(text.byte_len(doc) == len(flat));
            text.validate(doc);
            check_newline_index(doc, flat, state);
        }
    }
    expect_bytes(text.to_bytes(doc), flat);
    text.validate(doc);
    check_newline_index(doc, flat, state);
}

fn test_transaction_and_bias() {
    var doc = text.from_bytes("abcdef");
    var specs: []transaction.EditSpec = [
        transaction.EditSpec { start: 1, end: 2, inserted: "XX" },
        transaction.EditSpec { start: 4, end: 4, inserted: [0xff] },
    ];
    var tx = transaction.apply(doc, specs);
    expect_bytes(text.to_bytes(doc), ['a', 'X', 'X', 'c', 'd', 0xff, 'e', 'f']);

    var inverse = transaction.inverse_specs(tx);
    var undo_tx = transaction.apply(doc, inverse);
    expect(len(undo_tx.edits) == 2);
    expect_bytes(text.to_bytes(doc), "abcdef");
    text.validate(doc);

    var insert_doc = text.from_bytes("abc");
    var insert_tx = transaction.apply(insert_doc, [
        transaction.EditSpec { start: 1, end: 1, inserted: "X" },
    ]);
    expect(transaction.map_position(insert_tx, 1, selection.Bias.before) == 1);
    expect(transaction.map_position(insert_tx, 1, selection.Bias.after) == 2);

    var selected = selection.Set {
        ranges: [selection.range(1, 2)],
        primary: 0,
    };
    var mapped = transaction.map_selections(insert_tx, selected);
    expect(selection.range_start(mapped.ranges[0]) == 2);
    expect(selection.range_end(mapped.ranges[0]) == 3);

    var end_insert_doc = text.from_bytes("abc");
    var end_insert_tx = transaction.apply(end_insert_doc, [
        transaction.EditSpec { start: 2, end: 2, inserted: "X" },
    ]);
    var end_mapped = transaction.map_selections(end_insert_tx, selected);
    expect(selection.range_start(end_mapped.ranges[0]) == 1);
    expect(selection.range_end(end_mapped.ranges[0]) == 2);
}

fn test_branching_history() {
    var doc = text.from_bytes("abc");
    var selections = selection.single(3);
    var h = history.start(doc, selections);

    var tx1 = transaction.apply(doc, [
        transaction.EditSpec { start: 3, end: 3, inserted: "1" },
    ]);
    selections = transaction.map_selections(tx1, selections);
    history.commit(h, doc, selections, "branch one");
    expect_bytes(text.to_bytes(doc), "abc1");

    var restored = history.undo(h, doc);
    match (restored) {
        none { trap; }
        some(value) { selections = value; }
    }
    expect_bytes(text.to_bytes(doc), "abc");

    var tx2 = transaction.apply(doc, [
        transaction.EditSpec { start: 3, end: 3, inserted: "2" },
    ]);
    selections = transaction.map_selections(tx2, selections);
    history.commit(h, doc, selections, "branch two");
    expect_bytes(text.to_bytes(doc), "abc2");

    restored = history.undo(h, doc);
    match (restored) {
        none { trap; }
        some(value) { selections = value; }
    }
    expect(history.child_count(h) == 2);

    var redo_first = history.redo(h, doc, 0);
    expect(redo_first is some(_));
    expect_bytes(text.to_bytes(doc), "abc1");

    restored = history.undo(h, doc);
    expect(restored is some(_));
    var redo_second = history.redo(h, doc, 1);
    expect(redo_second is some(_));
    expect_bytes(text.to_bytes(doc), "abc2");
    text.validate(doc);
}

fn main() {
    test_round_trip_bytes();
    test_strict_utf8_units();
    test_piece_tree_basic();
    test_piece_tree_sequential_appends();
    test_piece_tree_random_edits();
    test_transaction_and_bias();
    test_branching_history();
}
