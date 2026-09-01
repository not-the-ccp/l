import slang_index;
import slang_project;

fn require(ok: bool) {
    if (!ok) {
        trap;
    }
}

fn module(name: []u8, source: []u8) -> slang_project.Module {
    return slang_project.Module { name: name, index: slang_index.index(source) };
}

fn count(errors: []slang_project.Error, kind: slang_project.ErrorKind) -> u64 {
    var total: u64 = 0;
    for (error in errors) {
        if (error.kind == kind) {
            total += 1;
        }
    }
    return total;
}

fn main() -> i64 {
    var hosts: [][]u8 = ["stdio", "fs", "sys", "proc", "term"];

    var good: []slang_project.Module = [
        module("a", "pub fn answer() -> i64 { return 42; } fn hidden() { }"),
        module("b", "import a as dep; import stdio; pub fn run() { }"),
    ];
    require(len(slang_project.validate(good, hosts)) == 0);

    var answer = slang_project.member(good, "a", "answer");
    require(answer.status is slang_project.MemberStatus.found);
    var hidden = slang_project.member(good, "a", "hidden");
    require(hidden.status is slang_project.MemberStatus.private_member);
    var absent = slang_project.member(good, "a", "missing");
    require(absent.status is slang_project.MemberStatus.missing_member);
    var absent_module = slang_project.member(good, "missing", "x");
    require(absent_module.status is slang_project.MemberStatus.missing_module);

    var duplicate_name: []slang_project.Module = [
        module("a", "pub fn x() { }"),
        module("b", "import a; fn a() { }"),
    ];
    var duplicate_errors = slang_project.validate(duplicate_name, hosts);
    require(count(duplicate_errors, slang_project.ErrorKind.duplicate_name) == 1);

    var reserved_name: []slang_project.Module = [module("reserved", "fn len() { }")];
    var reserved_errors = slang_project.validate(reserved_name, hosts);
    require(count(reserved_errors, slang_project.ErrorKind.reserved_name) == 1);

    var unresolved: []slang_project.Module = [module("entry", "import nowhere; fn main() { }")];
    var unresolved_errors = slang_project.validate(unresolved, hosts);
    require(count(unresolved_errors, slang_project.ErrorKind.unresolved_module) == 1);

    var cycle: []slang_project.Module = [
        module("left", "import right; fn a() { }"),
        module("right", "import left; fn b() { }"),
    ];
    var cycle_errors = slang_project.validate(cycle, hosts);
    require(count(cycle_errors, slang_project.ErrorKind.import_cycle) == 1);

    var duplicate_modules: []slang_project.Module = [
        module("same", "fn a() { }"),
        module("same", "fn b() { }"),
    ];
    var duplicate_module_errors = slang_project.validate(duplicate_modules, hosts);
    require(count(duplicate_module_errors, slang_project.ErrorKind.duplicate_module) == 1);

    return 0;
}
