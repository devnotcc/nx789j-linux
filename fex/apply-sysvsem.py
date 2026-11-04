# Wire the user-space System V semaphore fallback (SysVSemEmu.*) into a FEX source tree.
# Run in the FEX checkout:  python3 apply-sysvsem.py   (copies the two files next to this script)
import os, re, shutil

here = os.path.dirname(os.path.abspath(__file__))
base = "Source/Tools/LinuxEmulation/"
for f in ("SysVSemEmu.h", "SysVSemEmu.cpp"):
    shutil.copy(os.path.join(here, f), base + "LinuxSyscalls/" + f)

p = base + "CMakeLists.txt"
s = open(p).read()
if "SysVSemEmu.cpp" not in s:
    anchor = "  LinuxSyscalls/LinuxAllocator.cpp\n"
    assert s.count(anchor) == 1
    s = s.replace(anchor, anchor + "  LinuxSyscalls/SysVSemEmu.cpp\n")
    open(p, "w").write(s)

inc = '#include "LinuxSyscalls/SysVSemEmu.h"\n'
for p in (base + "LinuxSyscalls/x32/Semaphore.cpp", base + "LinuxSyscalls/x64/Semaphore.cpp"):
    s = open(p).read()
    s, n = re.subn(r"::syscall\(SYSCALL_DEF\((semop|semget|semctl|semtimedop)\)", r"FEX::HLE::SysVSem::Syscall(SYSCALL_DEF(\1)", s)
    assert n > 0, p
    if inc not in s:
        i = s.index("#include")
        s = s[:i] + inc + s[i:]
    open(p, "w").write(s)
    print(p, n, "calls")

p = base + "LinuxSyscalls/Syscalls/Passthrough.cpp"
s = open(p).read()
lam = ("[](FEXCore::Core::CpuStateFrame* Frame, uint64_t a, uint64_t b, uint64_t c, uint64_t d) -> uint64_t {{ "
       "uint64_t Result = FEX::HLE::SysVSem::Syscall(SYSCALL_DEF({host}), a, b, c, d); SYSCALL_ERRNO(); }}")
for reg, name, tmpl, host in (
        ("REGISTER_SYSCALL_IMPL", "semget", "SyscallPassthrough3", "semget"),
        ("REGISTER_SYSCALL_IMPL_X64", "semop", "SyscallPassthrough3", "semop"),
        ("REGISTER_SYSCALL_IMPL_X64", "semtimedop", "SyscallPassthrough4", "semtimedop"),
        ("REGISTER_SYSCALL_IMPL_X32", "semtimedop_time64", "SyscallPassthrough4", "semtimedop")):
    old = "%s(%s, %s<SYSCALL_DEF(%s)>);" % (reg, name, tmpl, host)
    if old in s:
        s = s.replace(old, "%s(%s, %s);" % (reg, name, lam.format(host=host)))
        print("passthrough:", name)
if inc not in s:
    i = s.index("#include")
    s = s[:i] + inc + s[i:]
open(p, "w").write(s)
print("done")
