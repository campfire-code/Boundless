//! Windows 显示器坐标换算。Windows（开启 Per-Monitor DPI 感知后）用物理像素，Mac 用逻辑点。
//! 协议里的屏幕布局和光标位置一律用逻辑点（物理像素 ÷ 缩放比），这样在排列窗口里两边屏幕大小相称。
//! 几块屏缩放比不同时，各自除以缩放比会错位，这里沿着相邻的边把逻辑布局重新拼起来

use crate::geometry::{Desktop, Point, Rect};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Monitor {
    /// 物理像素，虚拟桌面坐标（主屏左上角为原点）
    pub physical: Rect,
    /// 缩放比，DPI ÷ 96
    pub scale: f64,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Layout {
    monitors: Vec<(Monitor, Rect)>,
}

impl Layout {
    pub fn new(monitors: &[Monitor]) -> Layout {
        let n = monitors.len();
        let mut logical: Vec<Option<Rect>> = vec![None; n];
        if n == 0 {
            return Layout::default();
        }
        let scaled = |m: &Monitor| {
            let r = m.physical;
            Rect::new(r.x / m.scale, r.y / m.scale, r.w / m.scale, r.h / m.scale)
        };
        let primary = monitors.iter().position(|m| m.physical.origin() == Point::ZERO).unwrap_or(0);
        logical[primary] = Some(scaled(&monitors[primary]));
        loop {
            let mut progressed = false;
            for i in 0..n {
                if logical[i].is_some() {
                    continue;
                }
                let m = &monitors[i];
                for j in 0..n {
                    let Some(lj) = logical[j] else { continue };
                    if let Some(r) = attach(m, &monitors[j], lj) {
                        logical[i] = Some(r);
                        progressed = true;
                        break;
                    }
                }
            }
            if !progressed {
                break;
            }
        }
        // 和其他屏幕都不相邻的，直接按自己的缩放比换算
        let monitors = monitors.iter().zip(logical).map(|(m, l)| (*m, l.unwrap_or_else(|| scaled(m)))).collect();
        Layout { monitors }
    }

    /// 逻辑布局，可直接作为 Desktop 上报给对端
    pub fn desktop(&self) -> Desktop {
        Desktop::new(self.monitors.iter().map(|(_, l)| *l).collect())
    }

    pub fn is_empty(&self) -> bool {
        self.monitors.is_empty()
    }

    /// 逻辑点 → 物理像素（点不在任何屏上时先收到最近的屏里）
    pub fn to_physical(&self, p: Point) -> Point {
        let p = self.desktop().clamp(p);
        let Some((m, l)) = self.monitors.iter().find(|(_, l)| l.contains(p)).or(self.monitors.first()) else { return p };
        Point::new(m.physical.x + (p.x - l.x) * m.scale, m.physical.y + (p.y - l.y) * m.scale)
    }

    /// 物理像素 → 逻辑点
    pub fn to_logical(&self, p: Point) -> Point {
        let Some((m, l)) = self.monitor_at_physical(p) else { return p };
        Point::new(l.x + (p.x - m.physical.x) / m.scale, l.y + (p.y - m.physical.y) / m.scale)
    }

    /// 物理像素位置所在屏的缩放比，用来把物理位移换成逻辑位移
    pub fn scale_at_physical(&self, p: Point) -> f64 {
        self.monitor_at_physical(p).map_or(1.0, |(m, _)| m.scale)
    }

    fn monitor_at_physical(&self, p: Point) -> Option<&(Monitor, Rect)> {
        self.monitors.iter().find(|(m, _)| m.physical.contains(p)).or_else(|| {
            self.monitors.iter().min_by(|a, b| {
                let da = Desktop::new(vec![a.0.physical]).clamp(p).distance(p);
                let db = Desktop::new(vec![b.0.physical]).clamp(p).distance(p);
                da.total_cmp(&db)
            })
        })
    }
}

/// m 若与已排好的 n 贴边，返回 m 的逻辑矩形：贴合的方向接在 n 的逻辑边上，错开的距离按 n 的缩放比换算
fn attach(m: &Monitor, n: &Monitor, ln: Rect) -> Option<Rect> {
    let (pm, pn) = (m.physical, n.physical);
    let (w, h) = (pm.w / m.scale, pm.h / m.scale);
    let touches = |a: f64, b: f64| (a - b).abs() <= 1.0;
    let overlap_y = pm.min_y() < pn.max_y() && pm.max_y() > pn.min_y();
    let overlap_x = pm.min_x() < pn.max_x() && pm.max_x() > pn.min_x();
    let y = ln.y + (pm.y - pn.y) / n.scale;
    let x = ln.x + (pm.x - pn.x) / n.scale;
    if overlap_y && touches(pm.min_x(), pn.max_x()) {
        return Some(Rect::new(ln.max_x(), y, w, h));
    }
    if overlap_y && touches(pm.max_x(), pn.min_x()) {
        return Some(Rect::new(ln.min_x() - w, y, w, h));
    }
    if overlap_x && touches(pm.min_y(), pn.max_y()) {
        return Some(Rect::new(x, ln.max_y(), w, h));
    }
    if overlap_x && touches(pm.max_y(), pn.min_y()) {
        return Some(Rect::new(x, ln.min_y() - h, w, h));
    }
    None
}
