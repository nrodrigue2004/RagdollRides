# Static check: every controllers.X.y call and every M.y on a required module names something the
# target module defines (functions, fields, table keys, exported types). Run: python3 tests/callcheck.py .
import re, os, sys, glob
root = sys.argv[1]
files = glob.glob(root + '/src/**/*.luau', recursive=True)
mods = {}  # module basename -> (path, exports set, table name)
def exports_of(path):
    s = open(path).read()
    m = re.findall(r'^return\s+([A-Za-z_]\w*)\s*$', s, re.M)
    if not m: return None, set(), s
    t = m[-1]
    ex = set(re.findall(r'^(?:function\s+)?' + re.escape(t) + r'[.:]([A-Za-z_]\w*)', s, re.M))
    # table constructor keys: local T = { key = ..., }
    mt = re.search(r'^local\s+' + re.escape(t) + r'(?:\s*:\s*[^=]+)?\s*=\s*\{(.*?)^\}', s, re.M | re.S)
    if mt:
        ex |= set(re.findall(r'^\s+([A-Za-z_]\w*)\s*=', mt.group(1), re.M))
    ex |= set(re.findall(r'^export\s+type\s+(\w+)', s, re.M))
    return t, ex, s
for f in files:
    base = os.path.basename(f).replace('.client.luau','').replace('.server.luau','').replace('.luau','')
    t, ex, s = exports_of(f)
    if t: mods.setdefault(base, []).append((f, ex))
# controllers map
init = open(root + '/src/client/init.client.luau').read()
ctrl = dict(re.findall(r'\{\s*"(\w+)",\s*"(\w+)"', init))
problems = []
for f in files:
    s = open(f).read()
    code = re.sub(r'--\[\[.*?\]\]', '', s, flags=re.S)
    code = re.sub(r'--[^\n]*', '', code)
    code = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', code)
    for name, member in re.findall(r'controllers\.(\w+)\.(\w+)', code):
        mod = ctrl.get(name)
        if mod is None:
            problems.append((f, f'controllers.{name} is not a controller')); continue
        ex = set().union(*[e for _, e in mods.get(mod, [])]) if mods.get(mod) else set()
        if member not in ex:
            problems.append((f, f'controllers.{name}.{member} not defined in {mod}'))
    # local X = require(...Y)
    for local, target in re.findall(r'^local\s+(\w+)\s*=\s*require\(([^)\n]*)\)', code, re.M):
        last = re.findall(r'(\w+)\s*\)?\s*$', target.replace(':WaitForChild("', '.').replace('")', ''))
        tname = re.findall(r'\.(\w+)\s*$', target) or re.findall(r'"(\w+)"', target) or re.findall(r'(\w+)\s*$', target)
        if not tname: continue
        tn = tname[-1]
        if tn not in mods or tn == 'Config': continue
        ex = set().union(*[e for _, e in mods[tn]])
        for member in set(re.findall(r'(?<![\w.:])' + re.escape(local) + r'\.(\w+)', code)):
            if member not in ex:
                problems.append((f, f'{local}.{member} not in {tn}'))
for f, p in sorted(set(problems)):
    print(f.replace(root + '/', ''), '|', p)
print(len(set(problems)), 'problems')
