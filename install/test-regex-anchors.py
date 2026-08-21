#!/usr/bin/env python3
"""No regex here may end at `$`, spell a digit `\\d`, or hide its pattern from this check.

In Python `$` matches at the end of the string AND immediately before a trailing
newline, so `re.compile(r'^[a-z]{1,4}$').match('abcd\\n')` matches with span (0, 4).
Every `^...$` validator therefore accepts one character its character class forbids,
and every `{1,N}` cap can be exceeded by exactly one. Twelve patterns in this repo had
that shape before anyone looked; four of them were safe only because their call sites
happened to use `fullmatch` or `.strip()`. `\\Z` puts the guarantee at the pattern, where a
new caller cannot forget it.

    python3 install/test-regex-anchors.py

Two design choices worth knowing before editing this file:

* **It walks the AST, not lines, and finds files by content, not by name.** One of the
  twelve spanned two lines, so its `$` sat on a continuation line no line grep sees; another
  lived in `bin/airlock-config`, which is Python with no `.py` on the end. Both misses are
  why this check exists in this shape.
* **A pattern it cannot read statically is a failure, not a note.** `re.compile(name)`,
  an f-string, a concatenation or a `functools.partial(re.compile, ...)` would otherwise
  be a silent way past the check, which is the same defect one level up. Today every
  pattern in the repo is a literal, so this costs nothing and starts green.

A pattern that genuinely needs `$` (a `re.MULTILINE` parser, say — there are none today),
or one that must be built at runtime, opts out with `# noqa: regex-anchor` on the line the
call starts on.
"""
import ast
import io
import os
import subprocess
import sys
import tokenize

OPT_OUT = 'noqa: regex-anchor'
OPT_OUT_DIGIT = 'noqa: regex-digit'
MISSING = object()   # a call into re with no readable pattern argument at all


def ends_with_end_anchor(pattern):
    """True when the pattern's last character is an unescaped `$`.

    `r'costs \\$'` ends with the character '$' but means a literal dollar, and flagging it
    would make this check reject correct code. Backslash parity decides: an even number of
    backslashes before the final '$' leaves it as the anchor, an odd number escapes it.
    """
    dollar = '$' if isinstance(pattern, str) else b'$'
    slash = '\\' if isinstance(pattern, str) else b'\\'
    if not pattern.endswith(dollar):
        return False
    backslashes = 0
    index = len(pattern) - 2
    while index >= 0 and pattern[index:index + 1] == slash:
        backslashes += 1
        index -= 1
    return backslashes % 2 == 0


def uses_unicode_digit_class(pattern):
    """True when a str pattern contains `\\d`, which is not the same thing as `[0-9]`.

    In a str pattern `\\d` is every Unicode decimal digit — Arabic-Indic, Devanagari,
    fullwidth — so `^image(\\d{3,})-\\d{8}-\\d{6}\\.jpg\\Z` accepts names the auto-save
    code that owns that shape can never produce. Same defect as `$`: the pattern claims
    a rule narrower than the one it enforces.

    Only str. In a bytes pattern `\\d` already means `[0-9]`, so flagging it would be
    noise. Only `\\d`: `\\w` appears nowhere, and the two `\\s` uses strip decoration off
    terminal output, where matching more whitespace is the intent rather than a hole.
    Backslash parity decides, as above — `r'a\\\\d'` is a literal backslash then a 'd'.
    """
    if not isinstance(pattern, str):
        return False
    index = pattern.find('\\d')
    while index != -1:
        backslashes = 0
        back = index - 1
        while back >= 0 and pattern[back] == '\\':
            backslashes += 1
            back -= 1
        if backslashes % 2 == 0:
            return True
        index = pattern.find('\\d', index + 1)
    return False


# Every one of these takes the pattern as argument 0.
RE_FUNCS = frozenset({'compile', 'match', 'fullmatch', 'search', 'split',
                      'findall', 'finditer', 'sub', 'subn'})


