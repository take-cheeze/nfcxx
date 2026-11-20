"""Hazard fixing and kernel ELF reading for the Linux NPU runner.

Copied from npu-render's tools/build_ptl_kernel.py (fix_hazards, nop_insertion_point and the
conflict pattern) and src/npu_render/ptl_carrier.py (require, read_kernel_text), so the runner
does not import that project."""
import re
import struct


def require(ok, message):
    if not ok:
        raise ValueError(message)




CONFLICT = re.compile(
    rb"ERROR: Instruction .*? is conflicting:.*?at line (\d+)\.?\s*$", re.S | re.M
)


BRANCH_DELAY_SLOTS = 6


def nop_insertion_point(lines, index):
    """Line index at which a NOP delays the bundle starting at `index`.

    The bundle's own continuation lines are skipped backwards. A branch is followed by
    BRANCH_DELAY_SLOTS bundles that execute whatever it decides; a NOP inside that window
    would move one of them out of it, so the NOP goes before the branch bundle instead
    (and before a branch whose window holds that branch, recursively).
    """
    at = index
    while at > 0 and lines[at].lstrip().startswith(b"||"):
        at -= 1

    def bundle_head(n):
        while n > 0 and lines[n].lstrip().startswith(b"||"):
            n -= 1
        return n

    def is_code(text):
        return bool(re.match(rb"[A-Z]{3}[0-9]?\.", text)) or text.startswith(b"NOP")

    def bundle_text(head):
        parts = [lines[head].split(b"//")[0].strip()]
        n = head + 1
        while n < len(lines) and lines[n].lstrip().startswith(b"||"):
            parts.append(lines[n].split(b"//")[0].strip()[2:].strip())
            n += 1
        return parts

    while True:
        # Walk back over the preceding bundles; stop after the delay-slot window.
        slots = 0
        n = at - 1
        moved = False
        while n >= 0 and slots < BRANCH_DELAY_SLOTS:
            text = lines[n].split(b"//")[0].strip()
            if not text or text.startswith(b"."):
                n -= 1
                continue
            if text.endswith(b":"):
                break  # a label: the window cannot cross a basic block boundary
            head = bundle_head(n)
            parts = bundle_text(head)
            if not any(is_code(part) for part in parts):
                n = head - 1
                continue
            if any(part.startswith(b"BRU.") for part in parts):
                at = head
                moved = True
                break
            for part in parts:
                m = re.match(rb"NOP\s*(\d*)$", part)
                slots += int(m.group(1) or 1) if m else 0
            if not any(part.startswith(b"NOP") for part in parts):
                slots += 1
            n = head - 1
        if not moved:
            # A predicate bundle (PEU) without its branch conditions the bundle that follows it:
            # a NOP between them would take the predicate, so the NOP goes before the PEU bundle.
            n = at - 1
            while n >= 0:
                text = lines[n].split(b"//")[0].strip()
                if not text or text.startswith(b"."):
                    n -= 1
                    continue
                if text.endswith(b":"):
                    break
                head = bundle_head(n)
                if any(part.startswith(b"PEU.") for part in bundle_text(head)):
                    at = head
                    moved = True
                break
        if not moved:
            return at


def fix_hazards(root, assembly, output, limit=400):
    """Delay bundles the assembler rejects for a write-port conflict by one NOP each.

    The compiler's VAU latency model and the assembler's disagree for 5000xx;
    delaying a consumer never changes the data flow. A NOP goes before the
    conflicting bundle, or before a preceding branch so delay slots stay intact.
    """
    inserted = []
    for _ in range(limit):
        code, messages, _object = transform(root, assembly, output, assemble=True, strict=False)
        if not code:
            break
        lines = assembly.split(b"\n")
        targets = set()
        for block in messages.split(b"moviAsm: ERROR"):
            numbers = re.findall(rb"at line (\d+)", block)
            if b"conflicting" in block and numbers:
                targets.add(int(numbers[-1]))
        if not targets:
            raise RuntimeError(
                "Assembler failed without a conflict to fix; see retained diagnostics"
            )
        for line in sorted(targets, reverse=True):
            at = nop_insertion_point(lines, line - 1)
            lines.insert(at, b"        NOP")
            inserted.append(
                dict(
                    reported_line=line,
                    inserted_before=at + 1,
                    context=[
                        x.decode(errors="replace").strip() for x in lines[max(0, at - 3) : at + 5]
                    ],
                )
            )
        assembly = b"\n".join(lines)
    else:
        raise RuntimeError("Hazard fixing did not converge")
    return assembly, inserted




def read_kernel_text(elf: bytes) -> bytes:
    """Extract one statically linked SHAVE text image without mutable data.

    This validates file structure, not the safety or semantics of instructions.
    Callers must pin the intended kernel hash and qualify its behavior separately.
    """
    require(52 <= len(elf) <= 1024 * 1024, "kernel ELF size")
    require(elf[:7] == b"\x7fELF\x01\x01\x01", "kernel ELF identity")
    header = struct.unpack_from("<16sHHIIIIIHHHHHH", elf)
    require(header[1:5] == (2, 2, 1, 0x1D000000), "kernel architecture and entry")
    require(
        header[11] == 40
        and 0 < header[12] < 64
        and header[13] < header[12]
        and header[6] + header[12] * 40 <= len(elf),
        "kernel section table",
    )
    sections = [struct.unpack_from("<10I", elf, header[6] + i * 40) for i in range(header[12])]
    names_section = sections[header[13]]
    require(names_section[4] + names_section[5] <= len(elf), "kernel names extent")
    strings = elf[names_section[4] : names_section[4] + names_section[5]]
    names = set()
    text = []
    for section in sections:
        require(section[0] < len(strings), "kernel section name")
        end = strings.find(b"\0", section[0])
        require(end >= 0, "kernel section name termination")
        name = strings[section[0] : end]
        require(name not in names, "duplicate kernel section name")
        names.add(name)
        require(section[4] + section[5] <= len(elf), "kernel section extent")
        require(section[1] not in (4, 8, 9), "kernel relocation or BSS unsupported")
        if name == b".arg.data":
            require(section[5] == 0, "kernel mutable data unsupported")
        if name != b".text" and section[2] & 2:
            require(section[5] == 0, "kernel extra allocated section unsupported")
        if name == b".text":
            require(section[3] == 0x1D000000 and section[2] & 4, "kernel text address")
            text.append(elf[section[4] : section[4] + section[5]])
    require(len(text) == 1 and len(text[0]) > 0 and len(text[0]) % 16 == 0, "kernel text extent")
    return text[0]
