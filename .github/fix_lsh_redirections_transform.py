#!/usr/bin/env python3
from pathlib import Path

p = Path('.github/apply_lsh_redirections.py')
s = p.read_text()
start = s.index("    s = once(s,\n'''    var pipe_partial")
end = s.index("    return s\n\n\ndef executor_file", start)
replacement = '''    insert = r\'''    var redirect_partial = expect_incomplete("printf x >", IncompleteKind.redirection);\n    require(len(redirect_partial.pipeline.commands) == 1);\n    require_bytes(redirect_partial.pipeline.commands[0].words[0].value, "printf");\n\n    var quoted_operator = expect_ready("printf 'a>b' \\\"c<d\\\"");\n    require(len(quoted_operator.commands[0].redirections) == 0);\n    require_bytes(quoted_operator.commands[0].words[1].value, "a>b");\n    require_bytes(quoted_operator.commands[0].words[2].value, "c<d");\n\n\'''\n    s = once(s, '    expect_error("| cat");\\n', insert + '    expect_error("| cat");\\n', 'redirection parser tests')\n'''
p.write_text(s[:start] + replacement + s[end:])
