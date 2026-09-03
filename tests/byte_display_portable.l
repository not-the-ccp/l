import byte_display as display;
import bytes;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn require_kind(src: const []u8, expected: display.UnitKind) {
    var unit = display.next_unit(src, 0);
    require(unit.start == 0);
    require(unit.end > 0);
    require(unit.kind == expected);
}

fn main() -> i64 {
    require_kind("a", display.UnitKind.text);
    require_kind("\t", display.UnitKind.tab);
    require_kind("\n", display.UnitKind.line_break);
    require_kind([0x1b], display.UnitKind.control);
    require_kind([0xff], display.UnitKind.invalid_byte);
    require_kind([0xe2, 0x80, 0xae], display.UnitKind.unicode_control); // U+202E

    // Printable Unicode passes through unchanged.
    var euro: []u8 = [0xe2, 0x82, 0xac];
    var euro_unit = display.next_unit(euro, 0);
    require(euro_unit.kind == display.UnitKind.text);
    require(bytes.equal(display.representation(euro, euro_unit), euro));

    // Protocol-relevant/control data is rendered as visible text, never copied
    // through as an escape/control sequence.
    require(bytes.equal(display.render_safe([0x1b, '[', '3', '1', 'm']), "^[[31m"));
    require(bytes.equal(display.render_safe([0x00, 0x7f]), "^@^?"));
    require(bytes.equal(display.render_safe([0xff, 0xc0]), "<FF><C0>"));
    require(bytes.equal(display.render_safe([0xe2, 0x80, 0xae]), "<U+202E>"));

    // Unit offsets stay tied to source bytes even when a safe representation is
    // wider, which lets editors map cursor/selection state back to raw input.
    var mixed: []u8 = ['a', 0xff, 'b'];
    var middle = display.next_unit(mixed, 1);
    require(middle.start == 1 && middle.end == 2);
    require(bytes.equal(display.representation(mixed, middle), "<FF>"));

    match (display.parse_byte_hex("00")) { some(v) { require(v == 0); } none { trap; } }
    match (display.parse_byte_hex("fF")) { some(v) { require(v == 255); } none { trap; } }
    match (display.parse_byte_hex("GG")) { none {} some(_) { trap; } }
    match (display.parse_byte_hex("F")) { none {} some(_) { trap; } }
    return 0;
}
