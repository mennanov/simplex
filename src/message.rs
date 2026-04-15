use crate::types::{Block, BlockHash, PeerId, View};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proposal {
    pub block: Block,
    pub from: PeerId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Vote {
    pub view: View,
    /// `None` represents the dummy block ⊥ (timeout vote)
    pub block_hash: Option<BlockHash>,
    pub from: PeerId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finalize {
    pub view: View,
    pub from: PeerId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Message {
    Propose(Proposal),
    Vote(Vote),
    Finalize(Finalize),
}
