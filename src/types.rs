use alloc::vec::Vec;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Ord, PartialOrd)]
pub struct PeerId(pub [u8; 32]);

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct View(pub u64);

impl View {
    pub fn genesis() -> Self {
        Self(0)
    }

    /// Returns the next view.
    pub fn next(&self) -> Self {
        Self(self.0 + 1)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct BlockHash(pub [u8; 32]);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Ord, PartialOrd)]
pub struct TransactionHash(pub [u8; 32]);

/// Represents a non-dummy block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Block {
    pub view: View,
    pub parent_view: View,
    pub transactions: Vec<TransactionHash>,
    pub block_hash: BlockHash,
}

impl Block {
    pub(crate) fn new(
        view: View,
        parent_view: View,
        transactions: Vec<TransactionHash>,
        block_hash: BlockHash,
    ) -> Self {
        Self {
            view,
            parent_view,
            transactions,
            block_hash,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TimerId(pub u64);

impl From<View> for TimerId {
    fn from(view: View) -> Self {
        Self(view.0)
    }
}
