const std = @import("std");

pub const HttpServer = struct {
    address: std.net.Address,
    listener: std.net.Server,
    allocator: std.mem.Allocator,
    thread_pool: *std.Thread.Pool,
    doc_root: []const u8,
    absolute_doc_root: []const u8,

    const Self = @This();

    pub fn init(ip: []const u8, port: u16, allocator: std.mem.Allocator, jobs: u8, doc_root: []const u8) !HttpServer {
        const address = try std.net.Address.parseIp(ip, port);
        const listener = try address.listen(.{ .reuse_address = true });

        const thread_pool = try allocator.create(std.Thread.Pool);
        try thread_pool.init(.{ .allocator = allocator, .n_jobs = jobs });

        var doc_root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const doc_root_tmp = try std.fs.cwd().realpath(doc_root, &doc_root_buf);
        const absolute_doc_root = try allocator.dupe(u8, doc_root_tmp);

        std.debug.print("Server listening on: {f}\n", .{address});
        return HttpServer{
            .address = address,
            .listener = listener,
            .allocator = allocator,
            .thread_pool = thread_pool,
            .doc_root = doc_root,
            .absolute_doc_root = absolute_doc_root,
        };
    }

    pub fn serve(self: *Self) !void {
        while (true) {
            const connection = self.listener.accept() catch |err| {
                std.log.err("Failed to accept connection: {}", .{err});
                continue;
            };

            const connPtr = try self.allocator.create(std.net.Server.Connection);
            connPtr.* = connection;
            try self.thread_pool.spawn(handleClientWrapper, .{ self, connPtr });
        }
    }

    fn serveFile(self: *Self, connection: *std.net.Server.Connection, file_path: []const u8) !void {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return try self.sendError(connection, 404, "Not Found"),
            error.AccessDenied => return try self.sendError(connection, 403, "Forbidden"),
            else => {
                std.log.err("Failed to open file {s} for client {f}: {}", .{ file_path, connection.address, err });
                return try self.sendError(connection, 500, "Internal Server Error");
            },
        };
        defer file.close();

        const stat = file.stat() catch |err| {
            std.log.err("Failed to stat file {s} for client {f}: {}", .{ file_path, connection.address, err });
            return try self.sendError(connection, 500, "Internal Server Error");
        };
        if (stat.size > 1024 * 1024 * 10) { // maximum 10MB
            std.log.err("File {s} too large for client {f}", .{ file_path, connection.address });
            return try self.sendError(connection, 413, "Payload Too Large");
        }

        const file_content = file.readToEndAlloc(self.allocator, stat.size) catch |err| {
            std.log.err("Failed to read file {s} for client {f}: {}", .{ file_path, connection.address, err });
            return try self.sendError(connection, 500, "Internal Server Error");
        };
        defer self.allocator.free(file_content);

        const ext = std.fs.path.extension(file_path);
        const content_type = getContentType(ext);
        const response = try std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 200 OK
            \\Content-Type: {s}
            \\Content-Length: {d}
            \\Connection: close
            \\
            \\{s}
        , .{ content_type, file_content.len, file_content });

        defer self.allocator.free(response);

        _ = connection.stream.write(response) catch |err| {
            std.log.err("Failed to write response for client {f}: {}", .{ connection.address, err });
            return err;
        };
    }

    fn getContentType(extension: []const u8) []const u8 {
        const lower_ext = if (extension.len > 0 and extension[0] == '.') extension[1..] else extension;
        return switch (lower_ext.len) {
            0 => "application/octet-stream",
            else => inline for (.{
                .{ ".html", "text/html" },
                .{ ".css", "text/css" },
                .{ ".js", "application/javascript" },
                .{ ".png", "image/png" },
                .{ ".jpg", "image/jpeg" },
                .{ ".jpeg", "image/jpeg" },
                .{ ".gif", "image/gif" },
            }) |pair| {
                if (std.ascii.eqlIgnoreCase(pair[0][1..], lower_ext)) return pair[1];
            } else "application/octet-stream",
        };
    }

    fn sendError(self: *Self, connection: *std.net.Server.Connection, status: u16, msg: []const u8) !void {
        const valid_status = switch (status) {
            400, 403, 404, 413, 414, 500 => status,
            else => 500,
        };
        const response = try std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 {d} {s}
            \\Content-Type: text/plain
            \\Connection: close
            \\
            \\{s}
        , .{ valid_status, msg, msg });
        defer self.allocator.free(response);

        _ = connection.stream.write(response) catch |err| {
            std.log.err("Failed to write error response for client {f}: {}", .{ connection.address, err });
            return err;
        };
    }

    fn handleClientWrapper(self: *Self, connPtr: *std.net.Server.Connection) void {
        defer {
            connPtr.stream.close();
            self.allocator.destroy(connPtr);
        }
        self.handleClient(connPtr) catch |err| {
            std.log.err("Error handling client {f}: {}", .{ connPtr.address, err });
        };
    }

    fn handleClient(self: *Self, connection: *std.net.Server.Connection) !void {
        var buffer: [1024]u8 = undefined;
        const read_size = try connection.stream.read(&buffer);
        if (read_size == 0) return;

        const request = buffer[0..read_size];

        if (!std.mem.startsWith(u8, request, "GET ")) {
            std.log.err("Invalid HTTP method from client {f}", .{connection.address});
            return try self.sendError(connection, 400, "Bad Request: Only GET supported");
        }

        const path_start = std.mem.indexOf(u8, request, " ") orelse {
            std.log.err("Invalid request format from client {f}", .{connection.address});
            return try self.sendError(connection, 400, "Bad Request");
        };
        const path_end = std.mem.indexOfPos(u8, request, path_start + 1, " ") orelse {
            std.log.err("Invalid request format from client {f}", .{connection.address});
            return try self.sendError(connection, 400, "Bad Request");
        };
        var req_path = request[path_start + 1 .. path_end];

        if (std.mem.indexOfScalar(u8, req_path, 0) != null) {
            std.log.err("Invalid path with null byte from client {f}", .{connection.address});
            return try self.sendError(connection, 400, "Bad Request: Invalid path");
        }

        var owned_path: ?[]u8 = null;
        defer if (owned_path) |p| self.allocator.free(p);
        if (std.mem.eql(u8, req_path, "/")) {
            owned_path = try self.allocator.dupe(u8, "/index.html");
            req_path = owned_path.?;
        }

        if (req_path.len > 255) {
            std.log.err("Path too long from client {f}: {s}", .{ connection.address, req_path });
            return try self.sendError(connection, 414, "URI Too Long");
        }

        // buffer no longer needed as the real path is already allocated on heap
        // var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;

        const full_path = std.fs.path.resolve(self.allocator, &[_][]const u8{ self.absolute_doc_root, req_path[1..] }) catch |err| {
            std.log.err("Failed to resolve path {s} for client {f}: {}", .{ req_path, connection.address, err });
            return try self.sendError(connection, 400, "Bad Request: Invalid path");
        };
        defer self.allocator.free(full_path);

        if (!std.mem.startsWith(u8, full_path, self.absolute_doc_root)) {
            std.log.err("Scope traversal attempted by client {f}: Requested {s}, resolved to {s}", .{ connection.address, req_path, full_path });
            return try self.sendError(connection, 403, "Forbidden: Out Of Scope");
        }

        std.log.info("Client {f} requested: {s}", .{ connection.address, req_path });

        var dir = std.fs.cwd().openDir(full_path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                return try self.serveFile(connection, full_path);
            },
            error.AccessDenied => return try self.sendError(connection, 403, "Forbidden"),
            else => {
                std.log.err("Filesystem error for path {s} from client {f}: {}", .{ full_path, connection.address, err });
                return try self.sendError(connection, 500, "Internal Server Error");
            },
        };
        defer dir.close();

        const index_path = try std.fs.path.join(self.allocator, &[_][]const u8{ full_path, "index.html" });
        defer self.allocator.free(index_path);
        try self.serveFile(connection, index_path);
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.absolute_doc_root);
        self.thread_pool.deinit();
        self.allocator.destroy(self.thread_pool);
        self.listener.deinit();
    }
};
