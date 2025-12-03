const std = @import("std");

pub fn SlidingWindow(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        items: []T,
        indices: []usize,
        count: usize = 0,
        items_pointer: usize = 0,

        pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Self {
            return .{ 
                .allocator = allocator,
                .items   = try allocator.alloc(T, capacity),
                .indices = try allocator.alloc(usize, capacity),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
            self.allocator.free(self.indices);
        }

        pub fn getFromBack(self: *Self, count_from_back: usize) T {
            const index = self.indices[(self.indices.len - 1) - count_from_back];
            return self.items[index];
        }

        pub fn append(self: *Self, item: T) void {
            const index = self.items_pointer;
            self.items[self.items_pointer] = item;
            self.items_pointer += 1;
            self.items_pointer %= self.items.len;

            if (self.count < self.indices.len) {
                self.indices[self.count] = index;
                self.count += 1;

            } else {
                @memmove(self.indices[0..(self.count - 1)], self.indices[1..self.count]);
                self.indices[self.count - 1] = index;
            }
        }
    };
}

test {
    const allocator = std.testing.allocator;
    var s = try SlidingWindow(i32).initCapacity(allocator, 4);
    defer s.deinit();

    s.append(1);
    s.append(2);
    s.append(3);
    s.append(4);

    try std.testing.expectEqual(s.getFromBack(0), 4);
    try std.testing.expectEqual(s.getFromBack(1), 3);
    try std.testing.expectEqual(s.getFromBack(2), 2);
    try std.testing.expectEqual(s.getFromBack(3), 1);

    for (s.indices) |i| {
        std.debug.print("{}, ", .{ s.items[i] });
    }
    std.debug.print("\n", .{ });

    s.append(5);
    s.append(6);

    for (s.indices) |i| {
        std.debug.print("{}, ", .{ s.items[i] });
    }
    std.debug.print("\n", .{ });

    try std.testing.expectEqual(s.getFromBack(0), 6);
    try std.testing.expectEqual(s.getFromBack(1), 5);
    try std.testing.expectEqual(s.getFromBack(2), 4);
    try std.testing.expectEqual(s.getFromBack(3), 3);
}
