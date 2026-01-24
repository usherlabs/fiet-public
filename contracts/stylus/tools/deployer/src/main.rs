use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use anyhow::{anyhow, Context, Result};
use clap::Parser;
use regex::Regex;
use serde_json::{json, Value};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

/// Deploy the Stylus contract using `cargo stylus deploy`, then write/update a deployments JSON.
///
/// This is intentionally a thin wrapper: it *still* uses the canonical `cargo stylus deploy`
/// workflow, but makes the output machine-readable for integration tooling.
#[derive(Parser, Debug)]
#[command(author, version, about)]
struct Cli {
    /// Directory containing the Stylus contract crate (where `cargo stylus deploy` should be run).
    ///
    /// In this repo, the contract crate lives under `src/` (eg `src/fiet-maker-policy/`).
    #[arg(long, default_value = "src/fiet-maker-policy")]
    contract_dir: PathBuf,

    /// RPC URL used by `cargo stylus deploy`.
    #[arg(long, env = "RPC_URL")]
    rpc_url: String,

    /// Path to a file containing the deployer private key.
    #[arg(long, env = "PRIV_KEY_PATH", conflicts_with = "private_key")]
    private_key_path: Option<String>,

    /// Private key (hex string, 0x...).
    #[arg(long, env = "PKEY", conflicts_with = "private_key_path")]
    private_key: Option<String>,

    /// Path to write deployment info (eg, deployments.devnet.json).
    #[arg(long, default_value = "deployments.devnet.json")]
    deployments_path: PathBuf,

    /// Key under `deployments` to store this contract (eg, intent-policy).
    #[arg(long, default_value = "intent-policy")]
    contract_key: String,

    /// Optional network name (eg, devnet, arb-sepolia).
    #[arg(long, default_value = "devnet")]
    network: String,

    /// Extra args to pass through to `cargo stylus deploy` (after `--`).
    ///
    /// Example:
    /// `-- --estimate-gas`
    #[arg(last = true)]
    passthrough: Vec<String>,
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    let (address, tx_hashes, raw_output) = run_cargo_stylus_deploy(&cli)?;
    write_deployments_json(&cli, &address, &tx_hashes, &raw_output)?;

    println!("Deployed `{}` to {}", cli.contract_key, address);
    Ok(())
}

fn run_cargo_stylus_deploy(cli: &Cli) -> Result<(String, Vec<String>, String)> {
    // Example output lines we parse (as shown in the repo README):
    //   Deploying program to address 0x...
    //   Confirmed tx 0x...
    let re_address = Regex::new(r"Deploying program to address (0x[a-fA-F0-9]{40})")?;
    let re_tx = Regex::new(r"Confirmed tx (0x[a-fA-F0-9]{64})")?;

    let mut cmd = Command::new("cargo");
    cmd.current_dir(&cli.contract_dir);
    cmd.arg("stylus").arg("deploy");
    cmd.arg("-e").arg(&cli.rpc_url);

    if let Some(ref pk_path) = cli.private_key_path {
        cmd.arg("--private-key-path").arg(pk_path);
    } else if let Some(ref pk) = cli.private_key {
        cmd.arg("--private-key").arg(pk);
    } else {
        return Err(anyhow!(
            "missing deployer key: provide --private-key-path or --private-key (or set PRIV_KEY_PATH/PKEY)"
        ));
    }

    // Keep stdout/stderr for parsing and for debugging when runs fail.
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());

    // Allow passing flags like --estimate-gas, --mode, etc.
    if !cli.passthrough.is_empty() {
        // clap includes the leading `--` separator in last=true? It does not; it gives args after it.
        cmd.args(&cli.passthrough);
    }

    let output = cmd
        .output()
        .context("failed to run `cargo stylus deploy`")?;
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    let combined = format!("{stdout}\n{stderr}");

    if !output.status.success() {
        return Err(anyhow!(
            "`cargo stylus deploy` failed (exit {}):\n{}",
            output.status,
            combined
        ));
    }

    let address = re_address
        .captures_iter(&combined)
        .next()
        .and_then(|c| c.get(1).map(|m| m.as_str().to_string()))
        .ok_or_else(|| {
            anyhow!("could not parse deployed address from `cargo stylus deploy` output")
        })?;

    let tx_hashes: Vec<String> = re_tx
        .captures_iter(&combined)
        .filter_map(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .collect();

    Ok((address, tx_hashes, combined))
}

fn write_deployments_json(
    cli: &Cli,
    address: &str,
    tx_hashes: &[String],
    raw_output: &str,
) -> Result<()> {
    let now = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "unknown".to_string());

    let existing = if cli.deployments_path.exists() {
        fs::read_to_string(&cli.deployments_path)
            .with_context(|| format!("failed reading {}", cli.deployments_path.display()))?
    } else {
        String::new()
    };

    let mut root: Value = if existing.trim().is_empty() {
        json!({})
    } else {
        serde_json::from_str(&existing)
            .with_context(|| format!("failed parsing JSON in {}", cli.deployments_path.display()))?
    };

    // Ensure root object
    if !root.is_object() {
        root = json!({});
    }

    // root.network / root.updated_at
    root["network"] = json!(cli.network);
    root["updated_at"] = json!(now);

    // root.deployments[contract_key] = { address, tx hashes, ... }
    if root.get("deployments").and_then(Value::as_object).is_none() {
        root["deployments"] = json!({});
    }

    let mut entry = json!({
        "address": address,
        "rpc_url": cli.rpc_url,
        "deployed_at": now,
    });

    if !tx_hashes.is_empty() {
        entry["tx_hashes"] = json!(tx_hashes);
    }

    // Preserve raw output for audit/debugging, but truncate so we don't bloat git history.
    // (Still useful when a devnet deployment behaves unexpectedly.)
    let trimmed = raw_output.trim();
    if !trimmed.is_empty() {
        let max = 16_000usize;
        let s = if trimmed.len() > max {
            &trimmed[..max]
        } else {
            trimmed
        };
        entry["cargo_stylus_output"] = json!(s);
    }

    root["deployments"][&cli.contract_key] = entry;

    write_json_atomic(&cli.deployments_path, &root)?;
    Ok(())
}

fn write_json_atomic(path: &Path, value: &Value) -> Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    if !parent.exists() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed creating directory {}", parent.display()))?;
    }

    let serialised =
        serde_json::to_string_pretty(value).context("failed serialising deployments JSON")?;
    let tmp_path = tmp_path_for(path);
    fs::write(&tmp_path, serialised.as_bytes())
        .with_context(|| format!("failed writing temp file {}", tmp_path.display()))?;
    fs::rename(&tmp_path, path).with_context(|| format!("failed replacing {}", path.display()))?;
    Ok(())
}

fn tmp_path_for(path: &Path) -> PathBuf {
    let mut tmp = path.as_os_str().to_os_string();
    tmp.push(".tmp");
    PathBuf::from(tmp)
}
