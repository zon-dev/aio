//! Constants are the configuration that the code actually imports — they include:
//! - all of the configuration values (flattened)
//! - derived configuration values,

const std = @import("std");
const assert = std.debug.assert;
// const vsr = @import("vsr.zig");
// const Config = @import("config.zig").Config;
const stdx = @import("stdx.zig");

// pub const config = @import("config.zig").configs.current;

// pub const semver = std.SemanticVersion{
//     .major = config.process.release.triple().major,
//     .minor = config.process.release.triple().minor,
//     .patch = config.process.release.triple().patch,
//     .pre = null,
//     .build = if (config.process.git_commit) |sha_full| sha_full[0..7] else null,
// };

/// The maximum log level.
/// One of: .err, .warn, .info, .debug
// pub const log_level: std.log.Level = config.process.log_level;

pub const log = std.log.defaultLog;

/// A log function that discards all log entries.
pub fn log_nop(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = .{
        message_level,
        scope,
        format,
        args,
    };
}

// Which mode to use for ./testing/hash_log.zig.
// pub const hash_log_mode = config.process.hash_log_mode;

/// The maximum number of replicas allowed in a cluster.
pub const replicas_max = 6;
/// The maximum number of standbys allowed in a cluster.
pub const standbys_max = 6;
/// The maximum number of cluster members (either standbys or active replicas).
pub const members_max = replicas_max + standbys_max;

/// All operations <vsr_operations_reserved are reserved for the control protocol.
/// All operations ≥vsr_operations_reserved are available for the state machine.
pub const vsr_operations_reserved: u8 = 128;

/// The maximum number of outgoing messages that may be queued on a client connection.
/// The client has one in-flight request, and occasionally a ping.
pub const connection_send_queue_max_client = 2;

// Limits for the number of value blocks that a single compaction can queue up for IO and for the
// number of IO operations themselves. The number of index blocks is always one per level.
// This is a comptime upper bound. The actual number of concurrency is also limited by the
// runtime-know number of free blocks.
//
// For simplicity for now, size IOPS to always be available.
pub const lsm_compaction_queue_read_max = 8;
pub const lsm_compaction_queue_write_max = 8;
pub const lsm_compaction_iops_read_max = lsm_compaction_queue_read_max + 2; // + two index blocks.
pub const lsm_compaction_iops_write_max = lsm_compaction_queue_write_max + 1; // + one index block.

/// TigerBeetle uses asserts proactively, unless they severely degrade performance. For production,
/// 5% slow down might be deemed critical, tests tolerate slowdowns up to 5x. Tests should be
/// reasonably fast to make deterministic simulation effective. `constants.verify` disambiguate the
/// two cases.
///
/// In the control plane (eg, vsr proper) assert unconditionally. Due to batching, control plane
/// overhead is negligible. It is acceptable to spend O(N) time to verify O(1) computation.
///
/// In the data plane (eg, lsm tree), finer grained judgement is required. Do an unconditional O(1)
/// assert before an O(N) loop (e.g, a bounds check). Inside the loop, it might or might not be
/// feasible to add an extra assert per iteration. In the latter case, guard the assert with `if
/// (constants.verify)`, but prefer an unconditional assert unless benchmarks prove it to be costly.
///
/// In the data plane, never use O(N) asserts for O(1) computations --- due to do randomized testing
/// the overall coverage is proportional to the number of tests run. Slow thorough assertions
/// decrease the overall test coverage.
///
/// Specific data structures might use a comptime parameter, to enable extra costly verification
/// only during unit tests of the data structure.
// pub const verify = config.process.verify;
pub const verify = true;
