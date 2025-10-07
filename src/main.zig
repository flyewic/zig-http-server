const std = @import("std");
const HttpServer = @import("http_server.zig").HttpServer;

const Config = struct {
    host: []const u8,
    port: u16,
    thread_count: usize,
    working_dir: []const u8,
};

fn readConfig(allocator: std.mem.Allocator, file_path: []const u8) !std.json.Parsed(Config) {
    const data = try std.fs.cwd().readFileAlloc(allocator, file_path, 512);
    defer allocator.free(data);
    return std.json.parseFromSlice(Config, allocator, data, .{ .allocate = .alloc_always });
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var parsed = readConfig(allocator, "config.json") catch |err| {
        if (err == error.FileNotFound) {
            std.log.err("Configuration file not found, has to be named config.json!\n", .{});
        } else if (err == error.UnexpectedEndOfInput) {
            std.log.err("There's an issue with the configuration file, please refer to the GitHub for proper syntax!\n", .{});
        } else {
            std.log.err("Unknown error!\n", .{});
        }
        return err;
    };
    defer parsed.deinit();

    var config = parsed.value;
    if (config.thread_count == 0) {
        config.thread_count = std.Thread.getCpuCount() catch 1;
    }

    var server = try HttpServer.init(config.host, config.port, allocator, config.thread_count, config.working_dir);
    defer server.deinit();

    try server.serve();
}
