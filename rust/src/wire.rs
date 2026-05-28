//! Wire format: fixed 24-byte little-endian records (see `spec/protocol.md`).

pub const T_ADD: u8 = 0;
pub const T_CANCEL: u8 = 1;
pub const T_REPLACE: u8 = 2;
pub const T_MARKET: u8 = 3;

/// One decoded message. Plain `Copy` struct — decoding is just field reads, no allocation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Msg {
    pub msg_type: u8,
    pub side: u8,
    pub order_id: u32,
    pub price: u32,
    pub qty: u32,
    pub new_price: u32,
    pub new_qty: u32,
}

impl Msg {
    /// Decode a 24-byte record. Caller guarantees `b.len() >= 24`.
    #[inline(always)]
    pub fn decode(b: &[u8]) -> Msg {
        let r = |o: usize| u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]);
        Msg {
            msg_type: b[0],
            side: b[1],
            order_id: r(4),
            price: r(8),
            qty: r(12),
            new_price: r(16),
            new_qty: r(20),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_reads_little_endian_fields() {
        let mut b = [0u8; 24];
        b[0] = T_REPLACE;
        b[1] = 1;
        b[4..8].copy_from_slice(&0x0102_0304u32.to_le_bytes());
        b[8..12].copy_from_slice(&10_000u32.to_le_bytes());
        b[12..16].copy_from_slice(&7u32.to_le_bytes());
        b[16..20].copy_from_slice(&9_999u32.to_le_bytes());
        b[20..24].copy_from_slice(&11u32.to_le_bytes());
        let m = Msg::decode(&b);
        assert_eq!(
            m,
            Msg { msg_type: T_REPLACE, side: 1, order_id: 0x0102_0304, price: 10_000, qty: 7, new_price: 9_999, new_qty: 11 }
        );
    }
}
