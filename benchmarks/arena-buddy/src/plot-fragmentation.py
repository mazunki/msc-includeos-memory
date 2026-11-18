import re, sys

def xterm_to_rgb(n):
    n = int(n)
    if 16 <= n <= 231:
        i = n - 16
        r, g, b = i // 36, (i // 6) % 6, i % 6
        steps = [0, 95, 135, 175, 215, 255]
        return steps[r], steps[g], steps[b]
    elif 232 <= n <= 255:
        level = 8 + (n - 232) * 10
        return level, level, level
    elif n == 0:
        return 0, 0, 0
    raise ValueError(f"unhandled xterm color {n}")

USED_RGB = xterm_to_rgb(240)  # grey used by the tool's own used_color, even though
                               # the terminal prints '@' with no explicit color code

ESC = re.compile(r'\x1b\[([0-9;]*)m')

def parse_legend(lines):
    out = []
    pat = re.compile(r'\x1b\[48;5;(\d+)m  \x1b\[0m order (\d+) = (.+)')
    for line in lines:
        m = pat.search(line)
        if m:
            color, order, rest = m.groups()
            out.append((xterm_to_rgb(color), order, rest.strip()))
    return out

def parse_tile_rows(lines):
    rows = []
    addr_pat = re.compile(r'\x1b\[90m([^\x1b]+)\x1b\[0m')
    row_pat = re.compile(r'^\s{4}\x1b\[90m(0x[0-9a-f]+)\x1b\[0m\s+(.*?)\s+\x1b\[90m(0x[0-9a-f]+)\x1b\[0m\s*$')
    for line in lines:
        m = row_pat.match(line.rstrip('\n'))
        if not m:
            continue
        phys_addr, tiles_raw, off_addr = m.groups()
        # walk the tile section char by char, handling optional ANSI color wraps
        cells = []
        i = 0
        while i < len(tiles_raw):
            if tiles_raw[i] == '\x1b':
                em = ESC.match(tiles_raw, i)
                assert em, f"bad escape at {i} in {tiles_raw!r}"
                code = em.group(1)
                i = em.end()
                if code.startswith('48;5;'):
                    color_code = code.split(';')[2]
                    ch = tiles_raw[i]
                    i += 1
                    # consume the reset
                    rm = ESC.match(tiles_raw, i)
                    assert rm and rm.group(1) == '0'
                    i = rm.end()
                    cells.append((ch, xterm_to_rgb(color_code)))
                elif code == '0':
                    i += 0  # stray reset, ignore
                else:
                    raise ValueError(f"unexpected code {code}")
            else:
                ch = tiles_raw[i]
                i += 1
                cells.append((ch, USED_RGB if ch == '@' else None))
        rows.append((phys_addr, cells, off_addr))
    return rows

def emit_tikz(rows, cell=0.14):
    ncols = max(len(r[1]) for r in rows)
    nrows = len(rows)
    defs = []
    seen = set()
    out = []
    out.append(r"\begin{tikzpicture}[x=%gcm, y=%gcm]" % (cell, cell))
    out.append(r"  \path (0,0) rectangle (%d,%d);" % (ncols, nrows))
    for ri, (phys_addr, cells, off_addr) in enumerate(rows):
        y = nrows - 1 - ri
        for ci, (ch, rgb) in enumerate(cells):
            if rgb is None:
                continue
            r, g, b = rgb
            colname = f"c{r}_{g}_{b}"
            if colname not in seen:
                defs.append(r"  \definecolor{%s}{RGB}{%d,%d,%d}" % (colname, r, g, b))
                seen.add(colname)
            out.append(r"  \fill[%s] (%d,%d) rectangle (%d,%d);" % (colname, ci, y, ci+1, y+1))
    out.append(r"\end{tikzpicture}")
    return "\n".join(defs) + "\n" + "\n".join(out)

def emit_legend(entries):
    out = []
    out.append(r"\scriptsize")
    out.append(r"\setlength{\tabcolsep}{2pt}")
    out.append(r"\renewcommand{\arraystretch}{1.05}")
    out.append(r"\begin{tabular}{@{}l l@{}}")
    seen = set()
    for rgb, order, rest in entries:
        r, g, b = rgb
        colname = f"c{r}_{g}_{b}"
        if colname not in seen:
            out.append(r"\definecolor{%s}{RGB}{%d,%d,%d}" % (colname, r, g, b))
            seen.add(colname)
        # drop the "order " prefix and " = " for a compact single-line entry
        out.append(r"\colorbox{%s}{\phantom{Xg}} & \texttt{%s}: %s \\" % (colname, order, rest))
    out.append(r"\end{tabular}")
    return "\n".join(out)

if __name__ == "__main__":
    path = sys.argv[1]
    with open(path) as f:
        lines = f.readlines()
    legend = parse_legend(lines)
    rows = parse_tile_rows(lines)
    print("%% === LEGEND ===")
    print(emit_legend(legend))
    print("%% === TILE MAP ===")
    print(emit_tikz(rows))
