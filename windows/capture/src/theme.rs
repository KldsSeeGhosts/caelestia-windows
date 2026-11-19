//! Fallback colors for the native recording controls and previews.

use windows::Win32::Graphics::Direct2D::Common::D2D1_COLOR_F;

pub const fn rgb(v: u32) -> D2D1_COLOR_F {
    rgba(v, 1.0)
}

pub const fn rgba(v: u32, a: f32) -> D2D1_COLOR_F {
    D2D1_COLOR_F { r: ((v >> 16) & 0xff) as f32 / 255.0, g: ((v >> 8) & 0xff) as f32 / 255.0, b: (v & 0xff) as f32 / 255.0, a }
}

pub const fn with_alpha(c: D2D1_COLOR_F, a: f32) -> D2D1_COLOR_F {
    D2D1_COLOR_F { a, ..c }
}

pub const PRIMARY: D2D1_COLOR_F = rgb(0xc2c1ff);
pub const ON_PRIMARY: D2D1_COLOR_F = rgb(0x2a2a60);
pub const PRIMARY_CONTAINER: D2D1_COLOR_F = rgb(0x7171ac);
pub const SECONDARY: D2D1_COLOR_F = rgb(0xc6c4e0);
pub const ERROR: D2D1_COLOR_F = rgb(0xffb4ab);
pub const SURFACE: D2D1_COLOR_F = rgb(0x201f23);
pub const SURFACE_VARIANT: D2D1_COLOR_F = rgb(0x2a292e);
pub const ON_SURFACE: D2D1_COLOR_F = rgb(0xe5e1e7);
pub const ON_SURFACE_VARIANT: D2D1_COLOR_F = rgb(0xc8c5d1);
pub const HOVER: D2D1_COLOR_F = rgb(0x45455c);
pub const ON_HOVER: D2D1_COLOR_F = rgb(0xb4b2ce);
pub const CAPSULE_BORDER: D2D1_COLOR_F = rgb(0x21215f);
/// Saturated red for the record button and live indicator.
pub const RECORD: D2D1_COLOR_F = rgb(0xff5449);
pub const WHITE: D2D1_COLOR_F = rgb(0xffffff);
pub const BLACK: D2D1_COLOR_F = rgb(0x000000);

#[derive(Clone, Copy)]
pub struct Palette {
    pub surface: D2D1_COLOR_F,
    pub surface_variant: D2D1_COLOR_F,
    pub on_surface: D2D1_COLOR_F,
    pub on_surface_variant: D2D1_COLOR_F,
    pub primary: D2D1_COLOR_F,
    pub on_primary: D2D1_COLOR_F,
    pub primary_container: D2D1_COLOR_F,
    pub secondary: D2D1_COLOR_F,
    pub hover: D2D1_COLOR_F,
    pub on_hover: D2D1_COLOR_F,
    pub outline: D2D1_COLOR_F,
    pub error: D2D1_COLOR_F,
    pub record: D2D1_COLOR_F,
    pub radius_small: f32,
    pub radius_normal: f32,
    pub radius_large: f32,
}

impl Default for Palette {
    fn default() -> Self {
        Self {
            surface: SURFACE,
            surface_variant: SURFACE_VARIANT,
            on_surface: ON_SURFACE,
            on_surface_variant: ON_SURFACE_VARIANT,
            primary: PRIMARY,
            on_primary: ON_PRIMARY,
            primary_container: PRIMARY_CONTAINER,
            secondary: SECONDARY,
            hover: HOVER,
            on_hover: ON_HOVER,
            outline: CAPSULE_BORDER,
            error: ERROR,
            record: RECORD,
            radius_small: 8.0,
            radius_normal: 9.0,
            radius_large: 20.0,
        }
    }
}
