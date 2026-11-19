//! Drawing helpers for the native recording controls.

use crate::gfx::wide;
use crate::theme::{self, *};
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::DirectWrite::*;
use windows_numerics::Vector2;

pub struct Ui<'a> {
    pub rt: &'a ID2D1RenderTarget,
    pub brush: &'a ID2D1SolidColorBrush,
    pub k: f32,
}

fn grow(r: &D2D_RECT_F, d: f32) -> D2D_RECT_F {
    D2D_RECT_F { left: r.left - d, top: r.top - d, right: r.right + d, bottom: r.bottom + d }
}

impl Ui<'_> {
    pub fn fill_rr(&self, r: &D2D_RECT_F, radius: f32, color: D2D1_COLOR_F) {
        unsafe {
            self.brush.SetColor(&color);
            self.rt.FillRoundedRectangle(&D2D1_ROUNDED_RECT { rect: *r, radiusX: radius, radiusY: radius }, self.brush);
        }
    }

    pub fn stroke_rr(&self, r: &D2D_RECT_F, radius: f32, color: D2D1_COLOR_F, width: f32) {
        let h = width / 2.0;
        let r = D2D_RECT_F { left: r.left + h, top: r.top + h, right: r.right - h, bottom: r.bottom - h };
        unsafe {
            self.brush.SetColor(&color);
            self.rt.DrawRoundedRectangle(
                &D2D1_ROUNDED_RECT { rect: r, radiusX: radius, radiusY: radius },
                self.brush,
                width,
                None::<&ID2D1StrokeStyle>,
            );
        }
    }

    pub fn fill_rect(&self, r: &D2D_RECT_F, color: D2D1_COLOR_F) {
        unsafe {
            self.brush.SetColor(&color);
            self.rt.FillRectangle(r, self.brush);
        }
    }

    pub fn circle(&self, cx: f32, cy: f32, radius: f32, fill: D2D1_COLOR_F, border: Option<(D2D1_COLOR_F, f32)>) {
        let e = D2D1_ELLIPSE { point: Vector2 { X: cx, Y: cy }, radiusX: radius, radiusY: radius };
        unsafe {
            self.brush.SetColor(&fill);
            self.rt.FillEllipse(&e, self.brush);
            if let Some((c, w)) = border {
                let e = D2D1_ELLIPSE { radiusX: radius - w / 2.0, radiusY: radius - w / 2.0, ..e };
                self.brush.SetColor(&c);
                self.rt.DrawEllipse(&e, self.brush, w, None::<&ID2D1StrokeStyle>);
            }
        }
    }

    pub fn text(&self, s: &str, r: &D2D_RECT_F, format: &IDWriteTextFormat, color: D2D1_COLOR_F) {
        unsafe {
            self.brush.SetColor(&color);
            self.rt.DrawText(&wide(s), format, r, self.brush, D2D1_DRAW_TEXT_OPTIONS_NONE, DWRITE_MEASURING_MODE_NATURAL);
        }
    }

    /// Soft drop shadow approximating the QML MultiEffect.
    pub fn shadow(&self, r: &D2D_RECT_F, radius: f32) {
        let k = self.k;
        let base = D2D_RECT_F { top: r.top + 3.0 * k, bottom: r.bottom + 3.0 * k, ..*r };
        for i in (1..=6).rev() {
            let d = i as f32 * 1.5 * k;
            self.fill_rr(&grow(&base, d), radius + d, theme::rgba(0x000000, 0.045));
        }
    }

    pub fn panel(&self, r: &D2D_RECT_F) {
        let radius = 20.0 * self.k;
        self.shadow(r, radius);
        self.fill_rr(r, radius, SURFACE);
        self.stroke_rr(r, radius, CAPSULE_BORDER, 1.0 * self.k);
    }
}
