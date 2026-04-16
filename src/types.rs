use alloc::vec::Vec;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Ord, PartialOrd)]
pub struct PeerId([u8; 32]);

impl PeerId {
    pub fn new(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct View(u64);

impl View {
    pub fn new(n: u64) -> Self {
        Self(n)
    }

    pub fn genesis() -> Self {
        Self(0)
    }

    /// Returns the next view.
    pub fn next(&self) -> Self {
        Self(self.0 + 1)
    }

    pub fn as_u64(&self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct BlockHash([u8; 32]);

impl BlockHash {
    pub fn new(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Ord, PartialOrd)]
pub struct TransactionHash([u8; 32]);

impl TransactionHash {
    pub fn new(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

/// Represents a non-dummy block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Block {
    view: View,
    parent_view: View,
    transactions: Vec<TransactionHash>,
    block_hash: BlockHash,
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

    pub fn view(&self) -> View {
        self.view
    }

    pub fn parent_view(&self) -> View {
        self.parent_view
    }

    pub fn transactions(&self) -> &[TransactionHash] {
        &self.transactions
    }

    pub fn block_hash(&self) -> BlockHash {
        self.block_hash
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TimerId(u64);

impl TimerId {
    pub fn new(id: u64) -> Self {
        Self(id)
    }

    pub fn as_u64(&self) -> u64 {
        self.0
    }
}

impl From<View> for TimerId {
    fn from(view: View) -> Self {
        Self(view.as_u64())
    }
}
