#!/usr/bin/env python3
"""
fix_txm_patcher.py — In-place patch for vphone-cli's scripts/patchers/txm.py

Replaces the fragile PACIBSP-based function-boundary scan in
patch_trustcache_bypass() with a direct ±0x4000 window search around the
unique 'mov w19, #0x2446' marker constant.

Root cause: In CloudOS 26.1 (23B85) there is an inline PACIBSP instruction only
0x24 bytes before the marker, so the backward scan picks it up as the function
start, placing the actual trustcache 'bl' pattern *before* the detected window
and causing fw_patch.py to report "binary search pattern not found in function".

This script is idempotent — it checks for the old logic before patching and
does nothing if already up-to-date.

Usage (called by phase4_patch.sh _apply_upstream_patches):
    python3 fix_txm_patcher.py <path/to/txm.py>
"""

import sys
import os
import re

OLD_MARKER = "hint #27"       # unique string only present in the old logic
NEW_MARKER = "win_start"      # unique string only present in the new logic

OLD_BLOCK = '''\
    def patch_trustcache_bypass(self):
        # Step 1: Find the unique function marker (mov w19, #0x2446)
        locs = _find_asm_pattern(self.raw, "mov w19, #0x2446")
        if len(locs) != 1:
            self._log(f"  [-] TXM: expected 1 'mov w19, #0x2446', "
                       f"found {len(locs)}")
            return
        marker_off = locs[0]

        # Step 2: Find the containing function (scan back for PACIBSP)
        pacibsp = _asm("hint #27")
        func_start = None
        for scan in range(marker_off & ~3, max(0, marker_off - 0x200), -4):
            if self.raw[scan:scan + 4] == pacibsp:
                func_start = scan
                break
        if func_start is None:
            self._log("  [-] TXM: function start not found")
            return

        # Step 3: Within the function, find mov w2, #0x14; bl; cbz w0; tbnz w0, #0x1f
        func_end = min(func_start + 0x2000, self.size)
        insns = list(_cs.disasm(self.raw[func_start:func_end], func_start))

        for i, ins in enumerate(insns):
            if not (ins.mnemonic == 'mov' and ins.op_str == 'w2, #0x14'):
                continue
            if i + 3 >= len(insns):
                continue
            bl_ins = insns[i + 1]
            cbz_ins = insns[i + 2]
            tbnz_ins = insns[i + 3]
            if (bl_ins.mnemonic == 'bl'
                    and cbz_ins.mnemonic == 'cbz' and 'w0' in cbz_ins.op_str
                    and tbnz_ins.mnemonic in ('tbnz', 'tbz')
                    and '#0x1f' in tbnz_ins.op_str):
                self.emit(bl_ins.address, MOV_X0_0,
                          "trustcache bypass: bl → mov x0, #0")
                return

        self._log("  [-] TXM: binary search pattern not found in function")'''

NEW_BLOCK = '''\
    def patch_trustcache_bypass(self):
        # Step 1: Find the unique function marker (mov w19, #0x2446)
        locs = _find_asm_pattern(self.raw, "mov w19, #0x2446")
        if len(locs) != 1:
            self._log(f"  [-] TXM: expected 1 'mov w19, #0x2446', "
                       f"found {len(locs)}")
            return
        marker_off = locs[0]

        # Step 2: Search a generous window around the marker for the trustcache
        # binary-search pattern: mov w2, #0x14; bl; cbz w0; tbnz/tbz w0, #0x1f
        #
        # We deliberately avoid PACIBSP-based function-boundary detection because
        # inline PACIBSP / data coincidences (e.g. at +0x24 from the marker in
        # CloudOS 26.1) would produce a wrong function-start that excludes the
        # pattern.  A ±0x4000 window around the unique marker is sufficient and
        # more robust across versions.
        win_start = max(0, marker_off - 0x4000) & ~3
        win_end   = min(marker_off + 0x4000, self.size)
        insns = list(_cs.disasm(self.raw[win_start:win_end], win_start))

        for i, ins in enumerate(insns):
            if not (ins.mnemonic == 'mov' and ins.op_str == 'w2, #0x14'):
                continue
            if i + 3 >= len(insns):
                continue
            bl_ins   = insns[i + 1]
            cbz_ins  = insns[i + 2]
            tbnz_ins = insns[i + 3]
            if (bl_ins.mnemonic == 'bl'
                    and cbz_ins.mnemonic == 'cbz' and 'w0' in cbz_ins.op_str
                    and tbnz_ins.mnemonic in ('tbnz', 'tbz')
                    and '#0x1f' in tbnz_ins.op_str):
                self.emit(bl_ins.address, MOV_X0_0,
                          "trustcache bypass: bl → mov x0, #0")
                return

        self._log("  [-] TXM: binary search pattern not found in function")'''


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path/to/txm.py>", file=sys.stderr)
        sys.exit(1)

    txm_path = sys.argv[1]
    if not os.path.isfile(txm_path):
        print(f"ERROR: {txm_path} not found", file=sys.stderr)
        sys.exit(1)

    text = open(txm_path, 'r').read()

    if NEW_MARKER in text:
        print(f"[+] txm.py already up-to-date (window-based search present), skipping.")
        sys.exit(0)

    if OLD_MARKER not in text:
        print(f"[!] txm.py: neither old nor new logic detected — unexpected version, skipping.")
        sys.exit(0)

    if OLD_BLOCK not in text:
        print(f"[!] txm.py: old PACIBSP block not found verbatim — may already be patched or changed upstream.")
        print(f"    Skipping to avoid corrupting the file.")
        sys.exit(0)

    patched = text.replace(OLD_BLOCK, NEW_BLOCK, 1)
    open(txm_path, 'w').write(patched)
    print(f"[+] txm.py patched: replaced PACIBSP scan-back with ±0x4000 window search.")


if __name__ == "__main__":
    main()
