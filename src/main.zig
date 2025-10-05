const std = @import("std");
const HttpServerModule = @import("http_server.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var server = try HttpServerModule.HttpServer.init("127.0.0.1", 8080, allocator);
    defer server.deinit();

    try server.serve();
}
