use crate::types::{Block, BlockHash, PeerId, View};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proposal {
    block: Block,
    from: PeerId,
}

impl Proposal {
    pub fn new(block: Block, from: PeerId) -> Self {
        Self { block, from }
    }

    pub fn block(&self) -> &Block {
        &self.block
    }

    pub fn from(&self) -> PeerId {
        self.from
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Vote {
    view: View,
    /// `None` represents the dummy block ⊥ (timeout vote)
    block_hash: Option<BlockHash>,
    from: PeerId,
}

impl Vote {
    pub fn new(view: View, block_hash: Option<BlockHash>, from: PeerId) -> Self {
        Self {
            view,
            block_hash,
            from,
        }
    }

    pub fn view(&self) -> View {
        self.view
    }

    pub fn block_hash(&self) -> Option<BlockHash> {
        self.block_hash
    }

    pub fn from(&self) -> PeerId {
        self.from
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finalize {
    view: View,
    from: PeerId,
}

impl Finalize {
    pub fn new(view: View, from: PeerId) -> Self {
        Self { view, from }
    }

    pub fn view(&self) -> View {
        self.view
    }

    pub fn from(&self) -> PeerId {
        self.from
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Message {
    Propose(Proposal),
    Vote(Vote),
    Finalize(Finalize),
}
