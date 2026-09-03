import bytes;
import tools.lace2.piece_tree as text;
import tools.lace2.selection as selection;

struct Node {
    id: u64,
    snapshot: ref text.Snapshot,
    selections: selection.Set,
    parent: ?ref Node,
    children: []ref Node,
    label: []u8,
}

pub struct History {
    root: ref Node,
    current: ref Node,
    next_id: u64,
}

pub fn start(doc: ref text.Text, selections: selection.Set) -> ref History {
    selection.validate(selections, text.byte_len(doc));
    var root = new Node {
        id: 0,
        snapshot: text.snapshot(doc),
        selections: selection.clone(selections),
        parent: none,
        children: [],
        label: "open",
    };
    return new History {
        root: root,
        current: root,
        next_id: 1,
    };
}

pub fn commit(
    history: ref History,
    doc: ref text.Text,
    selections: selection.Set,
    label: []u8
) -> u64 {
    selection.validate(selections, text.byte_len(doc));
    var child = new Node {
        id: history.next_id,
        snapshot: text.snapshot(doc),
        selections: selection.clone(selections),
        parent: some(history.current),
        children: [],
        label: bytes.clone(label),
    };
    history.next_id += 1;
    push(history.current.children, child);
    history.current = child;
    return child.id;
}

pub fn can_undo(history: ref History) -> bool {
    return history.current.parent is some(_);
}

pub fn undo(
    history: ref History,
    doc: ref text.Text
) -> ?selection.Set {
    match (history.current.parent) {
        none { return none; }
        some(parent) {
            text.restore(doc, parent.snapshot);
            history.current = parent;
            return some(selection.clone(parent.selections));
        }
    }
}

pub fn child_count(history: ref History) -> u64 {
    return len(history.current.children);
}

pub fn redo(
    history: ref History,
    doc: ref text.Text,
    child_index: u64
) -> ?selection.Set {
    if (child_index >= len(history.current.children)) { return none; }
    var child = history.current.children[child_index];
    text.restore(doc, child.snapshot);
    history.current = child;
    return some(selection.clone(child.selections));
}

pub fn current_id(history: ref History) -> u64 {
    return history.current.id;
}

pub fn current_label(history: ref History) -> []u8 {
    return bytes.clone(history.current.label);
}
