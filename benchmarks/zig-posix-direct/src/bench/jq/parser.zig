const std = @import("std");
const json = @import("json.zig");

pub const ParseError = error{
    UnexpectedEnd,
    UnexpectedCharacter,
    NotImplemented,
} || std.mem.Allocator.Error;

pub fn parse(out: std.mem.Allocator, temp: std.mem.Allocator, input: []const u8) ParseError!json.Value {
    var parser = Parser{ .input = input, .pos = 0, .temp = temp };
    const value = try parser.parseJsonText();
    return value.deepClone(out);
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

    fn skipWhitespace(self: *Parser) void {
        while (self.peek()) |c| {
            switch (c) {
                ' ', '\t', '\n', '\r' => self.advance(),
                else => break,
            }
        }
    }

    fn expectLiteral(self: *Parser, literal: []const u8) ParseError!void {
        if (self.input.len - self.pos < literal.len) return ParseError.UnexpectedEnd;
        if (!std.mem.eql(u8, self.input[self.pos..][0..literal.len], literal)) {
            return ParseError.UnexpectedCharacter;
        }
        self.pos += literal.len;
    }

    fn parseJsonText(self: *Parser) ParseError!json.Value {
        const value = try self.parseValue();
        self.skipWhitespace();
        if (self.pos != self.input.len) return ParseError.UnexpectedCharacter;
        return value;
    }

    fn parseValue(self: *Parser) ParseError!json.Value {
        self.skipWhitespace();
        const c = self.peek() orelse return ParseError.UnexpectedEnd;
        return switch (c) {
            'n' => self.parseNull(),
            't', 'f' => self.parseBool(),
            '0'...'9', '-' => self.parseNumber(),
            '"' => self.parseString(),
            '[' => self.parseArray(),
            '{' => self.parseObject(),
            else => ParseError.UnexpectedCharacter,
        };
    }

    fn parseNull(self: *Parser) ParseError!json.Value {
        try self.expectLiteral("null");
        return .null;
    }

    fn parseBool(self: *Parser) ParseError!json.Value {
        if (self.peek() == 't') {
            try self.expectLiteral("true");
            return .{ .bool = true };
        }
        try self.expectLiteral("false");
        return .{ .bool = false };
    }

    fn parseNumber(self: *Parser) ParseError!json.Value {
        const start = self.pos;

        if (self.peek() == '-') self.advance();

        const first_digit = self.peek() orelse return ParseError.UnexpectedEnd;
        if (!std.ascii.isDigit(first_digit)) return ParseError.UnexpectedCharacter;
        while (self.peek()) |c| : (self.advance()) {
            if (!std.ascii.isDigit(c)) break;
        }

        if (self.peek() == '.') {
            self.advance();
            while (self.peek()) |c| : (self.advance()) {
                if (!std.ascii.isDigit(c)) break;
            }
        }

        if (self.peek() == 'e' or self.peek() == 'E') {
            self.advance();
            if (self.peek() == '+' or self.peek() == '-') self.advance();
            while (self.peek()) |c| : (self.advance()) {
                if (!std.ascii.isDigit(c)) break;
            }
        }

        const text = self.input[start..self.pos];
        const value = std.fmt.parseFloat(f64, text) catch return ParseError.UnexpectedCharacter;
        return .{ .number = value };
    }

    fn parseString(self: *Parser) ParseError!json.Value {
        return .{ .string = try self.parseStringBytes() };
    }

    fn parseStringBytes(self: *Parser) ParseError![]u8 {
        self.advance(); // consume opening quotation-mark

        var buf: std.ArrayList(u8) = .empty;

        while (true) {
            const c = self.peek() orelse return ParseError.UnexpectedEnd;
            switch (c) {
                '"' => {
                    self.advance();
                    return buf.toOwnedSlice(self.temp);
                },
                '\\' => {
                    self.advance();
                    try self.parseEscape(&buf);
                },
                0x00...0x1F => return ParseError.UnexpectedCharacter,
                else => {
                    try buf.append(self.temp, c);
                    self.advance();
                },
            }
        }
    }

    fn parseEscape(self: *Parser, buf: *std.ArrayList(u8)) ParseError!void {
        const esc = self.peek() orelse return ParseError.UnexpectedEnd;
        switch (esc) {
            '"', '\\', '/' => {
                try buf.append(self.temp, esc);
                self.advance();
            },
            'b' => {
                try buf.append(self.temp, 0x08);
                self.advance();
            },
            'f' => {
                try buf.append(self.temp, 0x0C);
                self.advance();
            },
            'n' => {
                try buf.append(self.temp, '\n');
                self.advance();
            },
            'r' => {
                try buf.append(self.temp, '\r');
                self.advance();
            },
            't' => {
                try buf.append(self.temp, '\t');
                self.advance();
            },
            'u' => {
                self.advance();
                const codepoint = try self.parseUnicodeEscape();
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return ParseError.UnexpectedCharacter;
                try buf.appendSlice(self.temp, utf8_buf[0..len]);
            },
            else => return ParseError.UnexpectedCharacter,
        }
    }

    fn parseHex4(self: *Parser) ParseError!u16 {
        if (self.input.len - self.pos < 4) return ParseError.UnexpectedEnd;
        const hex = self.input[self.pos..][0..4];
        const value = std.fmt.parseInt(u16, hex, 16) catch return ParseError.UnexpectedCharacter;
        self.pos += 4;
        return value;
    }

    fn parseUnicodeEscape(self: *Parser) ParseError!u21 {
        const first = try self.parseHex4();

        if (first >= 0xD800 and first <= 0xDBFF) {
            try self.expectLiteral("\\u");
            const second = try self.parseHex4();
            if (second < 0xDC00 or second > 0xDFFF) return ParseError.UnexpectedCharacter;

            const pair = [_]u16{ first, second };
            return std.unicode.utf16DecodeSurrogatePair(&pair) catch ParseError.UnexpectedCharacter;
        }

        if (first >= 0xDC00 and first <= 0xDFFF) {
            return ParseError.UnexpectedCharacter;
        }

        return first;
    }

    fn parseArray(self: *Parser) ParseError!json.Value {
        self.advance(); // consume '['
        self.skipWhitespace();

        var items: std.ArrayList(json.Value) = .empty;

        if (self.peek() == ']') {
            self.advance();
            return .{ .array = try items.toOwnedSlice(self.temp) };
        }

        while (true) {
            const value = try self.parseValue();
            try items.append(self.temp, value);

            self.skipWhitespace();
            const c = self.peek() orelse return ParseError.UnexpectedEnd;
            switch (c) {
                ',' => self.advance(),
                ']' => {
                    self.advance();
                    return .{ .array = try items.toOwnedSlice(self.temp) };
                },
                else => return ParseError.UnexpectedCharacter,
            }
        }
    }

    fn parseObject(self: *Parser) ParseError!json.Value {
        self.advance(); // consume '{'
        self.skipWhitespace();

        var fields: std.ArrayList(json.Value.Field) = .empty;

        if (self.peek() == '}') {
            self.advance();
            return .{ .object = try fields.toOwnedSlice(self.temp) };
        }

        while (true) {
            self.skipWhitespace();
            if (self.peek() != '"') return ParseError.UnexpectedCharacter;

            const key = try self.parseStringBytes();
            self.skipWhitespace();
            if (self.peek() != ':') return ParseError.UnexpectedCharacter;
            self.advance();

            const value = try self.parseValue();
            try fields.append(self.temp, .{ .key = key, .value = value });

            self.skipWhitespace();
            const c = self.peek() orelse return ParseError.UnexpectedEnd;
            switch (c) {
                ',' => self.advance(),
                '}' => {
                    self.advance();
                    return .{ .object = try fields.toOwnedSlice(self.temp) };
                },
                else => return ParseError.UnexpectedCharacter,
            }
        }
    }
};
