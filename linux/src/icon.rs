//! Procedural tray icon: a severity-coloured disc with the day count on top.
//!
//! Drawn by hand rather than with an image/font crate so the binary carries no
//! asset files and no font dependency.

use crate::state::Status;

const SIZE: i32 = 24;
const RADIUS: f32 = 11.0;
const TRANSPARENT: u32 = 0x0000_0000;
const FOREGROUND: u32 = 0xFFFF_FFFF;

const GLYPH_WIDTH: i32 = 3;
const GLYPH_HEIGHT: i32 = 5;
/// A 3x5 bitmap per digit, one byte per row, low 3 bits used.
const DIGITS: [[u8; GLYPH_HEIGHT as usize]; 10] = [
    [0b111, 0b101, 0b101, 0b101, 0b111], // 0
    [0b010, 0b110, 0b010, 0b010, 0b111], // 1
    [0b111, 0b001, 0b111, 0b100, 0b111], // 2
    [0b111, 0b001, 0b111, 0b001, 0b111], // 3
    [0b101, 0b101, 0b111, 0b001, 0b001], // 4
    [0b111, 0b100, 0b111, 0b001, 0b111], // 5
    [0b111, 0b100, 0b111, 0b101, 0b111], // 6
    [0b111, 0b001, 0b001, 0b001, 0b001], // 7
    [0b111, 0b101, 0b111, 0b101, 0b111], // 8
    [0b111, 0b101, 0b111, 0b001, 0b111], // 9
];

pub fn render(status: &Status) -> ksni::Icon {
    let mut pixels = vec![TRANSPARENT; (SIZE * SIZE) as usize];
    draw_disc(&mut pixels, status.color());

    if let Status::Days { days, .. } = status {
        // Three digits will not fit legibly at 24px, so cap the label.
        draw_digits(&mut pixels, &(*days).clamp(0, 99).to_string());
    }

    let mut data = Vec::with_capacity(pixels.len() * 4);
    for pixel in pixels {
        // ARGB32, network byte order.
        data.extend_from_slice(&pixel.to_be_bytes());
    }

    ksni::Icon {
        width: SIZE,
        height: SIZE,
        data,
    }
}

fn draw_disc(pixels: &mut [u32], color: u32) {
    let center = (SIZE as f32 - 1.0) / 2.0;
    for y in 0..SIZE {
        for x in 0..SIZE {
            let dx = x as f32 - center;
            let dy = y as f32 - center;
            if dx * dx + dy * dy <= RADIUS * RADIUS {
                set(pixels, x, y, color);
            }
        }
    }
}

fn draw_digits(pixels: &mut [u32], label: &str) {
    let digits: Vec<usize> = label
        .chars()
        .filter_map(|c| c.to_digit(10).map(|d| d as usize))
        .collect();
    if digits.is_empty() {
        return;
    }

    // One digit gets a 3x scale; two digits fit at 2x with a 2px gap.
    let (scale, gap) = if digits.len() == 1 { (3, 0) } else { (2, 2) };
    let glyph_width = GLYPH_WIDTH * scale;
    let total_width = glyph_width * digits.len() as i32 + gap * (digits.len() as i32 - 1);
    let origin_x = (SIZE - total_width) / 2;
    let origin_y = (SIZE - GLYPH_HEIGHT * scale) / 2;

    for (index, digit) in digits.iter().enumerate() {
        let left = origin_x + index as i32 * (glyph_width + gap);
        draw_glyph(pixels, DIGITS[*digit], left, origin_y, scale);
    }
}

fn draw_glyph(
    pixels: &mut [u32],
    glyph: [u8; GLYPH_HEIGHT as usize],
    left: i32,
    top: i32,
    scale: i32,
) {
    for (row, bits) in glyph.iter().enumerate() {
        for column in 0..GLYPH_WIDTH {
            let lit = bits & (1 << (GLYPH_WIDTH - 1 - column)) != 0;
            if !lit {
                continue;
            }
            for dy in 0..scale {
                for dx in 0..scale {
                    let x = left + column * scale + dx;
                    let y = top + row as i32 * scale + dy;
                    set(pixels, x, y, FOREGROUND);
                }
            }
        }
    }
}

fn set(pixels: &mut [u32], x: i32, y: i32, color: u32) {
    if x < 0 || y < 0 || x >= SIZE || y >= SIZE {
        return;
    }
    pixels[(y * SIZE + x) as usize] = color;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{Severity, COLOR_NEUTRAL, COLOR_OVERDUE};

    fn pixel_at(icon: &ksni::Icon, x: i32, y: i32) -> u32 {
        let offset = ((y * icon.width + x) * 4) as usize;
        u32::from_be_bytes(icon.data[offset..offset + 4].try_into().unwrap())
    }

    #[test]
    fn icon_has_the_declared_dimensions() {
        let icon = render(&Status::NoData);
        assert_eq!(icon.width, SIZE);
        assert_eq!(icon.height, SIZE);
        assert_eq!(icon.data.len(), (SIZE * SIZE * 4) as usize);
    }

    #[test]
    fn corners_stay_transparent_and_the_disc_is_severity_coloured() {
        let icon = render(&Status::Days {
            days: 30,
            severity: Severity::Overdue,
            issue_key: None,
        });
        assert_eq!(pixel_at(&icon, 0, 0), TRANSPARENT);
        assert_eq!(pixel_at(&icon, SIZE - 1, SIZE - 1), TRANSPARENT);
        // Just inside the disc, clear of the digits.
        assert_eq!(pixel_at(&icon, 2, 12), COLOR_OVERDUE);
    }

    #[test]
    fn non_day_states_draw_a_plain_neutral_disc() {
        let icon = render(&Status::NoCredentials);
        assert_eq!(pixel_at(&icon, 12, 12), COLOR_NEUTRAL);
        assert!(!icon
            .data
            .chunks_exact(4)
            .any(|p| u32::from_be_bytes(p.try_into().unwrap()) == FOREGROUND));
    }

    #[test]
    fn day_counts_draw_foreground_pixels() {
        for days in [0, 5, 12, 99, 4_000] {
            let icon = render(&Status::Days {
                days,
                severity: Severity::Ok,
                issue_key: None,
            });
            assert!(
                icon.data
                    .chunks_exact(4)
                    .any(|p| u32::from_be_bytes(p.try_into().unwrap()) == FOREGROUND),
                "no digits drawn for {days} days"
            );
        }
    }
}
