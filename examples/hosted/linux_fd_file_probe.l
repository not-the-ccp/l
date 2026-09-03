import bytes;
import linux.fd as fd;
import sys;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn opened(result: fd.OpenResult) -> fd.Fd {
    match (fd.open_fd(result)) {
        some(value) { return value; }
        none { trap; }
    }
}

fn require_error(result: fd.OpenResult) {
    match (fd.open_fd(result)) {
        none {}
        some(_) { trap; }
    }
    match (fd.open_error(result)) {
        some(number) { require(number > 0); }
        none { trap; }
    }
}

fn main() -> i64 {
    var args = sys.args();
    require(len(args) == 1);
    var path = args[0];

    var first = opened(fd.create_truncate(path));
    require(fd.write(first, "abc") == 3);
    fd.close(first);

    var append = opened(fd.create_append(path));
    require(fd.write(append, "de") == 2);
    fd.close(append);

    var input = opened(fd.open_read(path));
    match (fd.read(input, 32)) {
        some(data) { require(bytes.equal(data, "abcde")); }
        none { trap; }
    }
    match (fd.read(input, 32)) {
        none {}
        some(_) { trap; }
    }
    fd.close(input);

    require_error(fd.open_read("/definitely/not/a/real/l-file-open-probe"));
    return 0;
}
