//! 点、矩形与桌面，语义对齐 CoreGraphics：左上角为原点，y 向下，矩形含左上边不含右下边

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl Point {
    pub const ZERO: Point = Point { x: 0.0, y: 0.0 };

    pub fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }

    pub fn distance(self, other: Point) -> f64 {
        (self.x - other.x).hypot(self.y - other.y)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub const ZERO: Rect = Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };

    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        Rect { x, y, w, h }
    }

    pub fn min_x(&self) -> f64 {
        self.x
    }
    pub fn min_y(&self) -> f64 {
        self.y
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.w
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.h
    }
    pub fn mid_x(&self) -> f64 {
        self.x + self.w / 2.0
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.h / 2.0
    }
    pub fn origin(&self) -> Point {
        Point::new(self.x, self.y)
    }

    pub fn is_empty(&self) -> bool {
        self.w <= 0.0 || self.h <= 0.0
    }

    pub fn contains(&self, p: Point) -> bool {
        p.x >= self.min_x() && p.x < self.max_x() && p.y >= self.min_y() && p.y < self.max_y()
    }

    pub fn offset(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.w, self.h)
    }

    pub fn inset(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.w - 2.0 * dx, self.h - 2.0 * dy)
    }

    pub fn union(&self, o: &Rect) -> Rect {
        let x = self.min_x().min(o.min_x());
        let y = self.min_y().min(o.min_y());
        Rect::new(x, y, self.max_x().max(o.max_x()) - x, self.max_y().max(o.max_y()) - y)
    }

    /// 相交部分；不相交时返回 None
    pub fn intersection(&self, o: &Rect) -> Option<Rect> {
        let x = self.min_x().max(o.min_x());
        let y = self.min_y().max(o.min_y());
        let r = self.max_x().min(o.max_x());
        let b = self.max_y().min(o.max_y());
        (r >= x && b >= y).then(|| Rect::new(x, y, r - x, b - y))
    }
}

/// 屏幕的一条边
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}

impl Edge {
    pub const ALL: [Edge; 4] = [Edge::Left, Edge::Right, Edge::Top, Edge::Bottom];

    pub fn opposite(self) -> Edge {
        match self {
            Edge::Left => Edge::Right,
            Edge::Right => Edge::Left,
            Edge::Top => Edge::Bottom,
            Edge::Bottom => Edge::Top,
        }
    }
}

/// 一台机器的全部显示器，坐标单位是逻辑点（Mac 的点；Windows 上按缩放比换算，见 dpi 模块）
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Desktop {
    pub displays: Vec<Rect>,
}

impl Desktop {
    pub fn new(displays: Vec<Rect>) -> Self {
        Desktop { displays }
    }

    pub fn display_containing(&self, p: Point) -> Option<Rect> {
        self.displays.iter().copied().find(|d| d.contains(p))
    }

    /// 把点收回到最近的显示器内
    pub fn clamp(&self, p: Point) -> Point {
        if self.displays.is_empty() || self.display_containing(p).is_some() {
            return p;
        }
        let mut best = p;
        let mut best_distance = f64::INFINITY;
        for d in &self.displays {
            let q = Point::new(p.x.max(d.min_x()).min(d.max_x() - 1.0), p.y.max(d.min_y()).min(d.max_y() - 1.0));
            let distance = q.distance(p);
            if distance < best_distance {
                best = q;
                best_distance = distance;
            }
        }
        best
    }

    /// 点是否贴在整个桌面的外沿 edge 上（边外没有其他显示器）
    pub fn is_at_edge(&self, p: Point, edge: Edge) -> bool {
        let q = self.clamp(p);
        let Some(d) = self.display_containing(q) else { return false };
        let beyond = match edge {
            Edge::Left => {
                if q.x >= d.min_x() + 1.0 {
                    return false;
                }
                Point::new(d.min_x() - 1.0, q.y)
            }
            Edge::Right => {
                if q.x < d.max_x() - 2.0 {
                    return false;
                }
                Point::new(d.max_x() + 1.0, q.y)
            }
            Edge::Top => {
                if q.y >= d.min_y() + 1.0 {
                    return false;
                }
                Point::new(q.x, d.min_y() - 1.0)
            }
            Edge::Bottom => {
                if q.y < d.max_y() - 2.0 {
                    return false;
                }
                Point::new(q.x, d.max_y() + 1.0)
            }
        };
        self.display_containing(beyond).is_none()
    }

    /// 所有显示器的外框
    pub fn bounds(&self) -> Rect {
        let mut it = self.displays.iter();
        let Some(first) = it.next() else { return Rect::ZERO };
        it.fold(*first, |acc, d| acc.union(d))
    }

    /// 主屏（原点在 (0,0)）
    pub fn main(&self) -> Option<Rect> {
        self.displays.iter().copied().find(|d| d.origin() == Point::ZERO).or_else(|| self.displays.first().copied())
    }

    /// 光标贴在桌面外沿并继续往外推时，返回推出去的那个点（紧贴边外）；没有推出桌面返回 None
    pub fn point_beyond(&self, p: Point, dx: f64, dy: f64) -> Option<Point> {
        let q0 = self.clamp(p);
        let d = self.display_containing(q0)?;
        let mut q = Point::new(q0.x + dx, q0.y + dy);
        let mut pushed = false;
        if dx > 0.0 && self.is_at_edge(q0, Edge::Right) {
            q.x = q.x.max(d.max_x());
            pushed = true;
        }
        if dx < 0.0 && self.is_at_edge(q0, Edge::Left) {
            q.x = q.x.min(d.min_x() - 0.5);
            pushed = true;
        }
        if dy > 0.0 && self.is_at_edge(q0, Edge::Bottom) {
            q.y = q.y.max(d.max_y());
            pushed = true;
        }
        if dy < 0.0 && self.is_at_edge(q0, Edge::Top) {
            q.y = q.y.min(d.min_y() - 0.5);
            pushed = true;
        }
        (pushed && self.display_containing(q).is_none()).then_some(q)
    }
}
