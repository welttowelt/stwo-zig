use stwo::core::circle::{CirclePoint, M31_CIRCLE_LOG_ORDER, SECURE_FIELD_CIRCLE_GEN};
use stwo::core::fields::cm31::CM31;
use stwo::core::fields::m31::{M31, P};
use stwo::core::fields::qm31::QM31;
use stwo::core::fields::ComplexConjugate;
use stwo::core::pcs::quotients::PointSample;
use stwo::core::vcs::blake2_hash::Blake2sHash;
use stwo::core::vcs::blake3_hash::Blake3Hash;

use crate::model::PointSampleVector;

pub(crate) fn encode_point_sample(sample: &PointSample) -> PointSampleVector {
    PointSampleVector {
        point: encode_secure_circle_point(sample.point),
        value: encode_qm31(sample.value),
    }
}

pub(crate) fn encode_m31(x: M31) -> u32 {
    x.0
}

pub(crate) fn encode_state(state: [M31; 2]) -> [u32; 2] {
    [encode_m31(state[0]), encode_m31(state[1])]
}

pub(crate) fn combine_state(state: [M31; 2], z: QM31, alpha: QM31) -> QM31 {
    QM31::from(state[0]) + alpha * QM31::from(state[1]) - z
}

pub(crate) fn encode_hash(x: Blake2sHash) -> [u8; 32] {
    x.0
}

pub(crate) fn encode_blake3_hash(x: Blake3Hash) -> [u8; 32] {
    x.as_ref()
        .try_into()
        .expect("blake3 hash should be 32 bytes")
}

pub(crate) fn encode_cm31(x: CM31) -> [u32; 2] {
    [x.0 .0, x.1 .0]
}

pub(crate) fn encode_qm31(x: QM31) -> [u32; 4] {
    [x.0 .0 .0, x.0 .1 .0, x.1 .0 .0, x.1 .1 .0]
}

pub(crate) fn encode_circle_point(p: CirclePoint<M31>) -> [u32; 2] {
    [p.x.0, p.y.0]
}

pub(crate) fn encode_secure_circle_point(p: CirclePoint<QM31>) -> [[u32; 4]; 2] {
    [encode_qm31(p.x), encode_qm31(p.y)]
}

pub(crate) fn sample_scalar(state: &mut u64) -> u64 {
    next_u64(state) & ((1u64 << M31_CIRCLE_LOG_ORDER) - 1)
}

pub(crate) fn sample_scalar_u128(state: &mut u64) -> u128 {
    ((next_u64(state) as u128) << 64) | (next_u64(state) as u128)
}

pub(crate) fn sample_hash(state: &mut u64) -> Blake2sHash {
    let mut bytes = [0u8; 32];
    fill_bytes(state, &mut bytes);
    Blake2sHash(bytes)
}

pub(crate) fn fill_bytes(state: &mut u64, bytes: &mut [u8]) {
    for chunk in bytes.chunks_mut(8) {
        let block = next_u64(state).to_le_bytes();
        let n = chunk.len();
        chunk.copy_from_slice(&block[..n]);
    }
}

pub(crate) fn sample_m31(state: &mut u64, non_zero: bool) -> M31 {
    loop {
        let candidate = (next_u64(state) as u32) & 0x7fff_ffff;
        if candidate == P {
            continue;
        }
        if non_zero && candidate == 0 {
            continue;
        }
        return M31::from_u32_unchecked(candidate);
    }
}

pub(crate) fn sample_cm31(state: &mut u64, non_zero: bool) -> CM31 {
    loop {
        let out = CM31(sample_m31(state, false), sample_m31(state, false));
        if non_zero && out.0 .0 == 0 && out.1 .0 == 0 {
            continue;
        }
        return out;
    }
}

pub(crate) fn sample_qm31(state: &mut u64, non_zero: bool) -> QM31 {
    loop {
        let out = QM31(
            CM31(sample_m31(state, false), sample_m31(state, false)),
            CM31(sample_m31(state, false), sample_m31(state, false)),
        );
        if non_zero && encode_qm31(out) == [0, 0, 0, 0] {
            continue;
        }
        return out;
    }
}

pub(crate) fn sample_secure_point_non_degenerate(state: &mut u64) -> CirclePoint<QM31> {
    loop {
        let point = SECURE_FIELD_CIRCLE_GEN.mul(sample_scalar_u128(state));
        if point.y != point.y.complex_conjugate() {
            return point;
        }
    }
}

pub(crate) fn next_u64(state: &mut u64) -> u64 {
    // Xorshift64* (deterministic, non-cryptographic).
    let mut x = *state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    *state = x;
    x.wrapping_mul(0x2545_f491_4f6c_dd1d)
}
