// Prints one bench report — used for the cross-flavor parity artifact.
use std::ffi::{CStr, CString};
fn main() {
    let line = CString::new(std::env::args().nth(1).unwrap_or_else(|| {
        "--workload wide_fibonacci --log-n-rows 10 --sequence-len 8 --samples 1 --warmups 0".into()
    }))
    .unwrap();
    let out = stwo_mobile_bench::stwo_mobile_bench(line.as_ptr());
    println!("{}", unsafe { CStr::from_ptr(out) }.to_string_lossy());
    unsafe { stwo_mobile_bench::stwo_mobile_bench_free(out) };
}
