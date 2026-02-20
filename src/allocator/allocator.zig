const std = @import("std");

var kernel_memory: [1024 * 1024 * 1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&kernel_memory);
pub const global_alloc = fba.allocator();
