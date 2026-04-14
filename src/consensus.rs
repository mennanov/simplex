use alloc::collections::BTreeMap;
use alloc::vec::Vec;

use crate::message::{Finalize, Message, Vote};
use crate::types::{Block, PeerId, TimerId, View};

#[derive(Debug, PartialEq)]
pub enum Event {
    MessageReceived(Message),
    TimerExpired(TimerId),
}

#[derive(Debug, PartialEq)]
pub enum Action {
    Broadcast(Message),
    FinalizeBlock(Block),
    SetTimer(TimerId),
    CancelTimer(TimerId),
}

#[allow(dead_code)]
pub struct Consensus {
    peer_id: PeerId,
    peers: Vec<PeerId>,
    view: View,
    notarizations: BTreeMap<View, BTreeMap<PeerId, Vote>>,
    dummy_votes: BTreeMap<View, BTreeMap<PeerId, Vote>>,
    finalizes: BTreeMap<View, Vec<Finalize>>,
}

impl Consensus {
    pub fn new(peer_id: PeerId, peers: Vec<PeerId>) -> Self {
        Self {
            peer_id,
            peers,
            view: View(1),
            notarizations: BTreeMap::new(),
            dummy_votes: BTreeMap::new(),
            finalizes: BTreeMap::new(),
        }
    }

    pub fn handle_event(&mut self, event: Event) -> Vec<Action> {
        match event {
            Event::MessageReceived(msg) => {
                match msg {
                    Message::Vote(vote) => {
                        if vote.block_hash.is_none() {
                            // Vote for a dummy block.
                            let view = vote.view;
                            self.dummy_votes
                                .entry(vote.view)
                                .or_default()
                                .entry(vote.from)
                                .or_insert(vote);
                            if self.has_byzantine_quorum(self.dummy_votes[&view].len()) {
                                // TODO: start a new view and forward actions from the new view.
                                Vec::from([Action::SetTimer(TimerId(self.view.0 + 1))])
                            } else {
                                Vec::new()
                            }
                        } else {
                            // TODO
                            Vec::new()
                        }
                    }
                    Message::Finalize(_) => {
                        // TODO
                        Vec::new()
                    }
                    _ => Vec::new(),
                }
            }
            Event::TimerExpired(_) => {
                // TODO.
                Vec::new()
            }
        }
    }

    fn has_byzantine_quorum(&self, v: usize) -> bool {
        let n = 4; //self.peers.len() + 1;
        v > n * 2 / 3
    }
}

#[cfg(test)]
mod tests {
    use crate::consensus::{Action, Consensus, Event};
    use crate::message::{Message, Vote};
    use crate::types::{PeerId, TimerId, View};
    use alloc::vec;

    fn peers() -> [PeerId; 4] {
        [
            PeerId([0u8; 32]),
            PeerId([1u8; 32]),
            PeerId([2u8; 32]),
            PeerId([3u8; 32]),
        ]
    }

    #[test]
    fn when_dummy_certificate_obtained_then_timer_for_next_view_is_set() {
        let [peer1, peer2, peer3, peer4] = peers();
        let mut consensus = Consensus::new(peer1, vec![peer2, peer3, peer4]);

        let mut actions = consensus.handle_event(Event::MessageReceived(Message::Vote(Vote {
            view: View(1),
            block_hash: None,
            from: peer1,
        })));
        assert!(actions.is_empty());
        actions = consensus.handle_event(Event::MessageReceived(Message::Vote(Vote {
            view: View(1),
            block_hash: None,
            from: peer2,
        })));
        assert!(actions.is_empty());
        actions = consensus.handle_event(Event::MessageReceived(Message::Vote(Vote {
            view: View(1),
            block_hash: None,
            from: peer3,
        })));
        assert_eq!(actions.len(), 1);
        assert_eq!(actions[0], Action::SetTimer(TimerId(2)));
    }
}
