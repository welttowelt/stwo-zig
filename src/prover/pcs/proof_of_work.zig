//! Prover-side proof-of-work nonce search policy.

pub fn grind(channel: anytype, pow_bits: u32) u64 {
    // Prefer a channel's cached or parallel implementation when it provides one.
    if (@hasDecl(@TypeOf(channel.*), "grind")) {
        return channel.grind(pow_bits);
    }

    var nonce: u64 = 0;
    while (true) : (nonce += 1) {
        if (channel.verifyPowNonce(pow_bits, nonce)) return nonce;
    }
}
