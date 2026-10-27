//! 小端序二进制读写，与 Swift 版 Wire.swift 逐字节一致

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WireError {
    Truncated,
    UnknownMessage(u8),
    InvalidValue,
    FrameTooLarge(usize),
}

impl fmt::Display for WireError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WireError::Truncated => write!(f, "消息不完整"),
            WireError::UnknownMessage(t) => write!(f, "未知消息类型 {t}"),
            WireError::InvalidValue => write!(f, "消息内容不合法"),
            WireError::FrameTooLarge(n) => write!(f, "帧过大（{n} 字节）"),
        }
    }
}

impl std::error::Error for WireError {}

#[derive(Default)]
pub struct ByteWriter {
    pub data: Vec<u8>,
}

impl ByteWriter {
    pub fn u8(&mut self, v: u8) {
        self.data.push(v);
    }
    pub fn bool(&mut self, v: bool) {
        self.u8(v as u8);
    }
    pub fn u16(&mut self, v: u16) {
        self.data.extend_from_slice(&v.to_le_bytes());
    }
    pub fn u32(&mut self, v: u32) {
        self.data.extend_from_slice(&v.to_le_bytes());
    }
    pub fn i32(&mut self, v: i32) {
        self.data.extend_from_slice(&v.to_le_bytes());
    }
    pub fn u64(&mut self, v: u64) {
        self.data.extend_from_slice(&v.to_le_bytes());
    }
    pub fn f64(&mut self, v: f64) {
        self.u64(v.to_bits());
    }
    pub fn bytes(&mut self, d: &[u8]) {
        self.u32(d.len() as u32);
        self.data.extend_from_slice(d);
    }
    pub fn string(&mut self, s: &str) {
        self.bytes(s.as_bytes());
    }
}

pub struct ByteReader<'a> {
    data: &'a [u8],
    offset: usize,
}

impl<'a> ByteReader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        ByteReader { data, offset: 0 }
    }

    pub fn is_at_end(&self) -> bool {
        self.offset == self.data.len()
    }

    pub fn take(&mut self, n: usize) -> Result<&'a [u8], WireError> {
        if self.data.len() - self.offset < n {
            return Err(WireError::Truncated);
        }
        let s = &self.data[self.offset..self.offset + n];
        self.offset += n;
        Ok(s)
    }

    fn array<const N: usize>(&mut self) -> Result<[u8; N], WireError> {
        Ok(self.take(N)?.try_into().unwrap())
    }

    pub fn u8(&mut self) -> Result<u8, WireError> {
        Ok(self.take(1)?[0])
    }
    pub fn bool(&mut self) -> Result<bool, WireError> {
        Ok(self.u8()? != 0)
    }
    pub fn u16(&mut self) -> Result<u16, WireError> {
        Ok(u16::from_le_bytes(self.array()?))
    }
    pub fn u32(&mut self) -> Result<u32, WireError> {
        Ok(u32::from_le_bytes(self.array()?))
    }
    pub fn i32(&mut self) -> Result<i32, WireError> {
        Ok(i32::from_le_bytes(self.array()?))
    }
    pub fn u64(&mut self) -> Result<u64, WireError> {
        Ok(u64::from_le_bytes(self.array()?))
    }
    pub fn f64(&mut self) -> Result<f64, WireError> {
        Ok(f64::from_bits(self.u64()?))
    }
    pub fn bytes(&mut self) -> Result<Vec<u8>, WireError> {
        let n = self.u32()? as usize;
        Ok(self.take(n)?.to_vec())
    }
    pub fn string(&mut self) -> Result<String, WireError> {
        String::from_utf8(self.bytes()?).map_err(|_| WireError::InvalidValue)
    }
}
