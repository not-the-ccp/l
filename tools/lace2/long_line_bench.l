import tools.lace2.editor_model as model;
import tools.lace2.render as render;

fn main() -> i64 {
    var data: []u8 = [];
    for (var i: u64 = 0; i < 50000; i += 1) { push(data, 'a'); }
    push(data, '\n');
    var editor = model.create(data);
    var total: u64 = 0;
    for (var i: u64 = 0; i < 4; i += 1) {
        var frame = render.draw(editor, "", "", 0, 1, 0, 6, 80);
        total += len(frame.bytes);
    }
    if (total == 0) { trap; }
    return 0;
}
