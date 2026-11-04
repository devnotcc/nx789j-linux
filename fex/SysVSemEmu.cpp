// SPDX-License-Identifier: MIT
// nx789j: user-space System V semaphores, see SysVSemEmu.h.
#include "LinuxSyscalls/SysVSemEmu.h"

#include <atomic>
#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fcntl.h>
#include <linux/futex.h>
#include <sys/ipc.h>
#include <sys/mman.h>
#include <sys/random.h>
#include <sys/sem.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace FEX::HLE::SysVSem {
namespace {
  constexpr uint32_t Magic = 0x4e585356; // "NXSV"
  constexpr size_t SetSize = 4096;
  constexpr int MaxValue = 32767; // the kernel's SEMVMX

  struct Set {
    uint32_t Magic;
    uint32_t NSems;
    std::atomic<uint32_t> Lock;    // 0 free, 1 held, 2 held with waiters
    std::atomic<uint32_t> Seq;     // bumped on every change; sleepers wait on it
    std::atomic<uint32_t> Removed; // IPC_RMID was called
    uint32_t Key;
    uint32_t Mode;
    uint32_t Uid;
    int64_t OTime;
    int64_t CTime;
    int32_t Val[];
  };
  constexpr uint32_t MaxSems = (SetSize - sizeof(Set)) / sizeof(int32_t);

  struct Mapping {
    int Id;
    Set* Ptr;
  };
  constexpr int MaxMappings = 512;
  Mapping Mappings[MaxMappings];
  std::atomic<uint32_t> TableLock {};
  std::atomic<int> Mode {}; // 0 not known yet, 1 the host kernel has SysV IPC, 2 emulate

  long Futex(std::atomic<uint32_t>* Word, int Op, uint32_t Value, const struct timespec* Timeout) {
    return ::syscall(SYS_futex, Word, Op, Value, Timeout, nullptr, 0);
  }

  void LockWord(std::atomic<uint32_t>& Word) {
    uint32_t Expected = 0;
    if (Word.compare_exchange_strong(Expected, 1)) {
      return;
    }
    while (Word.exchange(2) != 0) {
      Futex(&Word, FUTEX_WAIT, 2, nullptr);
    }
  }
  void UnlockWord(std::atomic<uint32_t>& Word) {
    if (Word.exchange(0) == 2) {
      Futex(&Word, FUTEX_WAKE, 1, nullptr);
    }
  }

  // Directory with one file per set ("id.<n>") and one symlink per key ("key.<hex>" -> id.<n>)
  int Dir(char* Out, size_t Size) {
    int Len = snprintf(Out, Size, "/dev/shm/.fex-sysvsem-%u", static_cast<unsigned>(::getuid()));
    ::mkdir(Out, 0700);
    return Len;
  }

  Set* MapId(int Id) {
    LockWord(TableLock);
    Set* Result = nullptr;
    int Free = -1;
    for (int i = 0; i < MaxMappings; ++i) {
      if (Mappings[i].Ptr && Mappings[i].Id == Id) {
        Result = Mappings[i].Ptr;
        break;
      }
      if (!Mappings[i].Ptr && Free < 0) {
        Free = i;
      }
    }
    if (!Result && Free >= 0) {
      char Path[128];
      int Len = Dir(Path, sizeof(Path));
      snprintf(Path + Len, sizeof(Path) - Len, "/id.%d", Id);
      int FD = ::open(Path, O_RDWR | O_CLOEXEC);
      if (FD >= 0) {
        void* Ptr = ::mmap(nullptr, SetSize, PROT_READ | PROT_WRITE, MAP_SHARED, FD, 0);
        ::close(FD);
        if (Ptr != MAP_FAILED) {
          Set* S = static_cast<Set*>(Ptr);
          if (S->Magic == Magic) {
            Mappings[Free] = {Id, S};
            Result = S;
          } else {
            ::munmap(Ptr, SetSize);
          }
        }
      }
    }
    UnlockWord(TableLock);
    return Result;
  }

