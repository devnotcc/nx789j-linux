// nx789j: libnx-sysvsem.so - System V semaphores for NATIVE programs on a kernel without
// CONFIG_SYSVIPC (LD_PRELOAD). Same implementation and on-disk format as the FEX patch
// (SysVSemEmu.cpp), so native ARM64 processes and x86 processes under FEX share semaphores.
// build: g++ -O2 -fPIC -shared -I. -o libnx-sysvsem.so sysvsem-preload.cpp SysVSemEmu.cpp
#include "LinuxSyscalls/SysVSemEmu.h"
#include <cstdarg>
#include <sys/ipc.h>
#include <sys/sem.h>
#include <sys/syscall.h>
#include <time.h>

using FEX::HLE::SysVSem::HostOrEmulated;
extern "C" {
__attribute__((visibility("default"))) int semget(key_t Key, int NSems, int Flags) {
  return HostOrEmulated(SYS_semget, static_cast<uint64_t>(Key), NSems, Flags, 0);
}
__attribute__((visibility("default"))) int semop(int Id, struct sembuf* Ops, size_t NOps) {
  return HostOrEmulated(SYS_semop, Id, reinterpret_cast<uint64_t>(Ops), NOps, 0);
}
__attribute__((visibility("default"))) int semtimedop(int Id, struct sembuf* Ops, size_t NOps, const struct timespec* Timeout) {
  return HostOrEmulated(SYS_semtimedop, Id, reinterpret_cast<uint64_t>(Ops), NOps, reinterpret_cast<uint64_t>(Timeout));
}
__attribute__((visibility("default"))) int semctl(int Id, int Num, int Cmd, ...) {
  va_list Args;
  va_start(Args, Cmd);
  uint64_t Arg = va_arg(Args, uint64_t); // union semun: an int or a pointer, 8 bytes either way
  va_end(Args);
  return HostOrEmulated(SYS_semctl, Id, Num, Cmd, Arg);
}
}
