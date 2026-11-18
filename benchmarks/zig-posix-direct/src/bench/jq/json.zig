// json object, rfc8259: https://www.rfc-editor.org/info/rfc8259
const std = @import("std");

pub const Value = union(enum) {
    null,
    bool: bool,
    number: f64,
    string: []const u8,
    array: []Value,
    object: []Field,

    pub const Field = struct {
        key: []const u8,
        value: Value,
    };

    pub const PrintOptions = struct {
        color: bool = false,
        pretty: bool = true, // false = compact single-line (jq's -c/tostring)
    };

    pub fn print(self: Value, writer: *std.Io.Writer, options: PrintOptions) std.Io.Writer.Error!void {
        var printer: Printer = .{ .writer = writer, .color = options.color, .pretty = options.pretty };
        try printer.print(self);
    }

    pub fn deepClone(self: Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
        switch (self) {
            .null, .bool, .number => return self,
            .string => |s| return .{ .string = try allocator.dupe(u8, s) },
            .array => |items| {
                const cloned = try allocator.alloc(Value, items.len);
                for (items, 0..) |item, i| cloned[i] = try item.deepClone(allocator);
                return .{ .array = cloned };
            },
            .object => |fields| {
                const cloned = try allocator.alloc(Field, fields.len);
                for (fields, 0..) |field, i| {
                    cloned[i] = .{
                        .key = try allocator.dupe(u8, field.key),
                        .value = try field.value.deepClone(allocator),
                    };
                }
                return .{ .object = cloned };
            },
        }
    }

    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .null, .bool, .number => {},
            .string => |s| allocator.free(s),
            .array => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
            .object => |fields| {
                for (fields) |field| {
                    allocator.free(field.key);
                    field.value.deinit(allocator);
                }
                allocator.free(fields);
            },
        }
    }
};

const Printer = struct {
    writer: *std.Io.Writer,
    color: bool,
    pretty: bool,
    depth: usize = 0,

    const ansi = struct {
        const reset = "\x1b[0m";
        const null_color = "\x1b[1;30m"; // bold black
        const string_color = "\x1b[0;32m"; // green
        const key_color = "\x1b[1;34m"; // bold blue
    };

    fn print(self: *Printer, value: Value) std.Io.Writer.Error!void {
        switch (value) {
            .null => try self.writeColored(ansi.null_color, "null"),
            .bool => |b| try self.writer.print("{}", .{b}),
            .number => |n| try self.writer.print("{d}", .{n}),
            .string => |s| try self.printString(s),
            .array => |items| try self.printArray(items),
            .object => |fields| try self.printObject(fields),
        }
    }

    fn printString(self: *Printer, s: []const u8) std.Io.Writer.Error!void {
        if (self.color) try self.writer.writeAll(ansi.string_color);
        try self.writer.print("\"{s}\"", .{s});
        if (self.color) try self.writer.writeAll(ansi.reset);
    }

    fn printArray(self: *Printer, items: []Value) std.Io.Writer.Error!void {
        if (items.len == 0) {
            try self.writer.writeAll("[]");
            return;
        }
        try self.writer.writeByte('[');
        if (self.pretty) try self.writer.writeByte('\n');
        self.depth += 1;
        for (items, 0..) |item, i| {
            if (self.pretty) try self.writeIndent();
            try self.print(item);
            if (i != items.len - 1) try self.writer.writeByte(',');
            if (self.pretty) try self.writer.writeByte('\n');
        }
        self.depth -= 1;
        if (self.pretty) try self.writeIndent();
        try self.writer.writeByte(']');
    }

    fn printObject(self: *Printer, fields: []Value.Field) std.Io.Writer.Error!void {
        if (fields.len == 0) {
            try self.writer.writeAll("{}");
            return;
        }
        try self.writer.writeByte('{');
        if (self.pretty) try self.writer.writeByte('\n');
        self.depth += 1;
        for (fields, 0..) |field, i| {
            if (self.pretty) try self.writeIndent();
            if (self.color) try self.writer.writeAll(ansi.key_color);
            try self.writer.print("\"{s}\"", .{field.key});
            if (self.color) try self.writer.writeAll(ansi.reset);
            try self.writer.writeAll(if (self.pretty) ": " else ":");
            try self.print(field.value);
            if (i != fields.len - 1) try self.writer.writeByte(',');
            if (self.pretty) try self.writer.writeByte('\n');
        }
        self.depth -= 1;
        if (self.pretty) try self.writeIndent();
        try self.writer.writeByte('}');
    }

    fn writeColored(self: *Printer, code: []const u8, text: []const u8) std.Io.Writer.Error!void {
        if (self.color) try self.writer.writeAll(code);
        try self.writer.writeAll(text);
        if (self.color) try self.writer.writeAll(ansi.reset);
    }

    fn writeIndent(self: *Printer) std.Io.Writer.Error!void {
        for (0..self.depth * 2) |_| try self.writer.writeByte(' ');
    }
};
