//! Recording poster images and output path helpers.

use crate::gfx::Gfx;
use std::path::PathBuf;
use windows::Win32::Foundation::E_OUTOFMEMORY;
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Imaging::*;
use windows::Win32::System::SystemInformation::GetLocalTime;
use windows::core::*;

pub struct Image {
    pub width: u32,
    pub height: u32,
    /// Top-down BGRA, opaque.
    pub pixels: Vec<u8>,
}

fn image_buffer(width: u32, height: u32) -> Result<Vec<u8>> {
    let len = width
        .checked_mul(height)
        .and_then(|n| n.checked_mul(4))
        .ok_or_else(|| Error::new(E_OUTOFMEMORY, "Image exceeds WIC's buffer size limit"))? as usize;
    let mut pixels = Vec::new();
    pixels.try_reserve_exact(len).map_err(|_| Error::from(E_OUTOFMEMORY))?;
    pixels.resize(len, 0);
    Ok(pixels)
}

pub fn bitmap_props() -> D2D1_BITMAP_PROPERTIES {
    D2D1_BITMAP_PROPERTIES {
        pixelFormat: D2D1_PIXEL_FORMAT { format: DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED },
        dpiX: 96.0,
        dpiY: 96.0,
    }
}

pub fn target_props() -> D2D1_RENDER_TARGET_PROPERTIES {
    D2D1_RENDER_TARGET_PROPERTIES {
        r#type: D2D1_RENDER_TARGET_TYPE_DEFAULT,
        pixelFormat: bitmap_props().pixelFormat,
        dpiX: 96.0,
        dpiY: 96.0,
        usage: D2D1_RENDER_TARGET_USAGE_NONE,
        minLevel: D2D1_FEATURE_LEVEL_DEFAULT,
    }
}

/// High-quality resize, used for the recording preview.
pub fn resize(gfx: &Gfx, img: &Image, width: u32, height: u32) -> Result<Image> {
    unsafe {
        let mut pixels = image_buffer(width, height)?;
        let src = source(gfx, img)?;
        let scaler = gfx.wic.CreateBitmapScaler()?;
        scaler.Initialize(&src, width, height, WICBitmapInterpolationModeHighQualityCubic)?;
        scaler.CopyPixels(std::ptr::null(), width * 4, &mut pixels)?;
        Ok(Image { width, height, pixels })
    }
}

unsafe fn source(gfx: &Gfx, img: &Image) -> Result<IWICBitmap> {
    unsafe {
        gfx.wic.CreateBitmapFromMemory(img.width, img.height, &GUID_WICPixelFormat32bppBGRA, img.width * 4, &img.pixels)
    }
}

pub fn expand(path: &str) -> PathBuf {
    let mut out = String::new();
    let mut rest = path.trim();
    if let Some(tail) = rest.strip_prefix('~') {
        out.push_str(&std::env::var("USERPROFILE").unwrap_or_default());
        rest = tail;
    }
    let parts: Vec<&str> = rest.split('%').collect();
    out.push_str(parts[0]);
    let mut i = 1;
    while i < parts.len() {
        let name = parts[i];
        if i + 1 == parts.len() {
            out.push('%');
            out.push_str(name);
            break;
        }
        match std::env::var(name) {
            Ok(v) if !name.is_empty() => out.push_str(&v),
            _ => out.push_str(&format!("%{name}%")),
        }
        out.push_str(parts[i + 1]);
        i += 2;
    }
    PathBuf::from(out)
}

/// Formats an output file name without path separators or reserved characters.
pub fn file_stem(format: &str) -> String {
    let t = unsafe { GetLocalTime() };
    let fmt = if format.trim().is_empty() { "recording-%Y-%m-%d_%H-%M-%S" } else { format.trim() };
    let stem = fmt
        .replace("%Y", &format!("{:04}", t.wYear))
        .replace("%m", &format!("{:02}", t.wMonth))
        .replace("%d", &format!("{:02}", t.wDay))
        .replace("%H", &format!("{:02}", t.wHour))
        .replace("%M", &format!("{:02}", t.wMinute))
        .replace("%S", &format!("{:02}", t.wSecond));
    let clean: String = stem.chars().map(|c| if "\\/:*?\"<>|\r\n\0".contains(c) { '_' } else { c }).collect();
    let clean = clean.trim().trim_end_matches('.').to_string();
    if clean.is_empty() { file_stem("") } else { clean }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stems_are_safe() {
        let s = file_stem("shot %Y/%m:%d");
        assert!(!s.contains('/') && !s.contains(':'));
        assert!(file_stem("").starts_with("recording-"));
        assert!(file_stem("...").starts_with("recording-"));
    }

    #[test]
    fn expands_variables() {
        let profile = std::env::var("USERPROFILE").unwrap();
        assert_eq!(expand("%USERPROFILE%\\shots"), PathBuf::from(profile).join("shots"));
        assert_eq!(expand("100%"), PathBuf::from("100%"));
    }

    #[test]
    fn oversized_resize_is_rejected_before_allocation() {
        assert_eq!(image_buffer(20, 10).unwrap().len(), 800);
        assert!(image_buffer(u32::MAX, 2).is_err());
    }

}
