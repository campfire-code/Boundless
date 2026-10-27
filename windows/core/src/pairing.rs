//! 配对码：12 位（约 59 bit 熵），去掉易混淆的 I/L/O/0/1。与 Swift 版 Pairing.swift 规则一致

use rand::seq::SliceRandom;

const ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const LENGTH: usize = 12;

pub fn generate_code() -> String {
    let mut rng = rand::rngs::OsRng;
    let chars: Vec<u8> = (0..LENGTH).map(|_| *ALPHABET.choose(&mut rng).unwrap()).collect();
    format(&chars)
}

/// 规范化用户输入（忽略大小写、空格、横线），不合法返回 None
pub fn normalize(input: &str) -> Option<String> {
    let chars: Vec<u8> = input
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .flat_map(|c| c.to_uppercase())
        .map(|c| if c.is_ascii() { c as u8 } else { 0 })
        .collect();
    if chars.len() != LENGTH || !chars.iter().all(|c| ALPHABET.contains(c)) {
        return None;
    }
    Some(format(&chars))
}

/// 由配对码派生 TLS 预共享密钥（PBKDF2-SHA256，20 万次迭代）
pub fn preshared_key(code: &str) -> [u8; 32] {
    let password = normalize(code).unwrap_or_else(|| code.to_string());
    let mut key = [0u8; 32];
    openssl::pkcs5::pbkdf2_hmac(
        password.as_bytes(),
        b"boundless-pairing-v1",
        200_000,
        openssl::hash::MessageDigest::sha256(),
        &mut key,
    )
    .expect("PBKDF2 失败");
    key
}

fn format(chars: &[u8]) -> String {
    chars.chunks(4).map(|c| std::str::from_utf8(c).unwrap()).collect::<Vec<_>>().join("-")
}
