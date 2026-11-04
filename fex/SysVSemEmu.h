// SPDX-License-Identifier: MIT
// nx789j: System V semaphores for guests on a host kernel built without CONFIG_SYSVIPC.
//
// The phone's kernel cannot enable SYSVIPC (it changes task_struct, and with it the symbol CRCs
// of ~400 prebuilt vendor modules), but the Steam client refuses to start without semget/semop.
// FEX is the guest's syscall layer, so the calls are served here: the first host call that
// answers ENOSYS switches this process to a user-space implementation. A semaphore set is a
// 4 KiB file in /dev/shm/.fex-sysvsem-<uid>/ mapped shared by every process that uses it;
// blocking is done with shared futexes on that mapping. SEM_UNDO is accepted and ignored.
#pragma once
#include <cstdint>
#include <cstring>

namespace FEX::HLE::SysVSem {
// Same contract as ::syscall(): result, or -1 with errno set. Arguments are the HOST layouts
// (FEX has already converted 32-bit guest structures before it makes the host call).
long HostOrEmulated(long Number, uint64_t A, uint64_t B, uint64_t C, uint64_t D);

template<typename T>
static inline uint64_t ToArg(T Value) {
  uint64_t Result {};
  memcpy(&Result, &Value, sizeof(Value) < sizeof(Result) ? sizeof(Value) : sizeof(Result));
  return Result;
}

static inline long Syscall(long Number) {
  return HostOrEmulated(Number, 0, 0, 0, 0);
}
template<typename T1>
static inline long Syscall(long Number, T1 A) {
  return HostOrEmulated(Number, ToArg(A), 0, 0, 0);
}
template<typename T1, typename T2>
static inline long Syscall(long Number, T1 A, T2 B) {
  return HostOrEmulated(Number, ToArg(A), ToArg(B), 0, 0);
}
template<typename T1, typename T2, typename T3>
static inline long Syscall(long Number, T1 A, T2 B, T3 C) {
  return HostOrEmulated(Number, ToArg(A), ToArg(B), ToArg(C), 0);
}
template<typename T1, typename T2, typename T3, typename T4>
static inline long Syscall(long Number, T1 A, T2 B, T3 C, T4 D) {
  return HostOrEmulated(Number, ToArg(A), ToArg(B), ToArg(C), ToArg(D));
}
} // namespace FEX::HLE::SysVSem
