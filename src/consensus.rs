use crate::message::{Finalize, Message, Proposal, Vote};
use crate::types::{Block, BlockHash, PeerId, TimerId, TransactionHash, View};
use alloc::collections::{BTreeMap, BTreeSet};
use alloc::vec::Vec;

#[derive(Debug, PartialEq)]
pub enum Event {
    MessageReceived(Message),
    TimerExpired(TimerId),
}

#[derive(Debug, PartialEq)]
pub enum Action {
    SendSigned { message: Message, to: PeerId },
    FinalizeBlock(Block),
    SetTimer(TimerId),
    CancelTimer(TimerId),
}

#[allow(dead_code)]
pub struct Consensus<L: LeaderElector> {
    // The leader elector is used to determine the leader for a given view.
    leader_elector: L,
    // The peer ID of this node.
    peer_id: PeerId,
    // All peers in the system.
    peers: Vec<PeerId>,
    // The current view.
    view: View,
    // BTreeMap(s) are used because they support efficient pruning of old views in O(log n)
    // via `split_off(view)` and are better optimized for storing sequential integer keys.
    notarizations: BTreeMap<View, BTreeMap<PeerId, Vote>>,
    dummy_votes: BTreeMap<View, BTreeMap<PeerId, Vote>>,
    finalizes: BTreeMap<View, Vec<Finalize>>,
    // Pending transactions to be proposed by this node when it becomes a leader.
    pending_transactions: BTreeSet<TransactionHash>,
}

impl<L: LeaderElector> Consensus<L> {
    pub fn new(peer_id: PeerId, peers: Vec<PeerId>, leader_checker: L) -> Self {
        Self {
            leader_elector: leader_checker,
            peer_id,
            peers,
            view: View::new(1),
            notarizations: BTreeMap::new(),
            dummy_votes: BTreeMap::new(),
            finalizes: BTreeMap::new(),
            pending_transactions: BTreeSet::new(),
        }
    }

    /// Handles an event from the system. Returns a list of actions to be performed by this node.
    pub fn handle_event(&mut self, event: Event) -> Vec<Action> {
        match event {
            Event::MessageReceived(msg) => {
                match msg {
                    Message::Vote(vote) => {
                        if vote.block_hash().is_none() {
                            // Vote for a dummy block.
                            let view = vote.view();
                            self.dummy_votes
                                .entry(vote.view())
                                .or_default()
                                .entry(vote.from())
                                .or_insert(vote);
                            if self.has_byzantine_quorum(self.dummy_votes[&view].len()) {
                                self.start_next_view()
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

    /// Schedules the `transaction` to be proposed by this node when it becomes a leader.
    pub fn propose(&mut self, transaction: TransactionHash) {
        self.pending_transactions.insert(transaction);
    }

    fn start_next_view(&mut self) -> Vec<Action> {
        self.view = self.view.next();
        let mut actions = Vec::from([Action::SetTimer(self.view.into())]);
        if self.leader_elector.leader(self.view, &self.peers) == &self.peer_id {
            actions.extend(self.broadcast_proposal());
        }
        actions
    }

    fn broadcast_proposal(&self) -> Vec<Action> {
        if !self.pending_transactions.is_empty() {
            let mut transactions = Vec::new();
            for tx in self.pending_transactions.iter() {
                transactions.push(*tx);
            }
            let mut actions = Vec::new();
            for peer_id in self.peers.iter() {
                if *peer_id != self.peer_id {
                    actions.push(Action::SendSigned {
                        message: Message::Propose(Proposal::new(
                            Block::new(
                                self.view,
                                View::genesis(), // TODO: compute correct parent view.
                                transactions.clone(),
                                BlockHash::default(), // TODO: compute correct block hash.
                            ),
                            self.peer_id,
                        )),
                        to: *peer_id,
                    });
                }
            }
            actions
        } else {
            Vec::new()
        }
    }

    fn has_byzantine_quorum(&self, v: usize) -> bool {
        v > self.peers.len() * 2 / 3
    }
}

/// Determines the leader for a given view in the system.
pub trait LeaderElector {
    /// Returns a leader for the given `view` among the given `peers`.
    fn leader<'a>(&self, view: View, peers: &'a [PeerId]) -> &'a PeerId;
}

pub struct RoundRobinLeaderChecker;

impl Default for RoundRobinLeaderChecker {
    fn default() -> Self {
        Self
    }
}

impl LeaderElector for RoundRobinLeaderChecker {
    fn leader<'a>(&self, view: View, peers: &'a [PeerId]) -> &'a PeerId {
        let leader_index = view.as_u64() % peers.len() as u64;
        &peers[leader_index as usize]
    }
}

#[cfg(test)]
mod tests {
    use crate::consensus::{Action, Consensus, Event, RoundRobinLeaderChecker};
    use crate::message::{Message, Vote};
    use crate::types::{PeerId, TimerId, TransactionHash, View};
    use alloc::vec;

    fn peers() -> [PeerId; 4] {
        [
            PeerId::new([0u8; 32]),
            PeerId::new([1u8; 32]),
            PeerId::new([2u8; 32]),
            PeerId::new([3u8; 32]),
        ]
    }

    #[test]
    fn when_dummy_certificate_is_obtained_then_timer_for_next_view_is_set() {
        let leader_checker = RoundRobinLeaderChecker;
        let [peer0, peer1, peer2, peer3] = peers();
        let mut consensus = Consensus::new(peer0, vec![peer0, peer1, peer2, peer3], leader_checker);

        let mut actions = consensus.handle_event(Event::MessageReceived(Message::Vote(Vote::new(
            View::new(1),
            None,
            peer0,
        ))));
        assert!(actions.is_empty());
        actions = consensus.handle_event(Event::MessageReceived(Message::Vote(Vote::new(
            View::new(1),
            None,
            peer1,
        ))));
        assert!(actions.is_empty());
        actions = consensus.handle_event(Event::MessageReceived(Message::Vote(Vote::new(
            View::new(1),
            None,
            peer2,
        ))));
        assert_eq!(actions.len(), 1);
        assert_eq!(actions[0], Action::SetTimer(TimerId::new(2)));
    }

    #[test]
    fn when_node_becomes_a_leader_then_proposals_are_broadcasted_to_peers() {
        let leader_checker = RoundRobinLeaderChecker;
        let [peer0, peer1, peer2, peer3] = peers();
        let mut consensus = Consensus::new(peer2, vec![peer0, peer1, peer2, peer3], leader_checker);
        let transaction = TransactionHash::new([0u8; 32]);

        consensus.propose(transaction);
        // Force a view change.
        consensus.handle_event(Event::MessageReceived(Message::Vote(Vote::new(
            View::new(1),
            None,
            peer0,
        ))));
        consensus.handle_event(Event::MessageReceived(Message::Vote(Vote::new(
            View::new(1),
            None,
            peer1,
        ))));
        let actions = consensus.handle_event(Event::MessageReceived(Message::Vote(Vote::new(
            View::new(1),
            None,
            peer2,
        ))));

        // The leader should broadcast the proposal to all other peers (peer0, peer1, peer3),
        // but NOT to itself.
        for peer in [peer0, peer1, peer3] {
            assert!(
                actions.iter().any(|action| matches!(
                    action,
                    Action::SendSigned { message: Message::Propose(proposal), to }
                        if *to == peer
                            && proposal.from() == peer2
                            && proposal.block().transactions().contains(&transaction)
                )),
                "expected proposal to be sent to {peer:?}"
            );
        }
    }
}
