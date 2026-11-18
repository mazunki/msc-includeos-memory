// a jq like query language
const std = @import("std");
const json = @import("json.zig");

pub const Segment = union(enum) {
    field: []const u8,
    index: usize,
    iterate, // .[]
};

pub const Stage = union(enum) {
    path: []const Segment,
    length,
    keys,
    tostring,
    join: []const u8,
    map: []const Stage,

    pub fn deinit(self: Stage, allocator: std.mem.Allocator) void {
        switch (self) {
            .path => |segments| allocator.free(segments),
            .join => |sep| allocator.free(sep),
            .map => |substages| freeStages(allocator, substages),
            .length, .keys, .tostring => {},
        }
    }
};

fn freeStages(allocator: std.mem.Allocator, stages: []const Stage) void {
    for (stages) |stage| stage.deinit(allocator);
    allocator.free(stages);
}

pub const Query = struct {
    stages: []const Stage,

    pub fn deinit(self: Query, allocator: std.mem.Allocator) void {
        freeStages(allocator, self.stages);
    }
};

pub const ParseError = error{
    UnexpectedEnd,
    UnexpectedCharacter,
    UnknownFunction,
} || std.mem.Allocator.Error;

pub const ApplyError = error{
    KeyNotFound,
    IndexOutOfBounds,
    NotAnObject,
    NotAnArray,
    NotIterable,
    BooleanHasNoLength,
    HasNoKeys,
    InvalidUtf8,
} || std.mem.Allocator.Error || std.Io.Writer.Error;

pub fn parse(temp: std.mem.Allocator, input: []const u8) ParseError!Query {
    var parser = Parser{ .input = input, .pos = 0, .temp = temp };
    return parser.parsePipeline();
}

pub fn apply(
    out: std.mem.Allocator,
    temp: std.mem.Allocator,
    query: Query,
    value: json.Value,
) ApplyError![]json.Value {
    const app = Application{ .temp = temp };

    var current: []const json.Value = &.{value};
    for (query.stages) |stage| {
        current = try app.applyStage(stage, current);
    }

    const final = try out.alloc(json.Value, current.len);
    for (current, 0..) |v, i| final[i] = try v.deepClone(out);
    return final;
}

