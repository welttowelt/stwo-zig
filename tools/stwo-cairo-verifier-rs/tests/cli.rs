use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};
use stwo_cairo_verifier_adapter::{
    sha256, SectionKind, HEADER_LEN, MAGIC, SECTION_FLAG_MANDATORY, SECTION_HEADER_LEN,
    STWO_CAIRO_REVISION, STWO_REVISION, VERSION,
};

fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_stwo-cairo-verifier-adapter")
}

fn temporary_directory(label: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "stwo-cairo-verifier-adapter-{label}-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir(&path).unwrap();
    path
}

fn canonical_envelope() -> Vec<u8> {
    let sections: [(SectionKind, &[u8]); 4] = [
        (SectionKind::Protocol, b"protocol"),
        (SectionKind::Statement, b"statement"),
        (SectionKind::Proof, b"proof"),
        (SectionKind::Provenance, b"provenance"),
    ];
    let total_len = usize::from(HEADER_LEN)
        + sections
            .iter()
            .map(|(_, payload)| SECTION_HEADER_LEN + payload.len())
            .sum::<usize>();
    let mut bytes = Vec::with_capacity(total_len);
    bytes.extend_from_slice(&MAGIC);
    bytes.extend_from_slice(&VERSION.to_le_bytes());
    bytes.extend_from_slice(&HEADER_LEN.to_le_bytes());
    bytes.extend_from_slice(&0_u32.to_le_bytes());
    bytes.extend_from_slice(&(sections.len() as u32).to_le_bytes());
    bytes.extend_from_slice(&0_u32.to_le_bytes());
    bytes.extend_from_slice(&(total_len as u64).to_le_bytes());
    for (kind, payload) in sections {
        bytes.extend_from_slice(&(kind as u16).to_le_bytes());
        bytes.extend_from_slice(&SECTION_FLAG_MANDATORY.to_le_bytes());
        bytes.extend_from_slice(&0_u32.to_le_bytes());
        bytes.extend_from_slice(&(payload.len() as u64).to_le_bytes());
        bytes.extend_from_slice(&sha256(payload));
        bytes.extend_from_slice(payload);
    }
    bytes
}

#[test]
fn identity_reports_exact_pins_and_codec_capabilities() {
    let output = Command::new(binary()).arg("identity").output().unwrap();
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let identity: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(identity["envelope_abi"], "STWZCVE/1");
    assert_eq!(identity["stwo_cairo"]["revision"], STWO_CAIRO_REVISION);
    assert_eq!(identity["stwo"]["revision"], STWO_REVISION);
    assert_eq!(identity["proof_reconstruction_implemented"], true);
    assert_eq!(identity["canonical_verification_implemented"], true);
    assert_eq!(identity["json_proof_verification_implemented"], true);
    assert_eq!(identity["compact_claim_reconstruction_implemented"], true);
    assert_eq!(
        identity["compact_stark_proof_reconstruction_implemented"],
        true
    );
    assert_eq!(identity["compact_proof_reconstruction_implemented"], true);
    assert_eq!(identity["compact_proof_verification_implemented"], true);
    assert_eq!(identity["cargo_lock_sha256"].as_str().unwrap().len(), 64);
    assert_eq!(identity["executable_sha256"].as_str().unwrap().len(), 64);
}

#[test]
fn config_reports_direct_argv_and_resource_bounds() {
    let output = Command::new(binary()).arg("config").output().unwrap();
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let config: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(config["envelope_abi"], "STWZCVE/1");
    assert_eq!(config["argv_template"][0], "verify");
    assert_eq!(config["argv_template"][2], "{exclusive_envelope_path}");
    assert_eq!(config["argv_template"][4], "{exclusive_result_path}");
    assert_eq!(config["timeout_ms"], 30_000);
    assert_eq!(config["max_envelope_bytes"], 1_u64 << 30);
    assert_eq!(config["max_result_bytes"], 1_u64 << 20);
    assert_eq!(config["max_address_space_bytes"], 4_u64 << 30);
}

#[test]
fn verify_rejects_authenticated_but_unknown_payload_codecs() {
    let directory = temporary_directory("authenticated");
    let envelope = directory.join("proof.stwzcve");
    let result = directory.join("result.json");
    fs::write(&envelope, canonical_envelope()).unwrap();

    let status = Command::new(binary())
        .args(["verify", "--envelope"])
        .arg(&envelope)
        .arg("--result")
        .arg(&result)
        .status()
        .unwrap();
    assert_eq!(status.code(), Some(3));
    let report: Value = serde_json::from_slice(&fs::read(&result).unwrap()).unwrap();
    assert_eq!(report["verified"], false);
    assert_eq!(report["error"]["code"], "invalid_protocol");
    for digest in [
        "protocol_digest",
        "statement_digest",
        "proof_digest",
        "provenance_digest",
    ] {
        assert_eq!(report[digest].as_str().unwrap().len(), 64);
    }

    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn verify_reports_malformed_envelope_without_digests() {
    let directory = temporary_directory("malformed");
    let envelope = directory.join("proof.stwzcve");
    let result = directory.join("result.json");
    fs::write(&envelope, b"not an envelope").unwrap();

    let status = Command::new(binary())
        .args(["verify", "--envelope"])
        .arg(&envelope)
        .arg("--result")
        .arg(&result)
        .status()
        .unwrap();
    assert_eq!(status.code(), Some(3));
    let report: Value = serde_json::from_slice(&fs::read(&result).unwrap()).unwrap();
    assert_eq!(report["verified"], false);
    assert_eq!(report["error"]["code"], "invalid_envelope");
    assert!(report["protocol_digest"].is_null());
    assert!(report["proof_digest"].is_null());

    fs::remove_dir_all(directory).unwrap();
}
