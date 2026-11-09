import re, sys, glob, json
def lua_strings(src, i):
    """parse "a" .. "b" starting at i (after whitespace). return (value, end) or None"""
    parts=[]
    n=len(src)
    while True:
        while i<n and src[i] in ' \t\r\n': i+=1
        if i<n and src[i] in '"\'':
            q=src[i]; i+=1; buf=''
            while i<n and src[i]!=q:
                if src[i]=='\\':
                    c=src[i+1]
                    buf+={'n':'\n','t':'\t','\\':'\\','"':'"',"'":"'"}.get(c,c); i+=2
                else:
                    buf+=src[i]; i+=1
            i+=1; parts.append(buf)
        else:
            return None
        j=i
        while j<n and src[j] in ' \t\r\n': j+=1
        if src.startswith('..',j):
            i=j+2; continue
        return ''.join(parts), j
keys=set()
for f in glob.glob('addons/DMGAssist/Core/*.lua')+glob.glob('addons/DMGAssist/*.lua'):
    if f.endswith('Locales.lua'): continue
    src=open(f,encoding='utf-8').read()
    for m in re.finditer(r'\bL\[', src):
        r=lua_strings(src,m.end())
        if r and src[r[1]]==']': keys.add(r[0])
src=open('addons/DMGAssist_Watchdog/UI.lua',encoding='utf-8').read()
for m in re.finditer(r'\b(?:T|Label)\(', src):
    r=lua_strings(src,m.end())
    if r: keys.add(r[0])
rt=[l.rstrip('\n').replace('\\n','\n') for l in open(sys.argv[1],encoding='utf-8')]
keys.update(rt)
keys={k for k in keys if re.search('[A-Za-z]',k)}
json.dump(sorted(keys), open(sys.argv[2],'w'), ensure_ascii=False, indent=0)
print(len(keys), sum(len(k) for k in keys))
