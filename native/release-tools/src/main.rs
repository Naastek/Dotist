use anyhow::{bail, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use minisign::{PublicKey, SecretKey, SecretKeyBox, SignatureBox};
use std::{env, fs, io::Write, process::{Command, Stdio}};

fn main() -> Result<()> {
    let args: Vec<_> = env::args().collect();
    let config: serde_json::Value = serde_json::from_slice(&fs::read("src-tauri/tauri.conf.json")?)?;
    let boxed = String::from_utf8(STANDARD.decode(config["plugins"]["updater"]["pubkey"].as_str().context("Missing updater public key")?)?)?;
    let public = PublicKey::from_box(boxed.into())?;
    if args.len() == 4 && args[1] == "verify" {
        let signature = String::from_utf8(STANDARD.decode(fs::read_to_string(&args[3])?.trim())?)?;
        minisign::verify(&public, &SignatureBox::from_string(&signature)?, fs::File::open(&args[2])?, true, false, false)?;
        return Ok(());
    }
    if args.len() != 3 { bail!("Usage: dotist-release-tools <archive> <Sparkle sign_update> | verify <archive> <signature file>"); }
    let key = env::var("TAURI_SIGNING_PRIVATE_KEY").context("Missing updater signing key")?;
    let key = if key.starts_with("untrusted comment:") { key } else { String::from_utf8(STANDARD.decode(key.trim())?)? };
    let secret = SecretKey::from_box(SecretKeyBox::from_string(&key)?, Some(env::var("TAURI_SIGNING_PRIVATE_KEY_PASSWORD").unwrap_or_default()))?;
    // minisign's serialized key contains 6 algorithm bytes, a 32-byte salt,
    // two 8-byte KDF limits, an 8-byte ID, then the 64-byte Ed25519 seed+public.
    let bytes = secret.to_bytes();
    let public_bytes = public.to_bytes();
    if bytes.len() != 158 || public_bytes.len() != 42 || bytes[94..126] != public_bytes[10..42] {
        bail!("Signing key does not match the application's trusted updater key");
    }
    let signature = minisign::sign(Some(&public), &secret, fs::File::open(&args[1])?, None, None)?;
    let tauri_signature = STANDARD.encode(signature.to_string().as_bytes());
    let mut signer = Command::new(&args[2]).args(["--ed-key-file", "-", "-p", &args[1]])
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;
    signer.stdin.take().context("Missing signer input")?.write_all(STANDARD.encode(&bytes[62..94]).as_bytes())?;
    let result = signer.wait_with_output()?;
    if !result.status.success() { bail!("Sparkle signing failed: {}", String::from_utf8_lossy(&result.stderr)); }
    let sparkle_signature = String::from_utf8(result.stdout)?.trim().to_owned();
    if STANDARD.decode(&sparkle_signature)?.len() != 64 { bail!("Invalid Sparkle signature"); }
    println!("{}", serde_json::json!({"tauriSignature":tauri_signature,"sparkleSignature":sparkle_signature,"sparklePublicKey":STANDARD.encode(&public_bytes[10..42])}));
    Ok(())
}
