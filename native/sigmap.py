# Find the native helper's addresses in a new game build from the known build (docs/NATIVE_DLL.md).
# usage: python -I sigmap.py OLD.exe NEW.exe
# Code addresses: the function's first bytes with every RIP-relative / rel32 operand masked must match
# exactly once in the new .text. Data addresses (globals, vtables): found through instructions that
# reference them in the old code, matched the same way, and read back from the new instruction.
# Prints each old -> new address and the masked signature (hex, ?? = wildcard) for dnnative.c.
import re, sys, struct
import pefile, capstone

BASE = 0x140000000
CODE = {
    'gate': 0x141215780, 'ffiLoadSite': 0x14126caea, 'lockVB': 0x140e09e40, 'unlockVB': 0x140e09f60,
    'pushcclosure': 0x141211e40, 'setfield': 0x141212530, 'createtable': 0x141211260,
    'pushstring': 0x1412120c0, 'pushfstring': 0x141211f10, 'touserdata': 0x141212b20,
    'tolstring': 0x1412129e0, 'pushboolean': 0x141211e00, 'error': 0x1412131e0,
    'holderThunk': 0x1406c3eb0,
}
DATA = {'VT_PMESH': 0x141dacf98, 'VT_VB': 0x1421abb48, 'gfxCtx': 0x142a352a0, 'geLua': 0x142c274f8}

md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True


class Img:
    def __init__(self, path):
        self.pe = pefile.PE(path, fast_load=True)
        self.data = self.pe.__data__
        t = next(s for s in self.pe.sections if s.Name.rstrip(b'\0') == b'.text')
        self.tva, self.toff, self.tlen = BASE + t.VirtualAddress, t.PointerToRawData, t.SizeOfRawData
        self.text = bytes(self.data[self.toff:self.toff + self.tlen])

    def off(self, va):
        return self.pe.get_offset_from_rva(va - BASE)

    def read(self, va, n):
        o = self.off(va)
        return bytes(self.data[o:o + n])


def masked(img, va, n):
    """(bytes, mask) for >= n bytes of whole instructions at va; rel32/disp32 operands masked."""
    code = img.read(va, n + 16)
    out, mask, insns = bytearray(), bytearray(), []
    for ins in md.disasm(code, va):
        b = bytes(ins.bytes)
        m = bytearray(b'\xff' * len(b))
        rel = ins.op_str and ('rip' in ins.op_str)
        branch = ins.group(capstone.CS_GRP_JUMP) or ins.group(capstone.CS_GRP_CALL)
        if rel or (branch and len(b) >= 5 and ins.op_str.startswith('0x')):
            # displacement / branch target: x86 puts disp32 at disp_offset, rel32 at imm_offset
            d = ins.disp_offset if rel else ins.imm_offset
            sz = 4
            if d: m[d:d + sz] = b'\0' * sz
        out += b; mask += m; insns.append(ins)
        if len(out) >= n: break
    return bytes(out), bytes(mask), insns


def regex(b, m):
    return re.compile(b''.join(re.escape(bytes([x])) if k else b'.' for x, k in zip(b, m)), re.S)


def sig_text(b, m):
    return ' '.join('%02x' % x if k else '??' for x, k in zip(b, m))


def find_code(old, new, va, lengths=(24, 32, 48, 64, 96)):
    for n in lengths:
        b, m, _ = masked(old, va, n)
        hits = [x.start() for x in regex(b, m).finditer(new.text)]
        if len(hits) == 1:
            return new.tva + hits[0], b, m
        if not hits:
            return None, b, m
    return 'ambiguous', b, m