def python_files(root):
    """Every tracked Python file, including the ones with no `.py` on the end.

    `bin/airlock-config` is Python and carries a validator; a `*.py` glob does not see it,
    and neither does the `py_compile` step in CI. A check that only looks where the name
    is convenient is how the twelfth pattern stayed hidden after eleven were found.
    """
    listed = subprocess.run(['git', '-C', root, 'ls-files', '-z'],
                            capture_output=True, text=True, check=True).stdout
    found = []
    for rel in listed.split('\0'):
        if not rel:
            continue
        if rel.endswith('.py'):
            found.append(rel)
            continue
        path = os.path.join(root, rel)
        try:
            with open(path, 'rb') as fh:
                first = fh.readline(200)
        except OSError:
            continue
        if is_python_file(rel, first):
            found.append(rel)
    return found


def is_python_file(rel, first_line):
    """Whether a tracked file is Python, by name or by shebang.

    Split out from the walk so the self-test can exercise it: 'the check only looked at
    *.py' is how the twelfth pattern stayed hidden, and a rule that important should not
    be the one part of this file nothing verifies.
    """
    if rel.endswith('.py'):
        return True
    # Vendored JS bundles can mention python in their first bytes; a shebang is the signal.
    return first_line.startswith(b'#!') and b'python' in first_line


def _re_bindings(tree):
    """Names in this module that reach `re`: ({module aliases}, {bare function names}).

    `import re as rx` and `from re import compile` are both ways to call the same
    functions under a different name, and a check that only knows `re.` misses them.
    """
    # Not seeded with 're': a module that never imports it may bind the name to something
    # else, and calling that `re.compile` is not this check's business.
    modules, bare = set(), set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name == 're':
                    modules.add(alias.asname or 're')
        elif isinstance(node, ast.ImportFrom) and node.module == 're':
            for alias in node.names:
                if alias.name in RE_FUNCS:
                    bare.add(alias.asname or alias.name)
    return modules, bare


def _pattern_arg(node, modules, bare):
    """The pattern argument of a call into `re`, or None if this is not such a call.

    `re.match(p, s)` takes the pattern first; `PATTERN.match(s)` takes the subject.
    Confusing the two would flag any code that matches against a string ending in '$',
    so the receiver has to be a name that actually reaches the `re` module.
    """
    func = node.func
    into_re = ((isinstance(func, ast.Attribute) and func.attr in RE_FUNCS
                and isinstance(func.value, ast.Name) and func.value.id in modules)
               or (isinstance(func, ast.Name) and func.id in bare))
    if not into_re:
        return None
    if node.args:
        return node.args[0]
    for keyword in node.keywords:
        if keyword.arg == 'pattern':          # re.compile(pattern=...) is the same call
            return keyword.value
    return MISSING


def _escaping_reference(node, modules, bare):
    """True for `re.compile` used as a value rather than called — partial(), a callback.

    The pattern then arrives from somewhere this check cannot see.
    """
    if isinstance(node, ast.Attribute):
        return (node.attr in RE_FUNCS and isinstance(node.value, ast.Name)
                and node.value.id in modules)
    return isinstance(node, ast.Name) and node.id in bare


def findings(path):
    """Yield (line, message) for everything wrong in one file."""
    with open(path, encoding='utf-8') as fh:
        return findings_in_source(fh.read(), path)


def _opt_out_lines(source, marker=OPT_OUT):
    """Line numbers carrying the given opt-out in a real comment.

    A substring search would also honour it inside a string literal, which is a way to
    turn the check off without leaving a comment anyone reviews.
    """
    marked = set()
    try:
        for token in tokenize.generate_tokens(io.StringIO(source).readline):
            if token.type == tokenize.COMMENT and marker in token.string:
                marked.add(token.start[0])
    except (tokenize.TokenError, IndentationError):
        pass          # unparseable source is reported by ast.parse below, not silently
    return marked


