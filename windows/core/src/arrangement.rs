//! 被控端屏幕在主控端坐标系中的摆放位置（相当于系统设置里的「显示器排列」），与 Swift 版 Arrangement.swift 一致

use crate::geometry::{Desktop, Edge, Point, Rect};

#[derive(Debug, Clone, PartialEq)]
pub struct Arrangement {
    /// 被控端自己的显示器，使用被控端的坐标
    pub client_displays: Vec<Rect>,
    /// 被控端桌面外框的左上角，放在主控端坐标系中的位置
    pub origin: Point,
}

/// 两块屏幕贴合的一段边，光标只能从这里穿过
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Segment {
    pub from: Point,
    pub to: Point,
}

impl Arrangement {
    pub fn new(client_displays: Vec<Rect>, origin: Point) -> Self {
        Arrangement { client_displays, origin }
    }

    pub fn client_bounds(&self) -> Rect {
        Desktop::new(self.client_displays.clone()).bounds()
    }

    pub fn placed_bounds(&self) -> Rect {
        let b = self.client_bounds();
        Rect::new(self.origin.x, self.origin.y, b.w, b.h)
    }

    pub fn placed_displays(&self) -> Vec<Rect> {
        let (dx, dy) = self.shift();
        self.client_displays.iter().map(|d| d.offset(dx, dy)).collect()
    }

    fn shift(&self) -> (f64, f64) {
        let b = self.client_bounds();
        (self.origin.x - b.min_x(), self.origin.y - b.min_y())
    }

    pub fn to_server(&self, p: Point) -> Point {
        let (dx, dy) = self.shift();
        Point::new(p.x + dx, p.y + dy)
    }

    pub fn to_client(&self, p: Point) -> Point {
        let (dx, dy) = self.shift();
        Point::new(p.x - dx, p.y - dy)
    }

    /// 主控端坐标上的点若落在被控端某块屏幕上，返回它在被控端的坐标
    pub fn client_point_at_server(&self, p: Point) -> Option<Point> {
        self.placed_displays().iter().any(|d| d.contains(p)).then(|| self.to_client(p))
    }

    /// 被控端上离主控端某点最近的位置（快捷键切换时的落点）
    pub fn nearest_client_point(&self, server_point: Point) -> Point {
        Desktop::new(self.client_displays.clone()).clamp(self.to_client(server_point))
    }

    /// 被控端整体位于主控端的哪一侧，决定切换快捷键的方向
    pub fn side(&self, server: &Desktop) -> Edge {
        let s = server.bounds();
        let c = self.placed_bounds();
        if c.min_x() >= s.max_x() - 1.0 {
            return Edge::Right;
        }
        if c.max_x() <= s.min_x() + 1.0 {
            return Edge::Left;
        }
        if c.max_y() <= s.min_y() + 1.0 {
            return Edge::Top;
        }
        if c.min_y() >= s.max_y() - 1.0 {
            return Edge::Bottom;
        }
        let dx = c.mid_x() - s.mid_x();
        let dy = c.mid_y() - s.mid_y();
        if dx.abs() >= dy.abs() {
            if dx > 0.0 {
                Edge::Right
            } else {
                Edge::Left
            }
        } else if dy > 0.0 {
            Edge::Bottom
        } else {
            Edge::Top
        }
    }

    pub fn shared_edges(&self, server: &Desktop) -> Vec<Segment> {
        let mut segments = Vec::new();
        for c in self.placed_displays() {
            for s in &server.displays {
                for x in [s.max_x(), s.min_x()] {
                    if (c.min_x() - x).abs() < 0.5 || (c.max_x() - x).abs() < 0.5 {
                        let lo = c.min_y().max(s.min_y());
                        let hi = c.max_y().min(s.max_y());
                        if hi > lo {
                            segments.push(Segment { from: Point::new(x, lo), to: Point::new(x, hi) });
                        }
                    }
                }
                for y in [s.max_y(), s.min_y()] {
                    if (c.min_y() - y).abs() < 0.5 || (c.max_y() - y).abs() < 0.5 {
                        let lo = c.min_x().max(s.min_x());
                        let hi = c.max_x().min(s.max_x());
                        if hi > lo {
                            segments.push(Segment { from: Point::new(lo, y), to: Point::new(hi, y) });
                        }
                    }
                }
            }
        }
        segments
    }

    /// 默认放在主控端右侧，与主屏垂直居中
    pub fn default_placement(client_displays: Vec<Rect>, server: &Desktop) -> Arrangement {
        let size = Desktop::new(client_displays.clone()).bounds();
        let main = server.main().unwrap_or(Rect::ZERO);
        let placed = Arrangement::new(client_displays, Point::new(server.bounds().max_x(), main.mid_y() - size.h / 2.0));
        placed.snapped(server, 40.0)
    }

    /// 吸附到最近的主控端屏幕边上：贴边、至少重叠 min_overlap、不与主控端屏幕重叠
    pub fn snapped(&self, server: &Desktop, min_overlap: f64) -> Arrangement {
        let b = self.placed_bounds();
        let mut best: Option<Arrangement> = None;
        let mut best_distance = f64::INFINITY;
        for s in &server.displays {
            let oy = min_overlap.min(s.h).min(b.h);
            let ox = min_overlap.min(s.w).min(b.w);
            let y = b.min_y().max(s.min_y() - b.h + oy).min(s.max_y() - oy);
            let x = b.min_x().max(s.min_x() - b.w + ox).min(s.max_x() - ox);
            let candidates = [
                Point::new(s.max_x(), y),
                Point::new(s.min_x() - b.w, y),
                Point::new(x, s.max_y()),
                Point::new(x, s.min_y() - b.h),
            ];
            for o in candidates {
                let candidate = Arrangement::new(self.client_displays.clone(), o);
                if candidate.overlaps(server) {
                    continue;
                }
                let distance = o.distance(b.origin());
                if distance < best_distance {
                    best = Some(candidate);
                    best_distance = distance;
                }
            }
        }
        best.unwrap_or_else(|| self.clone())
    }

    fn overlaps(&self, server: &Desktop) -> bool {
        self.placed_displays().iter().any(|c| {
            server.displays.iter().any(|s| matches!(c.intersection(s), Some(i) if i.w > 0.5 && i.h > 0.5))
        })
    }
}
