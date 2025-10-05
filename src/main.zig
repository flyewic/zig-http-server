const std = @import("std");
const HttpServerModule = @import("http_server.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var server = try HttpServerModule.HttpServer.init("127.0.0.1", 8080, allocator, 8);
    defer server.deinit();

    try server.serve();
}
