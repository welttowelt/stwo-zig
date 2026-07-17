mod cli;
mod commands;
mod components;
mod model;
mod profile;
mod proving;
mod statements;
mod traces;
mod wire;

use anyhow::{bail, Result};
use cli::parse_cli;
use commands::{run_bench, run_generate, run_verify};
use model::Mode;
use std::env;

const UPSTREAM_COMMIT: &str = "a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2";

fn main() -> Result<()> {
    let cli = parse_cli(env::args().collect())?;
    if cli.stage_profile_out.is_some() && cli.mode != Mode::Generate {
        bail!("--stage-profile-out is only supported for generate mode");
    }
    match cli.mode {
        Mode::Generate => run_generate(&cli),
        Mode::Verify => run_verify(&cli),
        Mode::Bench => run_bench(&cli),
    }
}
