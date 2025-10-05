const std = @import("std");

pub fn main() !void {
    // create listener
    const address = try std.net.Address.parseIp("127.0.0.1", 8080);
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    std.debug.print("Server listening on {f}\n", .{address});

    while (true) {
        var connection = try listener.accept();
        defer connection.stream.close();

        try handleClient(&connection);
    }
}

fn handleClient(connection: *std.net.Server.Connection) !void {
    var buffer: [1024]u8 = undefined;
    const read_size = try connection.stream.read(&buffer);
    if (read_size == 0) return;

    const request = buffer[0..read_size];
    var response: []const u8 = undefined;

    if (std.mem.startsWith(u8, request, "GET / HTTP/1.1")) {
        response =
            \\HTTP/1.1 200 OK
            \\Content-Type: text/html
            \\Connection: close
            \\
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>zig-http-server</title></head>
            \\<body><h1>epic zig server</h1></body>
            \\</html>
        ;
    } else {
        response =
            \\HTTP/1.1 404 Not Found
            \\Content-Type: text/plain
            \\Connection: close
            \\
            \\404 Not Found
        ;
    }

    _ = try connection.stream.write(response);
}
