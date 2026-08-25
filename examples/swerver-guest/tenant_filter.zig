//! Turn each unique x-tenant header into a supervisor `ensure` call, then use
//! the returned Nether data socket as this request's upstream.

const std = @import("std");

extern "env" fn get_path(out_ptr: [*]u8, out_cap: u32) u32;
extern "env" fn get_header(name_ptr: [*]const u8, name_len: u32, out_ptr: [*]u8, out_cap: u32) u32;
extern "env" fn host_call(ptr: [*]const u8, len: u32) i32;
extern "env" fn read_call_result(out_ptr: [*]u8, out_cap: u32) u32;
extern "env" fn set_upstream(ptr: [*]const u8, len: u32) i32;

var path_buf: [1024]u8 = undefined;
var tenant_buf: [128]u8 = undefined;
var call_buf: [160]u8 = undefined;
var result_buf: [256]u8 = undefined;

const tenant_header = "x-tenant";
const route_prefix = "/tenant";

export fn on_request() i32 {
    const path_len = @min(get_path(&path_buf, path_buf.len), path_buf.len);
    if (!std.mem.startsWith(u8, path_buf[0..path_len], route_prefix)) return 0;

    const tenant_len = @min(
        get_header(tenant_header, tenant_header.len, &tenant_buf, tenant_buf.len),
        tenant_buf.len,
    );
    const tenant = if (tenant_len == 0) "default" else tenant_buf[0..tenant_len];
    const command = std.fmt.bufPrint(&call_buf, "ensure {s}", .{tenant}) catch return 1;
    if (host_call(command.ptr, @intCast(command.len)) != 0) return 1;
    return 3;
}

export fn on_resume() i32 {
    const len = @min(read_call_result(&result_buf, result_buf.len), result_buf.len);
    const result = result_buf[0..len];
    const separator = std.mem.indexOfScalar(u8, result, 0x1e) orelse return 1;
    if (separator == 0) return 1;
    if (set_upstream(result[0..separator].ptr, @intCast(separator)) != 0) return 1;
    return 0;
}
