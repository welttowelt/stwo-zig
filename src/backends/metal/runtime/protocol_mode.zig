//! Supported Merkle domain encodings shared by commitment operations.

const std = @import("std");

const plain_domain_prefix_bytes: u32 = 0;
const prefixed_domain_prefix_bytes: u32 = 64;

pub fn validDomainPrefixBytes(value: u32) bool {
    return value == plain_domain_prefix_bytes or value == prefixed_domain_prefix_bytes;
}

test "Metal lifted Merkle protocol mode accepts only supported encodings" {
    try std.testing.expect(validDomainPrefixBytes(plain_domain_prefix_bytes));
    try std.testing.expect(validDomainPrefixBytes(prefixed_domain_prefix_bytes));
    try std.testing.expect(!validDomainPrefixBytes(1));
    try std.testing.expect(!validDomainPrefixBytes(63));
    try std.testing.expect(!validDomainPrefixBytes(65));
}
