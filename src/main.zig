const std = @import("std");
const HttpServer = @import("http_server.zig").HttpServer;

const Config = struct {
    host: []const u8,
    port: u16,
    thread_count: u8,
    working_dir: []const u8,
};

fn readConfig(allocator: std.mem.Allocator, file_path: []const u8) !std.json.Parsed(Config) {
    const data = try std.fs.cwd().readFileAlloc(allocator, file_path, 512);
    defer allocator.free(data);
    return std.json.parseFromSlice(Config, allocator, data, .{ .allocate = .alloc_always });
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var parsed = try readConfig(allocator, "config.json");
    defer parsed.deinit();

    const config = parsed.value;

    var server = try HttpServer.init(config.host, config.port, allocator, config.thread_count, config.working_dir);
    defer server.deinit();

    try server.serve();
}
