use crate::model::{Cli, Example, FriConfigWire, Mode, PcsConfigWire, ProveMode};
use anyhow::{anyhow, bail, Result};
use stwo::core::fri::FriConfig;
use stwo::core::pcs::PcsConfig;

pub(crate) fn parse_cli(args: Vec<String>) -> Result<Cli> {
    let mut mode: Option<Mode> = None;
    let mut example: Option<Example> = None;
    let mut artifact: Option<String> = None;
    let mut stage_profile_out: Option<String> = None;
    let mut prove_mode = ProveMode::Prove;
    let mut include_all_preprocessed_columns = false;

    let mut pow_bits = 0u32;
    let mut fri_log_blowup = 1u32;
    let mut fri_log_last_layer = 0u32;
    let mut fri_n_queries = 3usize;

    let mut sm_log_n_rows = 5u32;
    let mut sm_initial_0 = 9u32;
    let mut sm_initial_1 = 3u32;

    let mut blake_log_n_rows = 5u32;
    let mut blake_n_rounds = 10u32;

    let mut plonk_log_n_rows = 5u32;

    let mut poseidon_log_n_instances = 8u32;

    let mut wf_log_n_rows = 5u32;
    let mut wf_sequence_len = 16u32;

    let mut xor_log_size = 5u32;
    let mut xor_log_step = 2u32;
    let mut xor_offset = 3usize;

    let mut bench_warmups = 1usize;
    let mut bench_repeats = 5usize;

    let mut i = 1usize;
    while i < args.len() {
        let flag = &args[i];
        if !flag.starts_with("--") {
            bail!("invalid argument {flag}");
        }
        if i + 1 >= args.len() {
            bail!("missing value for {flag}");
        }
        let value = &args[i + 1];
        i += 2;

        match flag.as_str() {
            "--mode" => {
                mode = match value.as_str() {
                    "generate" => Some(Mode::Generate),
                    "verify" => Some(Mode::Verify),
                    "bench" => Some(Mode::Bench),
                    _ => bail!("invalid mode {value}"),
                }
            }
            "--example" => {
                example = match value.as_str() {
                    "blake" => Some(Example::Blake),
                    "plonk" => Some(Example::Plonk),
                    "poseidon" => Some(Example::Poseidon),
                    "state_machine" => Some(Example::StateMachine),
                    "wide_fibonacci" => Some(Example::WideFibonacci),
                    "xor" => Some(Example::Xor),
                    _ => bail!("invalid example {value}"),
                }
            }
            "--artifact" => artifact = Some(value.clone()),
            "--stage-profile-out" => stage_profile_out = Some(value.clone()),
            "--prove-mode" => {
                prove_mode = prove_mode_from_str(value)
                    .ok_or_else(|| anyhow!("invalid prove mode {value}"))?
            }
            "--include-all-preprocessed-columns" => {
                include_all_preprocessed_columns = match value.as_str() {
                    "0" | "false" => false,
                    "1" | "true" => true,
                    _ => bail!(
                        "invalid boolean value for --include-all-preprocessed-columns: {value}"
                    ),
                };
            }
            "--pow-bits" => pow_bits = value.parse()?,
            "--fri-log-blowup" => fri_log_blowup = value.parse()?,
            "--fri-log-last-layer" => fri_log_last_layer = value.parse()?,
            "--fri-n-queries" => fri_n_queries = value.parse()?,
            "--sm-log-n-rows" => sm_log_n_rows = value.parse()?,
            "--sm-initial-0" => sm_initial_0 = value.parse()?,
            "--sm-initial-1" => sm_initial_1 = value.parse()?,
            "--blake-log-n-rows" => blake_log_n_rows = value.parse()?,
            "--blake-n-rounds" => blake_n_rounds = value.parse()?,
            "--plonk-log-n-rows" => plonk_log_n_rows = value.parse()?,
            "--poseidon-log-n-instances" => poseidon_log_n_instances = value.parse()?,
            "--wf-log-n-rows" => wf_log_n_rows = value.parse()?,
            "--wf-sequence-len" => wf_sequence_len = value.parse()?,
            "--xor-log-size" => xor_log_size = value.parse()?,
            "--xor-log-step" => xor_log_step = value.parse()?,
            "--xor-offset" => xor_offset = value.parse()?,
            "--bench-warmups" => bench_warmups = value.parse()?,
            "--bench-repeats" => bench_repeats = value.parse()?,
            _ => bail!("unknown flag {flag}"),
        }
    }

    Ok(Cli {
        mode: mode.ok_or_else(|| anyhow!("--mode is required"))?,
        example,
        artifact: artifact.ok_or_else(|| anyhow!("--artifact is required"))?,
        stage_profile_out,
        prove_mode,
        include_all_preprocessed_columns,
        pow_bits,
        fri_log_blowup,
        fri_log_last_layer,
        fri_n_queries,
        sm_log_n_rows,
        sm_initial_0,
        sm_initial_1,
        blake_log_n_rows,
        blake_n_rounds,
        plonk_log_n_rows,
        poseidon_log_n_instances,
        wf_log_n_rows,
        wf_sequence_len,
        xor_log_size,
        xor_log_step,
        xor_offset,
        bench_warmups,
        bench_repeats,
    })
}

pub(crate) fn prove_mode_to_str(mode: ProveMode) -> &'static str {
    match mode {
        ProveMode::Prove => "prove",
        ProveMode::ProveEx => "prove_ex",
    }
}

pub(crate) fn prove_mode_from_str(value: &str) -> Option<ProveMode> {
    match value {
        "prove" => Some(ProveMode::Prove),
        "prove_ex" => Some(ProveMode::ProveEx),
        _ => None,
    }
}

pub(crate) fn pcs_config_from_cli(cli: &Cli) -> Result<PcsConfig> {
    Ok(PcsConfig {
        pow_bits: cli.pow_bits,
        fri_config: FriConfig::new(
            cli.fri_log_last_layer,
            cli.fri_log_blowup,
            cli.fri_n_queries,
        ),
    })
}

pub(crate) fn pcs_config_to_wire(config: PcsConfig) -> PcsConfigWire {
    PcsConfigWire {
        pow_bits: config.pow_bits,
        fri_config: FriConfigWire {
            log_blowup_factor: config.fri_config.log_blowup_factor,
            log_last_layer_degree_bound: config.fri_config.log_last_layer_degree_bound,
            n_queries: config.fri_config.n_queries as u64,
        },
    }
}

pub(crate) fn pcs_config_from_wire(wire: &PcsConfigWire) -> Result<PcsConfig> {
    let n_queries: usize = wire
        .fri_config
        .n_queries
        .try_into()
        .map_err(|_| anyhow!("fri n_queries out of range"))?;
    Ok(PcsConfig {
        pow_bits: wire.pow_bits,
        fri_config: FriConfig::new(
            wire.fri_config.log_last_layer_degree_bound,
            wire.fri_config.log_blowup_factor,
            n_queries,
        ),
    })
}
