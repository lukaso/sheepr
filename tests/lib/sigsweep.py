#!/usr/bin/env python3
"""The sweep of tests/dist/t_sigs.sh: every cleanup trap in the shell files under a dir catches the
one signal list (scripts/lib/sigs.sh), and holds further signals off while it cleans up.

    sigsweep.py DIR SIGS-LINE RENDERED-FILE

It reads each shell file under DIR (a .sh or .conf name, or a #! line naming sh) as the shell
does: words, quotes, $( ), comments and heredocs. A command is a `trap` only where a command
starts (never in a comment, a quoted string or a heredoc). Rules (each violation is printed as
`RULE path:line: what`):
  near     an EXIT trap with no trap beside it (its start within 5 lines of the EXIT trap) whose
           action is not empty and whose signals include $SIGS unquoted ("$SIGS" is one word, not
           the list; a comment is not a trap);
  ignore   an EXIT trap whose action does not start (after an optional `rc=$?`) with
           `trap '' $SIGS`, itself or as the first command of the function it calls: a second
           signal during the cleanup must not cut it short;
  listed   a file with an EXIT trap that does not get the list: it sources sigs.sh (a plain
           variable in the path expanded), or it carries
           SIGS-LINE as a command, or it is RENDERED-FILE (install.sh: the list is written into its
           trap lines at render, as tests/dist/t_install.sh checks);
  other    a SIGS= assignment that is not SIGS-LINE (a bare SIGS= too);
  literal  a trap on a literal signal of the list (but smoke.sh's own exit codes: a single HUP,
           INT or TERM trapped with `exit 129`, `exit 130` or `exit 143`).
The last line printed is `SITES n`: the number of EXIT traps read.
"""
import os
import re
import sys


def skip_sq(s, i):
    j = s.find("'", i)
    return len(s) if j < 0 else j + 1


def skip_bq(s, i):
    while i < len(s):
        if s[i] == '\\':
            i += 2
            continue
        if s[i] == '`':
            return i + 1
        i += 1
    return i


def skip_dq(s, i):
    while i < len(s):
        c = s[i]
        if c == '\\':
            i += 2
            continue
        if c == '"':
            return i + 1
        if c == '`':
            i = skip_bq(s, i + 1)
            continue
        if s.startswith('$(', i):
            i = skip_paren(s, i + 2)
            continue
        if s.startswith('${', i):
            i = skip_brace(s, i + 2)
            continue
        i += 1
    return i


def skip_paren(s, i):
    depth = 1
    while i < len(s):
        c = s[i]
        if c == '\\':
            i += 2
            continue
        if c == "'":
            i = skip_sq(s, i + 1)
            continue
        if c == '"':
            i = skip_dq(s, i + 1)
            continue
        if c == '`':
            i = skip_bq(s, i + 1)
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return i


def skip_brace(s, i):
    depth = 1
    while i < len(s):
        c = s[i]
        if c == '\\':
            i += 2
            continue
        if c == '"':
            i = skip_dq(s, i + 1)
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return i


BREAK = set(' \t\n;&|()<>')


def word_end(s, i):
    while i < len(s):
        c = s[i]
        if c in BREAK:
            break
        if c == '\\':
            i += 2
            continue
        if c == "'":
            i = skip_sq(s, i + 1)
            continue
        if c == '"':
            i = skip_dq(s, i + 1)
            continue
        if c == '`':
            i = skip_bq(s, i + 1)
            continue
        if s.startswith('$(', i):
            i = skip_paren(s, i + 2)
            continue
        if s.startswith('${', i):
            i = skip_brace(s, i + 2)
            continue
        i += 1
    return min(i, len(s))


def unquote(raw):
    out, i = [], 0
    while i < len(raw):
        c = raw[i]
        if c == "'":
            j = skip_sq(raw, i + 1)
            out.append(raw[i + 1:j - 1])
            i = j
        elif c == '"':
            j = skip_dq(raw, i + 1)
            inner = raw[i + 1:j - 1]
            out.append(re.sub(r'\\([$`"\\\n])', r'\1', inner))
            i = j
        elif c == '\\' and i + 1 < len(raw):
            out.append(raw[i + 1])
            i += 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)


class Word:
    def __init__(self, raw, line, end):
        self.raw, self.line, self.end = raw, line, end
        self.value = unquote(raw)


