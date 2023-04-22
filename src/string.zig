const std = @import("std");
const t = @import("t.zig");

const v = @import("validate.zig");
const codes = @import("codes.zig");
const Builder = @import("builder.zig").Builder;
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

const json = std.json;
const Allocator = std.mem.Allocator;

const INVALID_TYPE = v.Invalid{
	.code = codes.TYPE_STRING,
	.err = "must be a string",
};

pub fn String(comptime S: type) type {
	return struct {
		required: bool,
		min: ?usize,
		max: ?usize,
		choices: ?[][]const u8 = null,
		function: ?*const fn(value: ?[]const u8, context: *Context(S)) anyerror!?[]const u8,
		invalid_min: ?v.Invalid,
		invalid_max: ?v.Invalid,
		invalid_choices: ?v.Invalid,

		const Self = @This();

		pub const Config = struct {
			min: ?usize = null,
			max: ?usize = null,
			required: bool = false,
			choices: ?[][]const u8 = null,
			function: ?*const fn(value: ?[]const u8, context: *Context(S)) anyerror!?[]const u8 = null,
		};

		pub fn init(allocator: Allocator, config: Config) !Self {
			var invalid_min: ?v.Invalid = null;
			if (config.min) |m| {
				const plural = if (m == 1) "" else "s";
				invalid_min = v.Invalid{
					.code = codes.STRING_LEN_MIN,
					.data = .{.imin = .{.min = @intCast(i64, m) }},
					.err = try std.fmt.allocPrint(allocator, "must have at least {d} character{s}", .{m, plural}),
				};
			}

			var invalid_max: ?v.Invalid = null;
			if (config.max) |m| {
				const plural = if (m == 1) "" else "s";
				invalid_max = v.Invalid{
					.code = codes.STRING_LEN_MAX,
					.data = .{.imax = .{.max = @intCast(i64, m) }},
					.err = try std.fmt.allocPrint(allocator, "must have no more than {d} character{s}", .{m, plural}),
				};
			}

			var invalid_choices: ?v.Invalid = null;
			if (config.choices) |choices| {
				const choice_list = try std.mem.join(allocator, ", ", choices);
				invalid_choices = v.Invalid{
					.code = codes.STRING_CHOICE,
					.data = .{.choice = .{.valid = choices}},
					.err = try std.fmt.allocPrint(allocator, "must be one of: {s}", .{choice_list}),
				};
			}

			return .{
				.min = config.min,
				.max = config.max,
				.choices = config.choices,
				.required = config.required,
				.function = config.function,
				.invalid_min = invalid_min,
				.invalid_max = invalid_max,
				.invalid_choices = invalid_choices,
			};
		}

		pub fn validator(self: *const Self) Validator(S) {
			return Validator(S).init(self);
		}

		// part of the Validator interface, but noop for strings
		pub fn nestField(_: *const Self, _: Allocator, _: *v.Field(S)) !void {}

		pub fn validateJsonValue(self: *const Self, input: ?json.Value, context: *Context(S)) !?json.Value {
			const untyped_value = input orelse {
				if (self.required) {
					try context.add(v.required);
				}
				return self.executeFunction(null, context);
			};

			const value = switch (untyped_value) {
				.String => |s| s,
				else => {
					try context.add(INVALID_TYPE);
					return null;
				}
			};

			if (self.min) |m| {
				std.debug.assert(self.invalid_min != null);
				if (value.len < m) {
					try context.add(self.invalid_min.?);
					return null;
				}
			}

			if (self.max) |m| {
				std.debug.assert(self.invalid_max != null);
				if (value.len > m) {
					try context.add(self.invalid_max.?);
					return null;
				}
			}

			choice_blk: {
				if (self.choices) |choices| {
					std.debug.assert(self.invalid_choices != null);
					for (choices) |choice| {
						if (std.mem.eql(u8, choice, value)) break :choice_blk;
					}
					try context.add(self.invalid_choices.?);
					return null;
				}
			}

			return self.executeFunction(value, context);
		}

		fn executeFunction(self: *const Self, value: ?[]const u8, context: *Context(S)) !?json.Value {
			if (self.function) |f| {
				const transformed = try f(value, context) orelse return null;
				return json.Value{.String = transformed};
			}
			return null;
		}
	};
}

const nullJson = @as(?json.Value, null);
test "string: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	{
		const validator = try builder.string(.{.required = true});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		t.reset(&context);
		const validator = try builder.string(.{.required = false});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "string: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = try builder.string(.{});
	try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Integer = 33}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_STRING}, context);
}

test "string: min length" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = try builder.string(.{.min = 4});
	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "abc"}, &context));
		try t.expectInvalid(.{.code = codes.STRING_LEN_MIN, .data_min = 4, .err = "must have at least 4 characters"}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "abcd"}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "abcde"}, &context));
		try t.expectEqual(true, context.isValid());
	}

	const singular = try builder.string(.{.min = 1});
	{
		try t.expectEqual(nullJson, try singular.validateJsonValue(.{.String = ""}, &context));
		try t.expectInvalid(.{.code = codes.STRING_LEN_MIN, .data_min = 1, .err = "must have at least 1 character"}, context);
	}
}

test "string: max length" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = try builder.string(.{.max = 4});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "abcde"}, &context));
		try t.expectInvalid(.{.code = codes.STRING_LEN_MAX, .data_max = 4, .err = "must have no more than 4 characters"}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "abcd"}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "abc"}, &context));
		try t.expectEqual(true, context.isValid());
	}

	const singular = try builder.string(.{.max = 1});
	{
		try t.expectEqual(nullJson, try singular.validateJsonValue(.{.String = "123"}, &context));
		try t.expectInvalid(.{.code = codes.STRING_LEN_MAX, .data_max = 1, .err = "must have no more than 1 character"}, context);
	}
}

test "string: choices" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	var choices = [_][]const u8{"one", "two", "three"};
	const validator = try builder.string(.{.choices = &choices});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "nope"}, &context));
		try t.expectInvalid(.{.code = codes.STRING_CHOICE}, context);
	}

	for (choices) |choice| {
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = choice}, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "string: function" {
	var context = try Context(i64).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, 101);
	defer context.deinit(t.allocator);

	const builder = try Builder(i64).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = try builder.string(.{.function = testStringValidator});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "ok"}, &context));
		try t.expectEqual(true, context.isValid());
	}


	{
		try t.expectString("is-null", (try validator.validateJsonValue(null, &context)).?.String);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectString("19", (try validator.validateJsonValue(.{.String = "change"}, &context)).?.String);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "fail"}, &context));
		try t.expectInvalid(.{.code = 999, .err = "string validation error"}, context);
	}
}

fn testStringValidator(value: ?[]const u8, context: *Context(i64)) !?[]const u8 {
	std.debug.assert(context.state == 101);

	const s = value orelse return "is-null";

	if (std.mem.eql(u8, s, "change")) {
		// test the arena allocator while we're here
		var alt = try context.allocator.alloc(u8, 2);
		alt[0] = '1';
		alt[1] = '9';
		return alt;
	}

	if (std.mem.eql(u8, s, "fail")) {
		try context.add(v.Invalid{
			.code = 999,
			.err = "string validation error",
		});
		return null;
	}

	return null;
}

