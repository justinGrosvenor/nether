//! A minimal blocking spinlock built directly on `std.atomic.Value`, so it does
//! not depend on a particular Zig std mutex type (the freestanding mutex surface
//! has churned across 0.16 builds - `std.atomic.Mutex` exists in some and not
//! others, which made the toolchain contract brittle). `std.atomic.Value` and its
//! cmpxchg/spinLoopHint are stable. Every critical section guarded by this is a
//! handful of field writes (RX FIFO push, redirection-entry read), so spinning is
//! the right shape: contention is rare and held for nanoseconds. This is the
//! concretion of the D3 per-device lock.

const std = @import("std");

pub const Lock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0), // 0 = free, 1 = held

    pub fn tryLock(self: *Lock) bool {
        return self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null;
    }

    pub fn lock(self: *Lock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *Lock) void {
        self.state.store(0, .release);
    }
};

test "lock excludes then releases" {
    var l = Lock{};
    l.lock();
    try std.testing.expect(!l.tryLock()); // held
    l.unlock();
    try std.testing.expect(l.tryLock()); // free again
    l.unlock();
}