def commands(s, line=1):
    """The simple commands of s, in order: lists of Words (reserved words at the start dropped)."""
    cmds, cur, pending = [], [], []
    i, n = 0, len(s)

    def close():
        nonlocal cur
        while cur and cur[0].raw in ('if', 'then', 'else', 'elif', 'fi', 'do', 'done', 'while',
                                     'until', '!', '{', '}', 'time'):
            cur = cur[1:]
        if cur:
            cmds.append(cur)
        cur = []

    while i < n:
        c = s[i]
        if c == '\n':
            close()
            line += 1
            i += 1
            for delim, strip in pending:
                while i < n:
                    j = s.find('\n', i)
                    j = n if j < 0 else j
                    body = s[i:j]
                    i = j + 1
                    line += 1
                    if (body.lstrip('\t') if strip else body) == delim:
                        break
            pending = []
            continue
        if c in ' \t':
            i += 1
            continue
        if c == '\\' and i + 1 < n and s[i + 1] == '\n':
            i += 2
            line += 1
            continue
        if c == '#':
            j = s.find('\n', i)
            i = n if j < 0 else j
            continue
        if s.startswith('<<', i) and not s.startswith('<<<', i):
            j, strip = i + 2, False
            if j < n and s[j] == '-':
                strip, j = True, j + 1
            while j < n and s[j] in ' \t':
                j += 1
            k = word_end(s, j)
            pending.append((unquote(s[j:k]), strip))
            i = k
            continue
        if c in '<>':
            # a redirection: its fd number (the word just read) and its target are not arguments
            if cur and cur[-1].raw.isdigit() and cur[-1].end == i:
                cur.pop()
            while i < n and s[i] in '<>&|':
                i += 1
            while i < n and s[i] in ' \t':
                i += 1
            k = word_end(s, i)
            line += s[i:k].count('\n')
            i = k
            continue
        if c in ';&|()':
            close()
            i += 1
            continue
        k = word_end(s, i)
        raw = s[i:k]
        w = Word(raw, line, k)
        line += raw.count('\n')
        if raw in ('{', '}'):
            close()
        else:
            cur.append(w)
        i = k
    close()
    return cmds


def is_ignore(cmd):
    return (len(cmd) >= 3 and cmd[0].raw == 'trap' and cmd[1].raw in ("''", '""')
            and cmd[2].raw == '$SIGS')


def starts_ignore(action, funcs):
    cmds = commands(action)
    if cmds and len(cmds[0]) == 1 and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*=\$\?', cmds[0][0].raw):
        cmds = cmds[1:]
    if not cmds:
        return False
    c = cmds[0]
    if is_ignore(c):
        return True
    body = funcs.get(c[0].value)
    if body is None:
        return False
    fc = commands(body)
    return bool(fc) and is_ignore(fc[0])


def is_shell(path):
    if path.endswith(('.sh', '.conf')):
        return True
    try:
        with open(path, 'rb') as f:
            first = f.readline(200)
    except OSError:
        return False
    return first.startswith(b'#!') and re.search(rb'\bsh\b', first) is not None


def main():
    root, sigs_line, rendered = sys.argv[1], sys.argv[2], os.path.realpath(sys.argv[3])
    listnames = re.fullmatch(r'SIGS="([A-Z0-9 ]*)"', sigs_line)
    names = set(listnames.group(1).split()) if listnames else set()
    exempt = re.compile(r'exit 1(29|30|43)')
    sites = 0
    for d, _, fs in sorted(os.walk(root)):
        for f in sorted(fs):
            p = os.path.join(d, f)
            if not is_shell(p):
                continue
            with open(p, encoding='utf-8', errors='replace') as fh:
                s = fh.read()
            cmds = commands(s)
            funcs = {}
            for m in re.finditer(r'(?m)^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(\)[ \t]*\{', s):
                funcs[m.group(1)] = s[m.end():]
            traps = [c for c in cmds if c[0].raw == 'trap' and len(c) >= 2]
            exits = [c for c in traps if c[1].value != '-' and any(w.value in ('EXIT', '0') for w in c[2:])]
            sites += len(exits)
            for c in exits:
                a, z = c[0].line, c[-1].line
                near = [t for t in traps if t is not c and t[1].value not in ('', '-')
                        and any(w.raw == '$SIGS' for w in t[2:]) and a - 5 <= t[0].line <= z + 5]
                if not near:
                    print(f'near {p}:{a}: an EXIT trap with no trap on $SIGS (unquoted, an action) beside it')
                if not starts_ignore(c[1].value, funcs):
                    print(f"ignore {p}:{a}: an EXIT trap whose cleanup does not start with trap '' $SIGS")
            if exits:
                # a source command's argument, its plain variables expanded (NAME=word assignments
                # in this file, the word with no quote or expansion of its own)
                plain = {}
                for c in cmds:
                    for w in c:
                        m = re.fullmatch(r'([A-Za-z_][A-Za-z0-9_]*)=([^\s$`"\'\\]*)', w.raw)
                        if not m:
                            break
                        plain[m.group(1)] = m.group(2)
                expand = lambda v: re.sub(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?', lambda m: plain.get(m.group(1), m.group(0)), v)
                sources = any(c[0].raw == '.' and len(c) >= 2 and expand(c[1].value).endswith('sigs.sh') for c in cmds)
                verbatim = any(len(c) == 1 and c[0].raw == sigs_line for c in cmds)
                if not (sources or verbatim or os.path.realpath(p) == rendered):
                    print(f'listed {p}:{exits[0][0].line}: has an EXIT trap but does not get the list (sigs.sh, the render, or its verbatim line)')
            for c in cmds:
                for w in c:
                    if w.raw.startswith('SIGS=') and w.raw != sigs_line:
                        print(f'other {p}:{w.line}: another SIGS: {w.raw}')
                    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*=.*', w.raw, re.S):
                        break
            for t in traps:
                lit = [w.value for w in t[2:] if w.value in names]
                if not lit:
                    continue
                if len(t) == 3 and t[2].value in ('HUP', 'INT', 'TERM') and exempt.fullmatch(t[1].value):
                    continue
                print(f'literal {p}:{t[0].line}: a literal signal list: {" ".join(w.raw for w in t)}')
    print(f'SITES {sites}')


if __name__ == '__main__':
    main()
