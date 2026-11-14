"""A type as text, made comparable: what ned's engine says and what the compiler says (nimsuggest, or its NIF) are
written a little differently — module qualifiers, `int literal(3)`, `owned`, pragmas of a proc type, a tuple's
fields. normT gives both the same form; compare.py and nifgrade.py use it."""
import re

def split_top(s, sep=','):
    # s split at `sep` outside () [] {}
    out = []; depth = 0; cur = ''
    for ch in s:
        if ch in '([{': depth += 1
        elif ch in ')]}': depth -= 1
        if ch == sep and depth == 0: out.append(cur); cur = ''
        else: cur += ch
    out.append(cur)
    return out

def normT(t):
    t = t.strip().lstrip(':').strip()
    if t == 'Error Type': return ''
    if t == 'iterator': t = 'proc'                             # (a parameter typed `iterator`: nimsuggest says proc)
    t = re.sub(r'\bvarargs\[([^,\[\]]+),[^\[\]]*\]', r'varargs[\1]', t)   # varargs[string, `$`]: its converter aside
    t = t.replace('%.', '')                                    # (Nim 2.4's nimsuggest: Option[%.T] for Option[T])
    t = re.sub(r'\bint literal\(\d+\)', 'int', t)
    t = re.sub(r'\b(float|string|bool|char) literal\([^)]*\)', r'\1', t)
    t = re.sub(r'(\b[A-Z]\w*): \w+$', r'\1', t)                # T: SomeFloat, var T: distinct
    t = t.replace(' or ', '|')
    t = re.sub(r'^owned[ (]', '', t).rstrip(')') if t.startswith('owned') else t
    if 'proc' in t or 'iterator' in t:
        t = re.sub(r'\s*\{\.[^{}]*\}', '', t)                 # (pragmas, also of a proc type inside another: closure, gcsafe …)
    if t.startswith('proc') or t.startswith('iterator'):
        t = t.replace('proc(', 'proc (')
        # proc (a, b: T) → proc (a: T, b: T)   (a comma inside brackets — (A, B) — is not between parameters)
        m = re.match(r'^(proc|iterator) \((.*)\)(.*)$', t)
        if m:
            out = []; names = []
            for part in split_top(m.group(2)):
                part = part.strip()
                if ':' in part:
                    n, ty = part.split(':', 1)
                    for x in names + [n]: out.append(x.strip() + ':' + ty.strip())
                    names = []
                elif part: names.append(part)
            t = '%s (%s)%s' % (m.group(1), ','.join(out + names), m.group(3))
    t = re.sub(r'\b[A-Za-z_][A-Za-z0-9_]*\.', '', t)          # module qualifiers: system.int → int
    t = re.sub(r'^(lent|var|sink) ', '', t)                     # lent string is a string to read
    t = re.sub(r'\bfloat64\b', 'float', t)
    t = t.replace(' ', '')
    # array[0..1, T] → array[2,T]
    t = re.sub(r'array\[0\.\.(\d+),', lambda m: 'array[%d,' % (int(m.group(1)) + 1), t)
    # tuple[a,b:T] → tuple[a:T,b:T]
    def tup(m):
        out = []; names = []
        for part in m.group(1).split(','):
            if ':' in part:
                n, ty = part.split(':', 1)
                for x in names + [n]: out.append(x + ':' + ty)
                names = []
            else: names.append(part)
        return 'tuple[' + ','.join(out + names) + ']'
    t = re.sub(r'tuple\[([^\[\]]*)\]', tup, t)
    for a, b in (('cint', 'int32'), ('cuint', 'uint32'), ('clong', 'int'), ('culong', 'uint'), ('csize_t', 'uint'),
                 ('cchar', 'char'), ('cfloat', 'float32'), ('cdouble', 'float'), ('clonglong', 'int64'), ('cshort', 'int16')):
        t = re.sub(r'\b%s\b' % a, b, t)
    t = re.sub(r'^owned\((.*)\)$', r'\1', t)
    return t.lower().replace('_', '')