def findings_in_source(source, label='<source>'):
    """Yield (line, message). Split out from findings() so the self-test needs no files."""
    tree = ast.parse(source, filename=label)
    modules, bare = _re_bindings(tree)
    exempt = _opt_out_lines(source)
    exempt_digit = _opt_out_lines(source, OPT_OUT_DIGIT)

    called = set()

    def opted_out(lineno):
        return lineno in exempt

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        pattern = _pattern_arg(node, modules, bare)
        if pattern is None:
            continue
        called.add(id(node.func))
        if opted_out(node.lineno):
            continue
        if isinstance(pattern, ast.Constant) and isinstance(pattern.value, (str, bytes)):
            if ends_with_end_anchor(pattern.value):
                yield node.lineno, f'pattern ends at $ -> {pattern.value!r}'
            if (uses_unicode_digit_class(pattern.value)
                    and node.lineno not in exempt_digit):
                yield node.lineno, (r'\d matches every Unicode digit; write [0-9] '
                                    f'-> {pattern.value!r}')
            continue
        if pattern is MISSING:
            yield node.lineno, 'call into re with no readable pattern argument'
            continue
        yield node.lineno, ('pattern is not a literal, so it cannot be checked here '
                            f'({type(pattern).__name__})')

    # `partial(re.compile, ...)`, `map(re.compile, ...)`, a stored reference: the call
    # happens where this check cannot follow it.
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Attribute, ast.Name)) or id(node) in called:
            continue
        if _escaping_reference(node, modules, bare) and not opted_out(node.lineno):
            name = node.attr if isinstance(node, ast.Attribute) else node.id
            yield node.lineno, f'`{name}` is used as a value; its pattern is unchecked'


# Each case is (source, expected). `expected` is a fragment the message must contain, or
# None for "must be accepted". Matching on the message rather than on "was anything
# reported" is deliberate: dropping bytes support moved `b'^x$'` into the *not a literal*
# branch, so a flagged/not-flagged assertion still passed while the check had actually
# stopped reading bytes patterns. The reason has to be part of the assertion.
#
# A check nobody checks is the defect this file exists to prevent, so these run on every
# invocation rather than in a separate test somebody forgets to call. Every flagged case
# here was a real way past an earlier draft.
ENDS_AT = 'ends at $'
UNI_DIGIT = 'every Unicode digit'
NOT_LITERAL = 'not a literal'
ESCAPES = 'used as a value'
SELF_TEST = [
    ("import re\nre.compile(r'^x$')\n", ENDS_AT),
    ("import re as rx\nrx.compile(r'^x$')\n", ENDS_AT),                 # module alias
    ("from re import compile\ncompile(r'^x$')\n", ENDS_AT),             # bare import
    ("import re\nre.compile(b'^x$')\n", ENDS_AT),                       # bytes pattern
    ("import re\nre.sub(r'^x$', '', s)\n", ENDS_AT),                    # not just compile()
    ("import re\nre.compile('^x' + '$')\n", NOT_LITERAL),               # concatenation
    ("import re\nre.compile(f'^{x}$')\n", NOT_LITERAL),                 # f-string
    ("import re\nP = '^x$'\nre.compile(P)\n", NOT_LITERAL),             # indirection
    ("import re, functools\nfunctools.partial(re.compile, r'^x$')\n", ESCAPES),
    ("import re\nre.compile(r'^x\\Z')\n", None),                        # the fixed form
    ("import re\nre.compile(r'^a\\d+\\Z')\n", UNI_DIGIT),                 # \d is not [0-9]
    ("import re\nre.compile(r'^a[0-9]+\\Z')\n", None),                  # the fixed form
    ("import re\nre.compile(rb'^a\\d+\\Z')\n", None),                    # bytes: \d is ASCII already
    ("import re\nre.compile(r'^a\\\\d\\Z')\n", None),                     # literal backslash then 'd'
    (f"import re\nre.compile(r'^a\\d\\Z')  # {OPT_OUT_DIGIT}\n", None),   # opt-out honoured
    (f"import re\nre.compile(r'^x$')  # {OPT_OUT}\n", None),            # opt-out honoured
    # An escaped dollar is a literal '$', not an anchor. Flagging it would make this check
    # reject correct code, which is how a check gets switched off for everyone.
    ("import re\nre.compile(r'costs 5\\$')\n", None),
    ("import re\nre.compile(r'^a\\\\$')\n", ENDS_AT),                     # escaped backslash, live anchor
    # The marker has to be a comment. Inside a string it is just text.
    (f"import re\nre.compile(r'^x$')  # real comment {OPT_OUT}\n", None),
    (f"import re\nX = re.compile(r'^x$') or '{OPT_OUT}'\n", ENDS_AT),
    ("import re\nre.compile(pattern=r'^x$')\n", ENDS_AT),               # keyword argument
    # A module that never imports re may bind the name to something else entirely.
    ("re = object()\nre.compile(r'^x$')\n", None),
    # The distinction the check turns on: a compiled pattern's .match() takes the SUBJECT,
    # so a subject ending in '$' must not be read as a pattern.
    ("import re\nP = re.compile(r'^x\\Z')\nP.match('costs 5$')\n", None),
]


