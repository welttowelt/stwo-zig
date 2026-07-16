use serde::Serialize;
use std::env;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Instant;
use stwo_cairo_verifier_adapter::{
    adapter_identity, hex_digest, read_envelope_file, verification_mode, verifier_config,
    verify_authenticated_envelope, write_json_atomically, Envelope, SectionKind, ENVELOPE_ABI,
};

#[derive(Debug)]
enum Command {
    Identity,
    Config,
    Verify { envelope: PathBuf, result: PathBuf },
}

#[derive(Serialize)]
struct StructuredError {
    code: &'static str,
    message: String,
}

#[derive(Serialize)]
struct VerifyResult {
    schema_version: u32,
    envelope_abi: &'static str,
    adapter_version: &'static str,
    cargo_lock_sha256: String,
    executable_sha256: Option<String>,
    stwo_cairo_revision: &'static str,
    stwo_revision: &'static str,
    protocol_digest: Option<String>,
    statement_digest: Option<String>,
    proof_digest: Option<String>,
    provenance_digest: Option<String>,
    verification_mode: &'static str,
    verified: bool,
    wall_time_ns: u64,
    error: Option<StructuredError>,
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(error) => {
            eprintln!("stwo-cairo-verifier-adapter: {error}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<ExitCode, String> {
    match parse_args(env::args_os().skip(1))? {
        Command::Identity => {
            let executable = env::current_exe().map_err(|error| error.to_string())?;
            let identity =
                adapter_identity(Some(&executable)).map_err(|error| error.to_string())?;
            serde_json::to_writer(std::io::stdout().lock(), &identity)
                .map_err(|error| error.to_string())?;
            println!();
            Ok(ExitCode::SUCCESS)
        }
        Command::Config => {
            serde_json::to_writer(std::io::stdout().lock(), &verifier_config())
                .map_err(|error| error.to_string())?;
            println!();
            Ok(ExitCode::SUCCESS)
        }
        Command::Verify { envelope, result } => verify(&envelope, &result),
    }
}

fn verify(envelope_path: &Path, result_path: &Path) -> Result<ExitCode, String> {
    let started = Instant::now();
    let executable = env::current_exe().map_err(|error| error.to_string())?;
    let identity = adapter_identity(Some(&executable)).map_err(|error| error.to_string())?;
    let bytes = read_envelope_file(envelope_path).map_err(|error| error.to_string())?;

    let mut mode = "unknown";
    let (digests, verified, error) = match Envelope::parse(&bytes) {
        Ok(envelope) => {
            mode = verification_mode(&envelope);
            let digests = Some([
                envelope.section(SectionKind::Protocol).sha256,
                envelope.section(SectionKind::Statement).sha256,
                envelope.section(SectionKind::Proof).sha256,
                envelope.section(SectionKind::Provenance).sha256,
            ]);
            match verify_authenticated_envelope(&envelope) {
                Ok(()) => (digests, true, None),
                Err(failure) => (
                    digests,
                    false,
                    Some(StructuredError {
                        code: failure.code,
                        message: failure.message,
                    }),
                ),
            }
        }
        Err(parse_error) => (
            None,
            false,
            Some(StructuredError {
                code: "invalid_envelope",
                message: parse_error.to_string(),
            }),
        ),
    };
    let digest = |index: usize| digests.as_ref().map(|values| hex_digest(values[index]));
    let report = VerifyResult {
        schema_version: 1,
        envelope_abi: ENVELOPE_ABI,
        adapter_version: identity.adapter_version,
        cargo_lock_sha256: identity.cargo_lock_sha256,
        executable_sha256: identity.executable_sha256,
        stwo_cairo_revision: identity.stwo_cairo.revision,
        stwo_revision: identity.stwo.revision,
        protocol_digest: digest(0),
        statement_digest: digest(1),
        proof_digest: digest(2),
        provenance_digest: digest(3),
        verification_mode: mode,
        verified,
        wall_time_ns: started.elapsed().as_nanos().min(u128::from(u64::MAX)) as u64,
        error,
    };
    write_json_atomically(result_path, &report).map_err(|error| error.to_string())?;
    Ok(if verified {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(3)
    })
}

fn parse_args<I>(mut args: I) -> Result<Command, String>
where
    I: Iterator<Item = std::ffi::OsString>,
{
    let command = args
        .next()
        .ok_or_else(|| usage("missing command"))?
        .into_string()
        .map_err(|_| usage("command is not valid UTF-8"))?;
    match command.as_str() {
        "identity" | "config" => {
            if args.next().is_some() {
                return Err(usage(&format!("{command} accepts no arguments")));
            }
            Ok(if command == "identity" {
                Command::Identity
            } else {
                Command::Config
            })
        }
        "verify" => {
            let mut envelope = None;
            let mut result = None;
            while let Some(flag) = args.next() {
                let flag = flag
                    .into_string()
                    .map_err(|_| usage("option is not valid UTF-8"))?;
                let value = args
                    .next()
                    .ok_or_else(|| usage(&format!("missing value for {flag}")))?;
                match flag.as_str() {
                    "--envelope" if envelope.is_none() => envelope = Some(PathBuf::from(value)),
                    "--result" if result.is_none() => result = Some(PathBuf::from(value)),
                    "--envelope" | "--result" => {
                        return Err(usage(&format!("duplicate option {flag}")))
                    }
                    _ => return Err(usage(&format!("unknown option {flag}"))),
                }
            }
            Ok(Command::Verify {
                envelope: envelope.ok_or_else(|| usage("missing --envelope"))?,
                result: result.ok_or_else(|| usage("missing --result"))?,
            })
        }
        _ => Err(usage(&format!("unknown command {command}"))),
    }
}

fn usage(message: &str) -> String {
    format!(
        "{message}\nusage: stwo-cairo-verifier-adapter identity\n       stwo-cairo-verifier-adapter config\n       stwo-cairo-verifier-adapter verify --envelope <path> --result <path>"
    )
}
