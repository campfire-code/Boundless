//! 剪贴板内容在 macOS（UTI）与 Windows 剪贴板格式之间的换算。只做数据转换，读写剪贴板在平台层

use std::io::Cursor;

pub const UTI_TEXT: &str = "public.utf8-plain-text";
pub const UTI_RTF: &str = "public.rtf";
pub const UTI_HTML: &str = "public.html";
pub const UTI_PNG: &str = "public.png";
pub const UTI_TIFF: &str = "public.tiff";

/// 与 Mac 版一致：超过 32MB 不同步
pub const MAX_BYTES: usize = 32 << 20;

/// 换行换成 Windows 的 CRLF（已经是 CRLF 的不重复加）
pub fn text_to_windows(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + s.len() / 32);
    let mut prev = '\0';
    for c in s.chars() {
        if c == '\n' && prev != '\r' {
            out.push('\r');
        }
        out.push(c);
        prev = c;
    }
    out
}

/// CRLF 换成 macOS 的 LF
pub fn text_from_windows(s: &str) -> String {
    s.replace("\r\n", "\n")
}

// MARK: CF_HTML（"HTML Format"）

/// HTML 包上 Windows 剪贴板要求的头部，偏移量是 UTF-8 字节数
pub fn html_to_cf_html(html: &str) -> Vec<u8> {
    let lower = html.to_ascii_lowercase();
    let (prefix, fragment, suffix) = match (lower.find("<body"), lower.rfind("</body>")) {
        (Some(open), Some(close)) if open < close => match lower[open..].find('>') {
            Some(gt) if open + gt < close => (&html[..open + gt + 1], &html[open + gt + 1..close], &html[close..]),
            _ => ("<html><body>", html, "</body></html>"),
        },
        _ => ("<html><body>", html, "</body></html>"),
    };
    const START: &str = "<!--StartFragment-->";
    const END: &str = "<!--EndFragment-->";
    let header_len = "Version:0.9\r\nStartHTML:0000000000\r\nEndHTML:0000000000\r\nStartFragment:0000000000\r\nEndFragment:0000000000\r\n".len();
    let start_html = header_len;
    let start_fragment = start_html + prefix.len() + START.len();
    let end_fragment = start_fragment + fragment.len();
    let end_html = end_fragment + END.len() + suffix.len();
    let mut out = format!(
        "Version:0.9\r\nStartHTML:{start_html:010}\r\nEndHTML:{end_html:010}\r\nStartFragment:{start_fragment:010}\r\nEndFragment:{end_fragment:010}\r\n"
    );
    out.push_str(prefix);
    out.push_str(START);
    out.push_str(fragment);
    out.push_str(END);
    out.push_str(suffix);
    out.into_bytes()
}

/// 从 CF_HTML 中取出 HTML：优先取完整文档（保留样式），取不到再取片段
pub fn cf_html_to_html(data: &[u8]) -> Option<String> {
    let data = data.strip_suffix(&[0]).unwrap_or(data);
    let header = String::from_utf8_lossy(&data[..data.len().min(512)]);
    let field = |name: &str| -> Option<usize> {
        let at = header.find(&format!("{name}:"))? + name.len() + 1;
        let digits: String = header[at..].chars().take_while(|c| c.is_ascii_digit() || *c == '-').collect();
        digits.parse::<i64>().ok().filter(|v| *v >= 0).map(|v| v as usize)
    };
    let range = |start: Option<usize>, end: Option<usize>| match (start, end) {
        (Some(s), Some(e)) if s < e && e <= data.len() => Some(&data[s..e]),
        _ => None,
    };
    let bytes = range(field("StartHTML"), field("EndHTML")).or_else(|| range(field("StartFragment"), field("EndFragment")))?;
    Some(String::from_utf8_lossy(bytes).into_owned())
}

// MARK: 图片：Windows 的 DIB（不带文件头的 BMP）↔ PNG

/// CF_DIB / CF_DIBV5 → PNG
pub fn dib_to_png(dib: &[u8]) -> Option<Vec<u8>> {
    if dib.len() < 40 {
        return None;
    }
    let u32_at = |o: usize| u32::from_le_bytes(dib[o..o + 4].try_into().unwrap());
    let header_size = u32_at(0) as usize;
    let bit_count = u16::from_le_bytes(dib[14..16].try_into().unwrap()) as usize;
    let compression = u32_at(16);
    let colors_used = u32_at(32) as usize;
    let palette_entries = if bit_count <= 8 && colors_used == 0 { 1usize << bit_count } else { colors_used };
    let palette = palette_entries * 4;
    // BITMAPINFOHEADER + BI_BITFIELDS / BI_ALPHABITFIELDS 时，掩码紧跟在头后面
    let masks = match (header_size, compression) {
        (40, 3) => 12,
        (40, 6) => 16,
        _ => 0,
    };
    let offset = 14 + header_size + masks + palette;
    let mut bmp = Vec::with_capacity(14 + dib.len());
    bmp.extend_from_slice(b"BM");
    bmp.extend_from_slice(&((14 + dib.len()) as u32).to_le_bytes());
    bmp.extend_from_slice(&[0, 0, 0, 0]);
    bmp.extend_from_slice(&(offset as u32).to_le_bytes());
    bmp.extend_from_slice(dib);
    let img = image::load_from_memory_with_format(&bmp, image::ImageFormat::Bmp).ok()?;
    encode_png(&img)
}

/// PNG 或 TIFF → CF_DIB（32 位、自下而上、BGRA）
pub fn image_to_dib(data: &[u8]) -> Option<Vec<u8>> {
    let img = image::load_from_memory(data).ok()?.to_rgba8();
    let (w, h) = img.dimensions();
    let mut out = Vec::with_capacity(40 + (w * h * 4) as usize);
    out.extend_from_slice(&40u32.to_le_bytes());
    out.extend_from_slice(&(w as i32).to_le_bytes());
    out.extend_from_slice(&(h as i32).to_le_bytes()); // 正值：自下而上
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&32u16.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes()); // BI_RGB
    out.extend_from_slice(&(w * h * 4).to_le_bytes());
    out.extend_from_slice(&[0; 16]); // 分辨率、调色板
    for row in img.rows().rev() {
        for px in row {
            let [r, g, b, a] = px.0;
            out.extend_from_slice(&[b, g, r, a]);
        }
    }
    Some(out)
}

/// TIFF（或其他 image 能读的格式）→ PNG
pub fn image_to_png(data: &[u8]) -> Option<Vec<u8>> {
    encode_png(&image::load_from_memory(data).ok()?)
}

fn encode_png(img: &image::DynamicImage) -> Option<Vec<u8>> {
    let mut out = Cursor::new(Vec::new());
    img.write_to(&mut out, image::ImageFormat::Png).ok()?;
    Some(out.into_inner())
}
