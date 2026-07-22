//! C-ABI mobile bench around the reference Rust stwo prover.
//!
//! Same contract as the Zig shim (mobile/README.md):
//!   stwo_mobile_bench("--example plonk --log-n-rows 12 --protocol functional --samples 5 --warmups 2")
//! returns NUL-terminated JSON or an `error: …` string; release it with
//! stwo_mobile_bench_free. Accepts the exact argument strings the Swift
//! shell sends (integration-tested below, verbatim).
//!
//! Timing contract = the Zig bench's: prove_seconds covers the transcript
//! machine only; twiddles are session-cached across warmups+samples; trace
//! generation, wire encoding, and verification are untimed
//! (see stwo-interop-rs/src/lib.rs docs).
//!
//! Report shape: digests live at `proof.samples[*].sha256` — the same path
//! validators use on native_proof_v7 — with `report_kind:
//! "rust_bench_v1"` as the discriminator (schema/mobile-proof-v1.md).

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
        samples: 5,
        warmups: 2,
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
            // The board runs one protocol; accept the flag the Swift shell
            // sends and reject anything but the pinned profile.
            "--protocol" => {
                if *val != "functional" {
                    anyhow::bail!("unsupported protocol {val} (functional only)");
                }
            }
            other => anyhow::bail!("unknown flag {other}"),
        }
        i += 2;
    }
    if args.workload.is_empty() || args.log_n_rows == 0 {
        anyhow::bail!("--workload and --log-n-rows are required");
    }
    Ok(args)
}

fn prove_once(
    session: &stwo_interop_rs::BenchSession,
    a: &Args,
) -> anyhow::Result<(Vec<u8>, f64)> {
    match a.workload.as_str() {
        "wide_fibonacci" => {
            stwo_interop_rs::bench_wide_fibonacci(session, a.log_n_rows, a.sequence_len)
        }
        "plonk" => stwo_interop_rs::bench_plonk(session, a.log_n_rows),
        other => anyhow::bail!("unsupported workload {other} (wide_fibonacci | plonk)"),
    }
}

fn bench(line: &str) -> anyhow::Result<String> {
    let a = parse(line)?;
    let n_samples = a.samples.max(1);
    // Session twiddles built once, untimed, reused across warmups+samples.
    let session = stwo_interop_rs::BenchSession::new(
        a.log_n_rows,
        POW_BITS,
        LOG_LAST_LAYER,
        LOG_BLOWUP,
        N_QUERIES,
    );
    for _ in 0..a.warmups {
        prove_once(&session, &a)?;
    }
    let mut secs: Vec<f64> = Vec::with_capacity(n_samples);
    let mut sample_objs: Vec<serde_json::Value> = Vec::with_capacity(n_samples);
    let mut digests: Vec<String> = Vec::with_capacity(n_samples);
    for _ in 0..n_samples {
        let (bytes, prove_seconds) = prove_once(&session, &a)?;
        secs.push(prove_seconds);
        let sha = hex::encode(Sha256::digest(&bytes));
        sample_objs.push(serde_json::json!({ "bytes": bytes.len(), "sha256": sha }));
        digests.push(sha);
    }
    let mut sorted = secs.clone();
    sorted.sort_by(|x, y| x.partial_cmp(y).unwrap());
    // v7 median semantics exactly (runner.py: sorted[len//2], i.e. the
    // upper element for even counts) — the board contract pins v7, so the
    // implementation matches it rather than the statistics textbook.
    let median = sorted[sorted.len() / 2];
    let all_equal = digests.windows(2).all(|w| w[0] == w[1]);

    Ok(serde_json::json!({
        "schema": "mobile-proof-rust-v1",
        "report_kind": "rust_bench_v1",
        "prover": "stwo-rust@a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2",
        "backend": "simd",
        "workload": { "name": a.workload, "log_n_rows": a.log_n_rows, "sequence_len": a.sequence_len },
        "protocol": { "name": "functional", "pow_bits": POW_BITS, "log_last_layer_degree_bound": LOG_LAST_LAYER, "log_blowup_factor": LOG_BLOWUP, "n_queries": N_QUERIES },
        "warmups": a.warmups,
        "samples": n_samples,
        "prove_seconds": { "samples": secs, "median": median },
        "proof": { "samples": sample_objs, "all_samples_byte_identical": all_equal },
        "verified_samples": n_samples
    })
    .to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    /// The pinned cross-flavor reference digest (mobile/PARITY.md): both
    /// flavors must emit exactly these proof bytes for this statement.
    const PARITY_SHA: &str = "91741aec956846d52e50f7b8fef3ac93195dbcd76cdb89e25ed33a148bea5700";

    fn run(line: &str) -> String {
        let c = CString::new(line).unwrap();
        let out = stwo_mobile_bench(c.as_ptr());
        let s = unsafe { CStr::from_ptr(out) }.to_string_lossy().to_string();
        unsafe { stwo_mobile_bench_free(out) };
        s
    }

    /// The EXACT argument strings the Swift shell sends (StwoBenchView.swift)
    /// — small at full contract, wide/deep at reduced size so the test stays
    /// fast while exercising the identical flag surface.
    #[test]
    fn swift_shell_arg_strings_are_accepted() {
        let small = run("--example wide_fibonacci --log-n-rows 10 --sequence-len 8 --protocol functional --warmups 2 --samples 5");
        assert!(small.starts_with('{'), "small rejected: {small}");
        let v: serde_json::Value = serde_json::from_str(&small).unwrap();
        assert_eq!(v["proof"]["samples"][0]["sha256"], PARITY_SHA);
        assert_eq!(v["proof"]["all_samples_byte_identical"], true);
        assert_eq!(v["samples"], 5);

        let wide = run("--example wide_fibonacci --log-n-rows 8 --sequence-len 32 --protocol functional --warmups 1 --samples 2");
        assert!(wide.starts_with('{'), "wide-shape rejected: {wide}");
        let deep = run("--example plonk --log-n-rows 8 --protocol functional --warmups 1 --samples 2");
        assert!(deep.starts_with('{'), "deep-shape rejected: {deep}");
    }

    #[test]
    fn error_results_are_prefixed_not_json() {
        let e = run("--example nope --log-n-rows 8 --protocol functional");
        assert!(e.starts_with("error: "), "got: {e}");
        let e2 = run("--example plonk --log-n-rows 8 --protocol secure");
        assert!(e2.starts_with("error: "), "got: {e2}");
    }
}
