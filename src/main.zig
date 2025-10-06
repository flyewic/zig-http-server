const std = @import("std");
const HttpServer = @import("http_server.zig").HttpServer;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var server = try HttpServer.init("127.0.0.1", 8080, allocator, 4, "./public");
    defer server.deinit();

    try server.serve();
}