def refs_to(img, target, limit=40):
    """VAs of instructions in .text whose RIP-relative operand resolves to target."""
    import numpy as np
    found = []
    t = img.text
    a = np.frombuffer(t, np.uint8).astype(np.int64)
    n = len(t) - 4
    d = a[:n] | (a[1:n + 1] << 8) | (a[2:n + 2] << 16) | (a[3:n + 3] << 24)
    d = np.where(d >= 1 << 31, d - (1 << 32), d)
    pos = np.arange(n, dtype=np.int64) + img.tva + 4 + d
    for tail in (0, 1, 4):  # trailing imm8 / imm32 after the disp
        for i in np.nonzero(pos + tail == target)[0]:
            i = int(i)
            # decode from a few bytes back to confirm an instruction holds this disp
            for back in range(1, 5):
                s = i - back
                for ins in md.disasm(t[s:s + 16], img.tva + s, 1):
                    if ins.disp_offset == back and 'rip' in ins.op_str and ins.address + ins.size + int(d[i]) == target:
                        found.append(ins.address)
            if len(found) >= limit: return found
    return found


def unique_in(img, b, m):
    return len([1 for _ in regex(b, m).finditer(img.text)]) == 1


def emit_c(old, new):
    """C initialisers for dnnative.c: {name, sig, refAt, dispAt, insnEnd} (refAt -1 = code address).
    Every signature is checked unique in both builds."""
    rows = []
    for name, va in CODE.items():
        if name == 'holderThunk': continue
        for n in (24, 32, 48, 64, 96):
            b, m, _ = masked(old, va, n)
            if unique_in(old, b, m) and unique_in(new, b, m): break
        else:
            raise SystemExit('no unique signature for ' + name)
        rows.append((name, sig_text(b, m), -1, 0, 0))
    for name, va in DATA.items():
        best = None
        for r in refs_to(old, va):
            for back in range(0, 25):
                ins = list(md.disasm(old.read(r - back, back + 16), r - back))
                hit = [x for x in ins if x.address == r]
                if not hit: continue
                h = hit[0]
                for n in (32, 48, 64):
                    b, m, _ = masked(old, r - back, max(n, back + h.size))
                    if unique_in(old, b, m) and unique_in(new, b, m):
                        best = (name, sig_text(b, m), back, back + h.disp_offset, back + h.size)
                        break
                if best: break
            if best: break
        if not best: raise SystemExit('no unique reference signature for ' + name)
        rows.append(best)
    print('// generated by native/sigmap.py from build 0x%08x, checked unique in 0x%08x' % (
        old.pe.FILE_HEADER.TimeDateStamp, new.pe.FILE_HEADER.TimeDateStamp))
    for r in rows:
        print('    {"%s", "%s", %d, %d, %d},' % r)


def main():
    old, new = Img(sys.argv[1]), Img(sys.argv[2])
    if '--c' in sys.argv: return emit_c(old, new)
    res = {}
    for name, va in CODE.items():
        nva, b, m = find_code(old, new, va)
        res[name] = nva
        print('%-14s %#x -> %s   sig %s' % (name, va, nva if isinstance(nva, str) or nva is None else hex(nva), sig_text(b, m)))
    for name, va in DATA.items():
        refs = refs_to(old, va)
        votes = {}
        for r in refs:
            # signature starting a few instructions before the reference, ending after it
            start = r
            for back in range(24, 0, -1):
                ins = list(md.disasm(old.read(r - back, back + 16), r - back))
                if ins and any(x.address == r for x in ins):
                    start = r - back
                    break
            nva, b, m = find_code(old, new, start, (32, 48, 64))
            if not isinstance(nva, int): continue
            # same instruction in the new code: walk to the reference offset
            delta = r - start
            for ins in md.disasm(new.read(nva + delta, 16), nva + delta, 1):
                if 'rip' in ins.op_str:
                    d = struct.unpack_from('<i', bytes(ins.bytes), ins.disp_offset)[0]
                    tgt = ins.address + ins.size + d
                    votes[tgt] = votes.get(tgt, 0) + 1
        best = sorted(votes.items(), key=lambda x: -x[1])
        res[name] = best[0][0] if best else None
        print('%-14s %#x -> %s   refs %d votes %s' % (name, va, hex(best[0][0]) if best else None, len(refs),
                                                    ', '.join('%#x:%d' % kv for kv in best[:3])))


if __name__ == '__main__':
    main()