const Application = struct {
    temp: std.mem.Allocator,

    fn applyStage(self: Application, stage: Stage, values: []const json.Value) ApplyError![]const json.Value {
        switch (stage) {
            .path => |segments| return self.applyPath(segments, values),
            .length => {
                const result = try self.temp.alloc(json.Value, values.len);
                for (values, 0..) |v, i| result[i] = try applyLength(v);
                return result;
            },
            .keys => {
                const result = try self.temp.alloc(json.Value, values.len);
                for (values, 0..) |v, i| result[i] = try self.applyKeys(v);
                return result;
            },
            .tostring => {
                const result = try self.temp.alloc(json.Value, values.len);
                for (values, 0..) |v, i| result[i] = try self.applyToString(v);
                return result;
            },
            .join => |sep| {
                const result = try self.temp.alloc(json.Value, values.len);
                for (values, 0..) |v, i| result[i] = try self.applyJoin(v, sep);
                return result;
            },
            .map => |substages| {
                const result = try self.temp.alloc(json.Value, values.len);
                for (values, 0..) |v, i| result[i] = try self.applyMap(substages, v);
                return result;
            },
        }
    }

    fn applyMap(self: Application, substages: []const Stage, value: json.Value) ApplyError!json.Value {
        if (value != .array) return ApplyError.NotAnArray;

        const sub_query = Query{ .stages = substages };
        var result: std.ArrayList(json.Value) = .empty;

        for (value.array) |item| {
            const stream = try apply(self.temp, self.temp, sub_query, item);
            try result.appendSlice(self.temp, stream);
        }

        return .{ .array = try result.toOwnedSlice(self.temp) };
    }

    fn applyPath(self: Application, segments: []const Segment, values: []const json.Value) ApplyError![]const json.Value {
        var current = values;

        for (segments) |segment| {
            var next: std.ArrayList(json.Value) = .empty;

            switch (segment) {
                .field => |name| {
                    for (current) |v| try next.append(self.temp, try applyField(v, name));
                },
                .index => |index| {
                    for (current) |v| try next.append(self.temp, try applyIndex(v, index));
                },
                .iterate => {
                    for (current) |v| {
                        switch (v) {
                            .array => |items| try next.appendSlice(self.temp, items),
                            .object => |fields| {
                                for (fields) |field| try next.append(self.temp, field.value);
                            },
                            else => return ApplyError.NotIterable,
                        }
                    }
                },
            }

            current = try next.toOwnedSlice(self.temp);
        }

        return current;
    }

    fn applyKeys(self: Application, value: json.Value) ApplyError!json.Value {
        switch (value) {
            .object => |fields| {
                const keys = try self.temp.alloc(json.Value, fields.len);
                for (fields, 0..) |field, i| {
                    keys[i] = .{ .string = try self.temp.dupe(u8, field.key) };
                }
                std.mem.sort(json.Value, keys, {}, struct {
                    fn lessThan(_: void, a: json.Value, b: json.Value) bool {
                        return std.mem.lessThan(u8, a.string, b.string);
                    }
                }.lessThan);
                return .{ .array = keys };
            },
            .array => |items| {
                const keys = try self.temp.alloc(json.Value, items.len);
                for (0..items.len) |i| keys[i] = .{ .number = @floatFromInt(i) };
                return .{ .array = keys };
            },
            else => return ApplyError.HasNoKeys,
        }
    }

    fn applyToString(self: Application, value: json.Value) ApplyError!json.Value {
        if (value == .string) return .{ .string = try self.temp.dupe(u8, value.string) };

        var buf: std.Io.Writer.Allocating = .init(self.temp);
        defer buf.deinit();
        try value.print(&buf.writer, .{ .pretty = false });
        return .{ .string = try buf.toOwnedSlice() };
    }

    fn applyJoin(self: Application, value: json.Value, sep: []const u8) ApplyError!json.Value {
        if (value != .array) return ApplyError.NotAnArray;

        var buf: std.Io.Writer.Allocating = .init(self.temp);
        defer buf.deinit();

        for (value.array, 0..) |item, i| {
            if (i != 0) try buf.writer.writeAll(sep);
            switch (item) {
                .null => {},
                .string => |s| try buf.writer.writeAll(s),
                else => try item.print(&buf.writer, .{ .pretty = false }),
            }
        }

        return .{ .string = try buf.toOwnedSlice() };
    }
};

fn applyField(value: json.Value, name: []const u8) ApplyError!json.Value {
    if (value != .object) return ApplyError.NotAnObject;
    for (value.object) |field| {
        if (std.mem.eql(u8, field.key, name)) return field.value;
    }
    return ApplyError.KeyNotFound;
}

fn applyIndex(value: json.Value, index: usize) ApplyError!json.Value {
    if (value != .array) return ApplyError.NotAnArray;
    if (index >= value.array.len) return ApplyError.IndexOutOfBounds;
    return value.array[index];
}

fn applyLength(value: json.Value) ApplyError!json.Value {
    const n: f64 = switch (value) {
        .null => 0,
        .bool => return ApplyError.BooleanHasNoLength,
        .number => |num| @abs(num),
        .string => |s| blk: {
            const count = std.unicode.utf8CountCodepoints(s) catch return ApplyError.InvalidUtf8;
            break :blk @floatFromInt(count);
        },
        .array => |items| @floatFromInt(items.len),
        .object => |fields| @floatFromInt(fields.len),
    };
    return .{ .number = n };
}

