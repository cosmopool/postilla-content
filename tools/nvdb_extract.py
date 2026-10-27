import sys,re
from pdfminer.high_level import extract_pages
from pdfminer.layout import LTTextContainer, LTChar, LTTextLine
BAND={'Bold':1,'Regular':2,'RegularItalic':3}
# stream of (char, style, small)
stream=[]
for pno,page in enumerate(extract_pages(sys.argv[1])):
    for el in page:
        if not isinstance(el, LTTextContainer): continue
        for line in el:
            if not isinstance(line, LTTextLine): continue
            chars=[c for c in line if isinstance(c,LTChar)]
            if not chars: continue
            sizes=[c.size for c in chars]
            if max(sizes)>10.5 or (max(sizes)<8 and min(sizes)>6): continue  # headers, letters, page numbers
            txt=''.join(c.get_text() for c in chars).strip()
            if re.fullmatch(r'[A-Z]( [A-Z])*',txt): continue
            if pno==0 and not any(9<c.size<10.5 for c in chars): continue
            items=[]
            for c in line:
                if isinstance(c,LTChar):
                    items.append((c.get_text(), c.fontname.split('+')[1].split('-')[1], c.size<6))
                else:
                    items.append((' ','Regular',False))
            # trim trailing spaces
            while items and items[-1][0].isspace(): items.pop()
            if items and items[-1][0]=='-' and not items[-1][2]:
                items.pop(); stream.extend(items)  # hyphen join
            else:
                stream.extend(items); stream.append((' ','Regular',False))
# tokens: split on spaces and commas, keep style of first char, collect superscripts
toks=[]; cur=''; style=None; sup=''
def flush():
    global cur,style,sup
    if cur: toks.append((cur,style,sup))
    cur='';style=None;sup=''
for ch,st,small in stream:
    if small:
        if ch.isdigit(): sup+=ch
        continue
    if ch in ' ,':
        flush();
        if ch==',': toks.append((',',None,''))
        continue
    if not cur: style=st
    cur+=ch
flush()
POS=re.compile(r'.*\.$|^e$|^inv\.?$|^[a-z]+\.[a-z.]+$|^sigla$')
entries=[]; i=0; inpos=False
while i<len(toks):
    t,st,sup=toks[i]
    if t==',' : i+=1; inpos=False; continue
    if POS.match(t) or inpos:  # pos continues previous entry
        entries[-1][3].append(t); i+=1; inpos=True; continue
    # headword: may be multiword until a pos token
    words=[t]; j=i+1
    while j<len(toks) and toks[j][0]!=',' and not POS.match(toks[j][0]):
        words.append(toks[j][0]); j+=1
    entries.append([' '.join(words), BAND.get(st,0), sup, []]); i=j; inpos=True
from collections import Counter
print(Counter(e[1] for e in entries), len(entries), file=sys.stderr)
with open(sys.argv[2],'w') as f:
    for w,b,s,p in entries:
        f.write('%s\t%s\t%s\t%s\n'%(w,s,' '.join(p),b))
