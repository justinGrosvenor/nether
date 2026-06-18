//! Shared power state. Firmware-floor devices (reset port, ACPI PM block)
//! request a transition from inside an I/O exit; the vCPU loop observes it after
//! each exit and stops with the matching reason. This keeps device handlers
//! side-effect-free with respect to the run loop's control flow.

pub const Action = enum { reset, shutdown };

pub const Power = struct {
    action: ?Action = null,

    pub fn request(self: *Power, a: Action) void {
        self.action = a;
    }
};