FILE_SHAPE_TEST = [
    ('apps/x/backend/thing.py', b'', True),
    ('bin/airlock-config', b'#!/usr/bin/env python3\n', True),          # no extension
    ('bin/tool', b'#!/usr/bin/python\n', True),
    ('install/lib.sh', b'#!/usr/bin/env bash\n', False),
    ('web/bundle.js', b'// mentions python but has no shebang\n', False),
    ('docs/notes.md', b'python\n', False),
]


def self_test():
    """Return a list of failures; empty when the checker still catches what it should."""
    problems = []
    for rel, head, expected in FILE_SHAPE_TEST:
        if is_python_file(rel, head) != expected:
            problems.append(f'file shape: {rel!r} should be '
                            f'{"scanned" if expected else "skipped"}')
    for index, (source, expected) in enumerate(SELF_TEST):
        messages = [m for _, m in findings_in_source(source, f'<self-test {index}>')]
        if expected is None:
            if messages:
                problems.append(f'self-test {index}: expected no finding, got {messages}\n'
                                f'{source.rstrip()}')
        elif not any(expected in m for m in messages):
            problems.append(f'self-test {index}: expected a finding containing '
                            f'{expected!r}, got {messages or "nothing"}\n{source.rstrip()}')
    return problems


def main():
    broken = self_test()
    if broken:
        print('FAIL this check no longer catches what it is meant to catch:')
        for item in broken:
            print(f'  {item}')
        return 1

    root = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                          capture_output=True, text=True, check=True).stdout.strip()
    files = python_files(root)

    bad = []
    for rel in files:
        for line, message in findings(os.path.join(root, rel)):
            bad.append(f'{rel}:{line}: {message}')

    for item in bad:
        print(f'FAIL {item}')
    if bad:
        print(f'\n{len(bad)} problem(s). Two rules, one shape — a pattern that claims a '
              f'narrower\nrule than it enforces. In Python `$` also matches immediately '
              f'before a trailing\nnewline, so a `^...$` validator accepts one character '
              f'its character class forbids\nand lets a {{1,N}} cap be exceeded by one; '
              f'use `\\Z`. And `\\d` in a str pattern is\nevery Unicode decimal digit, '
              f'not `[0-9]`, so a rule written for ASCII digits also\naccepts '
              f'Arabic-Indic and fullwidth ones; write the class out.\n\nIf a pattern '
              f'genuinely needs `$` (multiline parsing) or must be built at runtime,\n'
              f'add `# {OPT_OUT}` to the line the call starts on; for a deliberate '
              f'Unicode-digit\nmatch use `# {OPT_OUT_DIGIT}`. Either way, say why in the '
              f'comment.')
        return 1
    print(f'ok  {len(files)} tracked Python files, every regex pattern is a literal, '
          f'none ends at `$`, and none matches non-ASCII digits')
    return 0


if __name__ == '__main__':
    sys.exit(main())
