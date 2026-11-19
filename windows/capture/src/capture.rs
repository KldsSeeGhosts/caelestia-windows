//! Physical desktop rectangle shared by the recorder and its controls.

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct IRect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl IRect {
    pub fn intersect(&self, o: &IRect) -> Option<IRect> {
        let l = self.x.max(o.x);
        let t = self.y.max(o.y);
        let r = (self.x + self.w).min(o.x + o.w);
        let b = (self.y + self.h).min(o.y + o.h);
        (r > l && b > t).then_some(IRect { x: l, y: t, w: r - l, h: b - t })
    }
}
