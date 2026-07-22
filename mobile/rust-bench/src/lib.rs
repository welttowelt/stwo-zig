//! C-ABI mobile bench around the reference Rust stwo prover.
//!
//! Same contract as the Zig shim (mobile/README.md):
//!   stwo_mobile_bench("--workload plonk --log-n-rows 12 --samples 3 --warmups 1")
//! returns NUL-terminated JSON (schema mobile-proof-rust-v1) or an
//! `error: …` string; release it with stwo_mobile_bench_free. Proof bytes
//! are the canonical wire JSON, so their sha256 digests are comparable to
//! the parity oracle's.

use sha2::{Digest, Sha256};
use std::ffi::{c_char, CStr, CString};

// The zig harness's "functional" protocol parameters.
const POW_BITS: u32 = 10;
const LOG_LAST_LAYER: u32 = 0;
const LOG_BLOWUP: u32 = 1;
const N_QUERIES: usize = 3;

#[no_mangle]
pub extern "C" fn stwo_mobile_bench(arg_line: *const c_char) -> *mut c_char {
    let line = unsafe { CStr::from_ptr(arg_line) }.to_string_lossy();
    let out = match bench(&line) {
        Ok(json) => json,
        Err(err) => format!("error: {err:#}"),
    };
    CString::new(out)
        .unwrap_or_else(|_| CString::new("error: interior NUL").unwrap())
        .into_raw()
}

/// # Safety
/// `ptr` must come from `stwo_mobile_bench`.
#[no_mangle]
pub unsafe extern "C" fn stwo_mobile_bench_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

struct Args {
    workload: String,
    log_n_rows: u32,
    sequence_len: u32,
    samples: usize,
    warmups: usize,
}

fn parse(line: &str) -> anyhow::Result<Args> {
    let mut args = Args {
        workload: String::new(),
        log_n_rows: 0,
        sequence_len: 8,
        samples: 3,
        warmups: 1,
    };
    let toks: Vec<&str> = line.split_whitespace().collect();
    let mut i = 0;
    while i < toks.len() {
        let key = toks[i];
        let val = toks
            .get(i + 1)
            .ok_or_else(|| anyhow::anyhow!("missing value for {key}"))?;
        match key {
            "--workload" | "--example" => args.workload = val.to_string(),
            "--log-n-rows" => args.log_n_rows = val.parse()?,
            "--sequence-len" => args.sequence_len = val.parse()?,
            "--samples" => args.samples = val.parse()?,
            "--warmups" => args.warmups = val.parse()?,
            other => anyhow::bail!("unknown flag {other}"),
        }
        i += 2;
    }
    if args.workload.is_empty() || args.log_n_rows == 0 {
        anyhow::bail!("--workload and --log-n-rows are required");
    }
    Ok(args)
}

fn prove_once(a: &Args) -> anyhow::Result<(Vec<u8>, f64)> {
    match a.workload.as_str() {
        "wide_fibonacci" => stwo_interop_rs::prove_wide_fibonacci(
            a.log_n_rows,
            a.sequence_len,
            POW_BITS,
            LOG_LAST_LAYER,
            LOG_BLOWUP,
            N_QUERIES,
        ),
        "plonk" => stwo_interop_rs::prove_plonk(
            a.log_n_rows,
            POW_BITS,
            LOG_LAST_LAYER,
            LOG_BLOWUP,
            N_QUERIES,
        ),
        other => anyhow::bail!("unsupported workload {other} (wide_fibonacci | plonk)"),
    }
}

fn bench(line: &str) -> anyhow::Result<String> {
    let a = parse(line)?;
    let n_samples = a.samples.max(1);
    for _ in 0..a.warmups {
        prove_once(&a)?;
    }
    let mut secs: Vec<f64> = Vec::with_capacity(n_samples);
    let mut digests: Vec<String> = Vec::with_capacity(n_samples);
    let mut proof_len = 0usize;
    for _ in 0..n_samples {
        let (bytes, prove_seconds) = prove_once(&a)?;
        secs.push(prove_seconds);
        proof_len = bytes.len();
        digests.push(hex::encode(Sha256::digest(&bytes)));
    }
    let mut sorted = secs.clone();
    sorted.sort_by(|x, y| x.partial_cmp(y).unwrap());
    let median = if sorted.len() % 2 == 1 {
        sorted[sorted.len() / 2]
    } else {
        (sorted[sorted.len() / 2 - 1] + sorted[sorted.len() / 2]) / 2.0
    };
    let all_equal = digests.windows(2).all(|w| w[0] == w[1]);

    Ok(serde_json::json!({
        "schema": "mobile-proof-rust-v1",
        "prover": "stwo-rust@a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2",
        "backend": "simd",
        "workload": { "name": a.workload, "log_n_rows": a.log_n_rows, "sequence_len": a.sequence_len },
        "protocol": { "name": "functional", "pow_bits": POW_BITS, "log_last_layer_degree_bound": LOG_LAST_LAYER, "log_blowup_factor": LOG_BLOWUP, "n_queries": N_QUERIES },
        "warmups": a.warmups,
        "samples": n_samples,
        "prove_seconds": { "samples": secs, "median": median },
        "proof": { "wire_bytes": proof_len, "sha256": digests, "all_samples_byte_identical": all_equal },
        "verified_samples": n_samples
    })
    .to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn c_abi_end_to_end() {
        let line =
            CString::new("--workload wide_fibonacci --log-n-rows 8 --sequence-len 8 --samples 2 --warmups 1")
                .unwrap();
        let out = stwo_mobile_bench(line.as_ptr());
        let s = unsafe { CStr::from_ptr(out) }.to_string_lossy().to_string();
        unsafe { stwo_mobile_bench_free(out) };
        assert!(s.starts_with('{'), "got: {s}");
        assert!(s.contains("mobile-proof-rust-v1"));
        assert!(s.contains("all_samples_byte_identical\":true"));
    }
}
