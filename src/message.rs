use crate::types::{Block, BlockHash, Iteration, PlayerId};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proposal {
    pub iteration: Iteration,
    pub block: Block,
    pub from: PlayerId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Vote {
    pub iteration: Iteration,
    /// `None` represents the dummy block ⊥ (timeout vote)
    pub block_hash: Option<BlockHash>,
    pub from: PlayerId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finalize {
    pub iteration: Iteration,
    pub from: PlayerId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Message {
    Propose(Proposal),
    Vote(Vote),
    Finalize(Finalize),
}