  void Forget(int Id) {
    LockWord(TableLock);
    for (int i = 0; i < MaxMappings; ++i) {
      if (Mappings[i].Ptr && Mappings[i].Id == Id) {
        ::munmap(Mappings[i].Ptr, SetSize);
        Mappings[i] = {};
      }
    }
    UnlockWord(TableLock);
  }

  long Fail(int Error) {
    errno = Error;
    return -1;
  }

  long SemGet(key_t Key, int NSems, int Flags) {
    if (NSems < 0 || static_cast<uint32_t>(NSems) > MaxSems) {
      return Fail(EINVAL);
    }
    char Path[128], KeyPath[128];
    int Len = Dir(Path, sizeof(Path));
    memcpy(KeyPath, Path, Len);
    snprintf(KeyPath + Len, sizeof(KeyPath) - Len, "/key.%08x", static_cast<unsigned>(Key));

    for (int Attempt = 0; Attempt < 64; ++Attempt) {
      if (Key != IPC_PRIVATE) {
        char Target[64];
        ssize_t TargetLen = ::readlink(KeyPath, Target, sizeof(Target) - 1);
        if (TargetLen > 3) {
          Target[TargetLen] = 0;
          int Id = atoi(Target + 3); // "id.<n>"
          Set* S = MapId(Id);
          if (!S || S->Removed.load()) {
            // stale link (set removed, or its creator died half way): drop it and look again
            ::unlink(KeyPath);
            Forget(Id);
            continue;
          }
          if ((Flags & IPC_CREAT) && (Flags & IPC_EXCL)) {
            return Fail(EEXIST);
          }
          if (static_cast<uint32_t>(NSems) > S->NSems) {
            return Fail(EINVAL);
          }
          return Id;
        }
        if (!(Flags & IPC_CREAT)) {
          return Fail(ENOENT);
        }
      }
      if (NSems == 0) {
        return Fail(EINVAL);
      }

      uint32_t Random {};
      if (::getrandom(&Random, sizeof(Random), 0) != sizeof(Random)) {
        Random = static_cast<uint32_t>(::getpid()) * 2654435761u + Attempt;
      }
      int Id = static_cast<int>(Random & 0x3fffffff) | 0x10000; // positive, never 0
      snprintf(Path + Len, sizeof(Path) - Len, "/id.%d", Id);
      int FD = ::open(Path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
      if (FD < 0) {
        if (errno == EEXIST) {
          continue;
        }
        return Fail(ENOSPC);
      }
      if (::ftruncate(FD, SetSize) != 0) {
        ::close(FD);
        ::unlink(Path);
        return Fail(ENOSPC);
      }
      void* Ptr = ::mmap(nullptr, SetSize, PROT_READ | PROT_WRITE, MAP_SHARED, FD, 0);
      ::close(FD);
      if (Ptr == MAP_FAILED) {
        ::unlink(Path);
        return Fail(ENOMEM);
      }
      Set* S = static_cast<Set*>(Ptr);
      S->NSems = NSems;
      S->Key = static_cast<uint32_t>(Key);
      S->Mode = Flags & 0777;
      S->Uid = ::getuid();
      S->CTime = ::time(nullptr);
      S->Magic = Magic; // last: a set is valid only from here on
      ::munmap(Ptr, SetSize);

      if (Key != IPC_PRIVATE) {
        char Target[64];
        snprintf(Target, sizeof(Target), "id.%d", Id);
        if (::symlink(Target, KeyPath) != 0) {
          // somebody else created the key in the meantime: use theirs
          ::unlink(Path);
          if (errno == EEXIST) {
            continue;
          }
          return Fail(ENOSPC);
        }
      }
      return Id;
    }
    return Fail(ENOSPC);
  }

  long SemOp(int Id, struct sembuf* Ops, size_t NOps, const struct timespec* Timeout) {
    if (NOps == 0 || NOps > 500) {
      return Fail(NOps ? E2BIG : EINVAL);
    }
    Set* S = MapId(Id);
    if (!S) {
      return Fail(EINVAL);
    }
    for (size_t i = 0; i < NOps; ++i) {
      if (Ops[i].sem_num >= S->NSems) {
        return Fail(EFBIG);
      }
    }
    struct timespec Deadline {};
    if (Timeout) {
      ::clock_gettime(CLOCK_MONOTONIC, &Deadline);
      Deadline.tv_sec += Timeout->tv_sec;
      Deadline.tv_nsec += Timeout->tv_nsec;
      if (Deadline.tv_nsec >= 1000000000L) {
        Deadline.tv_nsec -= 1000000000L;
        Deadline.tv_sec++;
      }
    }

    for (;;) {
      LockWord(S->Lock);
      if (S->Removed.load()) {
        UnlockWord(S->Lock);
        return Fail(EIDRM);
      }
      // all or nothing: try the operations on a scratch copy of the values they touch
      bool Possible = true, NoWait = false, Range = false;
      for (size_t i = 0; i < NOps && Possible; ++i) {
        int64_t Value = S->Val[Ops[i].sem_num];
        for (size_t j = 0; j < i; ++j) {
          if (Ops[j].sem_num == Ops[i].sem_num) {
            Value += Ops[j].sem_op;
          }
        }
        if (Ops[i].sem_op == 0 ? Value != 0 : Value + Ops[i].sem_op < 0) {
          Possible = false;
          NoWait = Ops[i].sem_flg & IPC_NOWAIT;
        } else if (Value + Ops[i].sem_op > MaxValue) {
          Range = true;
        }
      }
      if (Possible && Range) {
        UnlockWord(S->Lock);
        return Fail(ERANGE);
      }
      if (Possible) {
        for (size_t i = 0; i < NOps; ++i) {
          S->Val[Ops[i].sem_num] += Ops[i].sem_op;
        }
        S->OTime = ::time(nullptr);
        S->Seq.fetch_add(1);
        UnlockWord(S->Lock);
        Futex(&S->Seq, FUTEX_WAKE, INT_MAX, nullptr);
        return 0;
      }
      const uint32_t Seen = S->Seq.load();
      UnlockWord(S->Lock);
      if (NoWait) {
        return Fail(EAGAIN);
      }

      struct timespec Left {};
      if (Timeout) {
        struct timespec Now {};
        ::clock_gettime(CLOCK_MONOTONIC, &Now);
        Left.tv_sec = Deadline.tv_sec - Now.tv_sec;
        Left.tv_nsec = Deadline.tv_nsec - Now.tv_nsec;
        if (Left.tv_nsec < 0) {
          Left.tv_nsec += 1000000000L;
          Left.tv_sec--;
        }
        if (Left.tv_sec < 0) {
          return Fail(EAGAIN);
        }
      }
      if (Futex(&S->Seq, FUTEX_WAIT, Seen, Timeout ? &Left : nullptr) != 0) {
        if (errno == EINTR) {
          return -1; // errno stays EINTR: the guest's signal handler runs, then it retries
        }
        if (errno == ETIMEDOUT) {
          return Fail(EAGAIN);
        }
      }
    }
  }

  long SemCtl(int Id, int Num, int Cmd, uint64_t Arg) {
    Cmd &= 0xff; // IPC_64 flag
    if (Cmd == IPC_INFO || Cmd == SEM_INFO) {
      struct seminfo* Info = reinterpret_cast<struct seminfo*>(Arg);
      memset(Info, 0, sizeof(*Info));
      Info->semmni = 32000;
      Info->semmsl = MaxSems;
      Info->semmns = 32000 * MaxSems;
      Info->semopm = 500;
      Info->semvmx = MaxValue;
      return 0;
    }
    Set* S = MapId(Id);
    if (!S) {
      return Fail(EINVAL);
    }
    if (S->Removed.load()) {
      return Fail(EIDRM);
    }
    long Result = 0;
    switch (Cmd) {
    case IPC_RMID: {
      char Path[128];
      int Len = Dir(Path, sizeof(Path));
      LockWord(S->Lock);
      S->Removed.store(1);
      S->Seq.fetch_add(1);
      const uint32_t Key = S->Key;
      UnlockWord(S->Lock);
      Futex(&S->Seq, FUTEX_WAKE, INT_MAX, nullptr);
      if (Key != static_cast<uint32_t>(IPC_PRIVATE)) {
        snprintf(Path + Len, sizeof(Path) - Len, "/key.%08x", Key);
        ::unlink(Path);
      }
      snprintf(Path + Len, sizeof(Path) - Len, "/id.%d", Id);
      ::unlink(Path);
      Forget(Id);
      return 0;
    }
    case IPC_SET: return 0;
    case IPC_STAT:
    case SEM_STAT:
    case 20 /* SEM_STAT_ANY */: {
      struct semid_ds* Stat = reinterpret_cast<struct semid_ds*>(Arg);
      memset(Stat, 0, sizeof(*Stat));
      Stat->sem_perm.__key = static_cast<key_t>(S->Key);
      Stat->sem_perm.uid = Stat->sem_perm.cuid = S->Uid;
      Stat->sem_perm.gid = Stat->sem_perm.cgid = ::getgid();
      Stat->sem_perm.mode = S->Mode;
      Stat->sem_otime = S->OTime;
      Stat->sem_ctime = S->CTime;
      Stat->sem_nsems = S->NSems;
      return Cmd == IPC_STAT ? 0 : Id;
    }
    case GETPID:
    case GETNCNT:
    case GETZCNT: return 0;
    default: break;
    }

    if ((Cmd == GETVAL || Cmd == SETVAL) && (Num < 0 || static_cast<uint32_t>(Num) >= S->NSems)) {
      return Fail(EINVAL);
    }
    LockWord(S->Lock);
    switch (Cmd) {
    case GETVAL: Result = S->Val[Num]; break;
    case SETVAL: {
      const int Value = static_cast<int>(Arg);
      if (Value < 0 || Value > MaxValue) {
        errno = ERANGE;
        Result = -1;
      } else {
        S->Val[Num] = Value;
      }
      break;
    }
    case GETALL: {
      unsigned short* Array = reinterpret_cast<unsigned short*>(Arg);
      for (uint32_t i = 0; i < S->NSems; ++i) {
        Array[i] = S->Val[i];
      }
      break;
    }
    case SETALL: {
      const unsigned short* Array = reinterpret_cast<const unsigned short*>(Arg);
      for (uint32_t i = 0; i < S->NSems; ++i) {
        S->Val[i] = Array[i];
      }
      break;
    }
    default:
      errno = EINVAL;
      Result = -1;
      break;
    }
    if (Cmd == SETVAL || Cmd == SETALL) {
      S->CTime = ::time(nullptr);
      S->Seq.fetch_add(1);
    }
    UnlockWord(S->Lock);
    if (Cmd == SETVAL || Cmd == SETALL) {
      Futex(&S->Seq, FUTEX_WAKE, INT_MAX, nullptr);
    }
    return Result;
  }
} // namespace

long HostOrEmulated(long Number, uint64_t A, uint64_t B, uint64_t C, uint64_t D) {
  if (Mode.load(std::memory_order_relaxed) != 2) {
    long Result = ::syscall(Number, A, B, C, D);
    if (!(Result == -1 && errno == ENOSYS)) {
      Mode.store(1, std::memory_order_relaxed);
      return Result;
    }
    Mode.store(2, std::memory_order_relaxed);
  }
  switch (Number) {
  case SYS_semget: return SemGet(static_cast<key_t>(A), static_cast<int>(B), static_cast<int>(C));
  case SYS_semop: return SemOp(static_cast<int>(A), reinterpret_cast<struct sembuf*>(B), C, nullptr);
  case SYS_semtimedop: return SemOp(static_cast<int>(A), reinterpret_cast<struct sembuf*>(B), C, reinterpret_cast<const struct timespec*>(D));
  case SYS_semctl: return SemCtl(static_cast<int>(A), static_cast<int>(B), static_cast<int>(C), D);
  default: return Fail(ENOSYS);
  }
}
} // namespace FEX::HLE::SysVSem
