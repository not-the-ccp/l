import bytes;
import tools.lace2.piece_tree as text;
import tools.lace2.selection as selection;

pub struct EditSpec {
    pub start: u64,
    pub end: u64,
    pub inserted: []u8,
}

pub struct AppliedEdit {
    pub start: u64,
    pub removed: []u8,
    pub inserted: []u8,
}

pub struct Transaction {
    pub edits: []AppliedEdit,
}

fn validate_specs(doc: ref text.Text, specs: []EditSpec) {
    var last_end: u64 = 0;
    var first = true;
    for (spec in specs) {
        if (spec.start > spec.end || spec.end > text.byte_len(doc)) { trap; }
        if (!first && spec.start < last_end) { trap; }
        first = false;
        last_end = spec.end;
    }
}

pub fn apply(doc: ref text.Text, specs: []EditSpec) -> Transaction {
    validate_specs(doc, specs);

    var applied: []AppliedEdit = [];
    for (spec in specs) {
        push(applied, AppliedEdit {
            start: spec.start,
            removed: text.slice(doc, spec.start, spec.end),
            inserted: bytes.clone(spec.inserted),
        });
    }

    var i = len(specs);
    while (i > 0) {
        i -= 1;
        var spec = specs[i];
        text.replace(doc, spec.start, spec.end, spec.inserted);
    }

    return Transaction { edits: applied };
}

fn shifted(value: u64, removed: u64, inserted: u64) -> u64 {
    if (inserted >= removed) { return value + (inserted - removed); }
    return value - (removed - inserted);
}

pub fn map_position(tx: Transaction, original: u64, bias: selection.Bias) -> u64 {
    var mapped = original;
    for (edit in tx.edits) {
        var removed_len = len(edit.removed);
        var inserted_len = len(edit.inserted);
        var edit_end = edit.start + removed_len;

        if (original < edit.start) { break; }

        if (original > edit_end || (original == edit_end && removed_len > 0)) {
            mapped = shifted(mapped, removed_len, inserted_len);
            continue;
        }

        var mapped_start = mapped - (original - edit.start);
        if (bias is selection.Bias.after) { return mapped_start + inserted_len; }
        return mapped_start;
    }
    return mapped;
}

fn map_point(tx: Transaction, point: selection.Point) -> selection.Point {
    return selection.Point {
        offset: map_position(tx, point.offset, point.bias),
        bias: point.bias,
    };
}

pub fn map_selections(tx: Transaction, set: selection.Set) -> selection.Set {
    var out = selection.clone(set);
    for (var i: u64 = 0; i < len(out.ranges); i += 1) {
        var value = out.ranges[i];
        out.ranges[i] = selection.Range {
            anchor: map_point(tx, value.anchor),
            head: map_point(tx, value.head),
        };
    }
    return selection.merged(out);
}

pub fn inverse_specs(tx: Transaction) -> []EditSpec {
    var out: []EditSpec = [];
    var shift: u64 = 0;
    var shrink: u64 = 0;

    for (edit in tx.edits) {
        var start = edit.start;
        if (shift >= shrink) { start += shift - shrink; }
        else { start -= shrink - shift; }

        push(out, EditSpec {
            start: start,
            end: start + len(edit.inserted),
            inserted: bytes.clone(edit.removed),
        });

        shift += len(edit.inserted);
        shrink += len(edit.removed);
    }
    return out;
}
