//! 滚轮换算。Windows 以 120 为一格（高精度滚轮和触控板会给出不足一格的值）；
//! macOS 分行滚动（普通滚轮）和像素滚动（触控板、妙控鼠标）。两边都是正值表示往上滚，
//! 水平方向 macOS 正值往左、Windows 正值往右

use crate::message::ScrollEvent;

pub const WHEEL_DELTA: f64 = 120.0;
/// 像素滚动换成滚轮单位：Windows 上大多数应用一格（120）滚 100 像素左右
const WHEEL_PER_PIXEL: f64 = 1.2;
/// Windows 滚轮单位换成 macOS 像素时，一行按 10 像素算（与 macOS 行滚动的像素量级一致）
const PIXELS_PER_LINE: f64 = 10.0;

/// Mac → Windows：把 macOS 滚动事件换成 Windows 滚轮量，不足 1 的部分累积到下次
#[derive(Default)]
pub struct ToWindows {
    vertical: f64,
    horizontal: f64,
}

impl ToWindows {
    /// 返回 (垂直, 水平) 滚轮量，单位 1/120 格
    pub fn convert(&mut self, s: &ScrollEvent) -> (i32, i32) {
        let (v, h) = if s.is_continuous {
            (s.point_delta_axis1 as f64 * WHEEL_PER_PIXEL, -(s.point_delta_axis2 as f64) * WHEEL_PER_PIXEL)
        } else {
            (s.delta_axis1 as f64 * WHEEL_DELTA, -(s.delta_axis2 as f64) * WHEEL_DELTA)
        };
        self.vertical += v;
        self.horizontal += h;
        // 加一点余量再截断，免得 5 × 1.2 累加成 5.9999… 少滚一个单位
        let whole = |x: f64| (x + 1e-9 * x.signum()).trunc();
        let out = (whole(self.vertical), whole(self.horizontal));
        self.vertical -= out.0;
        self.horizontal -= out.1;
        (out.0 as i32, out.1 as i32)
    }
}

/// Windows → Mac：一次滚轮消息换成 macOS 滚动事件。
/// lines_per_notch 是 Windows 设置里的「一次滚动的行数」，整格滚动按它换成行数，保持 Windows 用户习惯的速度
pub fn from_windows(vertical: i32, horizontal: i32, lines_per_notch: u32) -> ScrollEvent {
    let lines = if lines_per_notch == 0 || lines_per_notch > 100 { 3 } else { lines_per_notch } as f64;
    let whole = vertical % 120 == 0 && horizontal % 120 == 0;
    if whole {
        let v = (vertical as f64 / WHEEL_DELTA * lines) as i32;
        let h = (-(horizontal as f64) / WHEEL_DELTA * lines) as i32;
        return ScrollEvent {
            delta_axis1: v,
            delta_axis2: h,
            point_delta_axis1: (v as f64 * PIXELS_PER_LINE) as i32,
            point_delta_axis2: (h as f64 * PIXELS_PER_LINE) as i32,
            fixed_delta_axis1: v as f64,
            fixed_delta_axis2: h as f64,
            is_continuous: false,
            scroll_phase: 0,
            momentum_phase: 0,
        };
    }
    // 高精度滚轮 / 触控板：换成像素滚动
    let pv = vertical as f64 / WHEEL_PER_PIXEL;
    let ph = -(horizontal as f64) / WHEEL_PER_PIXEL;
    ScrollEvent {
        delta_axis1: (pv / PIXELS_PER_LINE).round() as i32,
        delta_axis2: (ph / PIXELS_PER_LINE).round() as i32,
        point_delta_axis1: pv.round() as i32,
        point_delta_axis2: ph.round() as i32,
        fixed_delta_axis1: pv / PIXELS_PER_LINE,
        fixed_delta_axis2: ph / PIXELS_PER_LINE,
        is_continuous: true,
        scroll_phase: 0,
        momentum_phase: 0,
    }
}
