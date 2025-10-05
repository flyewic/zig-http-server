const std = @import("std");

pub const HttpServer = struct {
    address: std.net.Address,
    listener: std.net.Server,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ip: []const u8, port: u16, allocator: std.mem.Allocator) !HttpServer {
        const address = try std.net.Address.parseIp(ip, port);
        const listener = try address.listen(.{ .reuse_address = true });

        std.debug.print("Server listening on: {f}\n", .{address});
        return HttpServer{
            .address = address,
            .listener = listener,
            .allocator = allocator,
        };
    }

    pub fn serve(self: *Self) !void {
        while (true) {
            var connection = try self.listener.accept() catch |err| {
                std.log.err("Failed to accept connection: {}", .{err});
                continue;
            };
            defer connection.stream.close();

            try self.handleClient(&connection);
        }
    }

    fn handleClient(self: *Self, connection: *std.net.Server.Connection) !void {
        var buffer: [1024]u8 = undefined;
        const read_size = try connection.stream.read(&buffer);
        if (read_size == 0) return;

        const request = buffer[0..read_size];
        const path = if (std.mem.startsWith(u8, request, "GET ")) {
            request[4 .. std.mem.indexOf(u8, request, " HTTP/") orelse request.len];
        } else {
            "(invalid request)";
        };

        std.log.info("Client {} requested: {s}", .{ connection.address, path });

        var response: []const u8 = undefined;
        if (std.mem.startsWith(u8, request, "GET / HTTP/1.1")) {
            const file = std.fs.cwd().openFile("./html/index.html", .{}) catch |err| {
                std.log.err("Failed to open index.html: {}", .{err});
                response =
                    \\HTTP/1.1 500 Internal Server Error
                    \\Content-Type: text/plain
                    \\Connection: close
                    \\
                    \\500 Internal Server Error: Could not open index.html
                ;
                _ = try connection.stream.write(response);
                return;
            };
            defer file.close();
            const file_content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
            defer self.allocator.free(file_content);

            response = try std.fmt.allocPrint(self.allocator,
                \\HTTP/1.1 200 OK
                \\Content-Type: text/html
                \\Content-Length: {d}
                \\Connection: close
                \\
                \\{s}
            , .{ file_content.len, file_content });
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

    pub fn deinit(self: *Self) void {
        self.listener.deinit();
    }
};
