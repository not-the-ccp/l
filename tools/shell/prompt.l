import bytes;
import strconv;

pub enum SegmentRole {
    cwd,
    status,
    marker,
}

pub struct Segment {
    pub role: SegmentRole,
    pub text: []u8,
}

pub struct Prompt {
    pub segments: []Segment,
}

fn display_cwd(cwd: ?[]u8, home: ?[]u8) -> []u8 {
    match (cwd) {
        none {
            return "?";
        }
        some(path) {
            match (home) {
                none {
                    return bytes.clone(path);
                }
                some(home_path) {
                    if (bytes.equal(path, home_path)) {
                        return "~";
                    }
                    if (len(home_path) != 0 && bytes.starts_with(path, home_path) && len(path) > len(home_path) && path[len(home_path)] == '/') {
                        var out: []u8 = ['~'];
                        bytes.append(out, bytes.slice(path, len(home_path), len(path)));
                        return out;
                    }
                    return bytes.clone(path);
                }
            }
        }
    }
}

// Build semantic prompt segments rather than terminal escape sequences. Themes
// can color/dim roles independently, while a no-style renderer can flatten the
// exact same model.
pub fn build(cwd: ?[]u8, home: ?[]u8, last_status: i64, continuation: bool) -> Prompt {
    var segments: []Segment = [];
    if (continuation) {
        push(segments, Segment { role: SegmentRole.marker, text: "…" });
        return Prompt { segments: segments };
    }

    push(segments, Segment {
        role: SegmentRole.cwd,
        text: display_cwd(cwd, home),
    });
    if (last_status != 0) {
        var status_text: []u8 = ['['];
        bytes.append(status_text, strconv.format_i64(last_status));
        push(status_text, ']');
        push(segments, Segment {
            role: SegmentRole.status,
            text: status_text,
        });
    }
    push(segments, Segment { role: SegmentRole.marker, text: "›" });
    return Prompt { segments: segments };
}

pub fn flatten(prompt: Prompt) -> []u8 {
    var out: []u8 = [];
    for (var i: u64 = 0; i < len(prompt.segments); i += 1) {
        if (i != 0) {
            push(out, ' ');
        }
        bytes.append(out, prompt.segments[i].text);
    }
    push(out, ' ');
    return out;
}