const Parser = struct {
    input: []const u8,
    pos: usize,
    temp: std.mem.Allocator,

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn advance(self: *Parser) void {
        self.pos += 1;
    }

    fn expect(self: *Parser, expected: u8) ParseError!void {
        const c = self.peek() orelse return ParseError.UnexpectedEnd;
        if (c != expected) return ParseError.UnexpectedCharacter;
        self.advance();
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.peek()) |c| {
            switch (c) {
                ' ', '\t', '\n', '\r' => self.advance(),
                else => break,
            }
        }
    }

    fn parsePipeline(self: *Parser) ParseError!Query {
        const stages = try self.parseStages();
        if (self.pos != self.input.len) return ParseError.UnexpectedCharacter;
        return .{ .stages = stages };
    }

    fn parseStages(self: *Parser) ParseError![]const Stage {
        var stages: std.ArrayList(Stage) = .empty;

        try stages.append(self.temp, try self.parseStage());

        self.skipWhitespace();
        while (self.peek() == '|') {
            self.advance();
            self.skipWhitespace();
            try stages.append(self.temp, try self.parseStage());
            self.skipWhitespace();
        }

        return try stages.toOwnedSlice(self.temp);
    }

    fn parseStage(self: *Parser) ParseError!Stage {
        const c = self.peek() orelse return ParseError.UnexpectedEnd;
        if (c == '.') return .{ .path = try self.parsePath() };
        if (isIdentifierStart(c)) return self.parseFuncall();
        return ParseError.UnexpectedCharacter;
    }

    fn parseFuncall(self: *Parser) ParseError!Stage {
        const name = try self.parseIdentifier();
        if (std.mem.eql(u8, name, "length")) return .length;
        if (std.mem.eql(u8, name, "keys")) return .keys;
        if (std.mem.eql(u8, name, "tostring")) return .tostring;
        if (std.mem.eql(u8, name, "join")) {
            try self.expect('(');
            self.skipWhitespace();
            const sep = try self.parseStringLiteral();
            self.skipWhitespace();
            try self.expect(')');
            return .{ .join = sep };
        }
        if (std.mem.eql(u8, name, "map")) {
            try self.expect('(');
            self.skipWhitespace();
            const substages = try self.parseStages();
            self.skipWhitespace();
            try self.expect(')');
            return .{ .map = substages };
        }
        return ParseError.UnknownFunction;
    }

    fn parseStringLiteral(self: *Parser) ParseError![]const u8 {
        try self.expect('"');

        var buf: std.ArrayList(u8) = .empty;

        while (true) {
            const c = self.peek() orelse return ParseError.UnexpectedEnd;
            switch (c) {
                '"' => {
                    self.advance();
                    return try buf.toOwnedSlice(self.temp);
                },
                '\\' => {
                    self.advance();
                    const esc = self.peek() orelse return ParseError.UnexpectedEnd;
                    const decoded: u8 = switch (esc) {
                        '"' => '"',
                        '\\' => '\\',
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        else => return ParseError.UnexpectedCharacter,
                    };
                    try buf.append(self.temp, decoded);
                    self.advance();
                },
                else => {
                    try buf.append(self.temp, c);
                    self.advance();
                },
            }
        }
    }

    fn parsePath(self: *Parser) ParseError![]const Segment {
        try self.expect('.');

        var segments: std.ArrayList(Segment) = .empty;

        if (self.peek()) |c| {
            if (isIdentifierStart(c)) {
                const name = try self.parseIdentifier();
                try segments.append(self.temp, .{ .field = name });
            } else if (c == '[') {
                try segments.append(self.temp, try self.parseBracket());
            }
        }

        while (self.peek()) |c| {
            switch (c) {
                '.' => {
                    self.advance();
                    const name = try self.parseIdentifier();
                    try segments.append(self.temp, .{ .field = name });
                },
                '[' => try segments.append(self.temp, try self.parseBracket()),
                else => break,
            }
        }

        return try segments.toOwnedSlice(self.temp);
    }

    fn parseBracket(self: *Parser) ParseError!Segment {
        self.advance(); // consume '['
        if (self.peek() == ']') {
            self.advance();
            return .iterate;
        }
        const index = try self.parseIndex();
        try self.expect(']');
        return .{ .index = index };
    }

    fn isIdentifierStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }

    fn isIdentifierContinue(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn parseIdentifier(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        const first = self.peek() orelse return ParseError.UnexpectedEnd;
        if (!isIdentifierStart(first)) return ParseError.UnexpectedCharacter;
        self.advance();
        while (self.peek()) |c| : (self.advance()) {
            if (!isIdentifierContinue(c)) break;
        }
        return self.input[start..self.pos];
    }

    fn parseIndex(self: *Parser) ParseError!usize {
        const start = self.pos;
        const first = self.peek() orelse return ParseError.UnexpectedEnd;
        if (!std.ascii.isDigit(first)) return ParseError.UnexpectedCharacter;
        while (self.peek()) |c| : (self.advance()) {
            if (!std.ascii.isDigit(c)) break;
        }
        return std.fmt.parseInt(usize, self.input[start..self.pos], 10) catch ParseError.UnexpectedCharacter;
    }
};
