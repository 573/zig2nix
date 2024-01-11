const std = @import("std");

fn stringifyFieldName(allocator: std.mem.Allocator, ast: std.zig.Ast, idx: std.zig.Ast.Node.Index) !?[]const u8 {
    if (ast.firstToken(idx) < 2) return null;
    const slice = ast.tokenSlice(ast.firstToken(idx) - 2);
    if (slice[0] == '@') {
        const v = try std.zig.string_literal.parseAlloc(allocator, slice[1..]);
        defer allocator.free(v);
        return try std.json.stringifyAlloc(allocator, v, .{});
    }
    return try std.json.stringifyAlloc(allocator, slice, .{});
}

fn stringifyValue(allocator: std.mem.Allocator, ast: std.zig.Ast, idx: std.zig.Ast.Node.Index) !?[]const u8 {
    const slice = ast.tokenSlice(ast.nodes.items(.main_token)[idx]);
    std.log.debug("value: {s}", .{slice});
    if (slice[0] == '\'') {
        switch (std.zig.parseCharLiteral(slice)) {
            .success => |v| return try std.json.stringifyAlloc(allocator, v, .{}),
            .failure => return error.parseCharLiteralFailed,
        }
    } else if (slice[0] == '"') {
        const v = try std.zig.string_literal.parseAlloc(allocator, slice);
        defer allocator.free(v);
        return try std.json.stringifyAlloc(allocator, v, .{});
    }
    switch (std.zig.number_literal.parseNumberLiteral(slice)) {
        .int => |v| return try std.json.stringifyAlloc(allocator, v, .{}),
        .float => |v| return try std.json.stringifyAlloc(allocator, v, .{}),
        .big_int => |v| return try std.json.stringifyAlloc(allocator, v, .{}),
        .failure => {},
    }
    // literal
    return try std.json.stringifyAlloc(allocator, slice, .{});
}

fn stringify(allocator: std.mem.Allocator, writer: anytype, ast: std.zig.Ast, idx: std.zig.Ast.Node.Index, has_name: bool) !void {
    if (has_name) {
        if (try stringifyFieldName(allocator, ast, idx)) |name| {
            defer allocator.free(name);
            std.log.debug("field: {s}", .{name});
            try writer.print("{s}:", .{name});
        }
    }

    var buf: [2]std.zig.Ast.Node.Index = undefined;
    if (ast.fullStructInit(&buf, idx)) |v| {
        try writer.writeAll("{");
        for (v.ast.fields, 0..) |i, n| {
            try stringify(allocator, writer, ast, i, true);
            if (n + 1 != v.ast.fields.len) try writer.writeAll(",");
        }
        try writer.writeAll("}");
    } else if (ast.fullArrayInit(&buf, idx)) |v| {
        try writer.writeAll("[");
        for (v.ast.elements, 0..) |i, n| {
            try stringify(allocator, writer, ast, i, false) ;
            if (n + 1 != v.ast.elements.len) try writer.writeAll(",");
        }
        try writer.writeAll("]");
    } else if (try stringifyValue(allocator, ast, idx)) |v| {
        defer allocator.free(v);
        try writer.writeAll(v);
    } else {
        return error.UnknownType;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const path: ?[]const u8 = blk: {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);
        if (args.len > 1) break :blk try allocator.dupe(u8, args[1]);
        break :blk null;
    };
    defer if (path) |p| allocator.free(p);

    const zon = blk: {
        var file = try std.fs.cwd().openFile(path orelse "build.zig.zon", .{.mode = .read_only});
        defer file.close();
        const buf = try allocator.allocSentinel(u8, try file.getEndPos(), 0);
        _ = try file.reader().readAll(buf);
        break :blk buf;
    };
    defer allocator.free(zon);

    var ast = try std.zig.Ast.parse(allocator, zon, .zon);
    defer ast.deinit(allocator);

    if (ast.errors.len > 0) {
        var writer = std.io.getStdErr().writer();
        for (ast.errors) |e| {
            const loc = ast.tokenLocation(ast.errorOffset(e), e.token);
            try writer.print("error: {s}:{}:{}: ", .{path orelse "build.zig.zon", loc.line, loc.column});
            try ast.renderError(e, writer);
            try writer.writeAll("\n");
        }
        return error.ParseFailed;
    }

    var json = std.ArrayList(u8).init(allocator);
    defer json.deinit();
    try stringify(allocator, json.writer(), ast, ast.nodes.items(.data)[0].lhs, false);
    try std.io.getStdOut().writer().writeAll(json.items);
}
