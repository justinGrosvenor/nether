//! A minimal blocking spinlock. Stable Zig 0.16's only freestanding mutex
//! (`std.atomic.Mutex`) exposes `tryLock`/`unlock` but no blocking acquire, and
//! `std.Io.Mutex` needs an `Io` we do not thread through device models. Every
//! critical section guarded by this is a handful of field writes (RX FIFO push,
//! redirection-entry read), so spinning is the right shape: contention is rare
//! and held for nanoseconds. This is the concretion of the D3 per-device lock.

const std = @import("std");

pub const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

test "lock excludes then releases" {
    var l = Lock{};
    l.lock();
    try std.testing.expect(!l.inner.tryLock()); // held
    l.unlock();
    try std.testing.expect(l.inner.tryLock()); // free again
    l.inner.unlock();
}
