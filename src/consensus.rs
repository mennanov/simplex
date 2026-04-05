use alloc::vec::Vec;
use hashbrown::HashMap;

use crate::error::Error;
use crate::message::{Finalize, Message, Vote};
use crate::types::{Block, BlockHash, Duration, Iteration, PlayerId, TimerId};

#[derive(Debug, PartialEq)]
pub enum Event {
    MessageReceived { from: PlayerId, msg: Message },
    TimerExpired(TimerId),
}

#[derive(Debug, PartialEq)]
pub enum Action {
    Send { to: PlayerId, msg: Message },
    Broadcast(Message),
    FinalizeBlock(Block),
    SetTimer(TimerId, Duration),
    CancelTimer(TimerId),
}

pub struct Consensus {
    #[allow(dead_code)]
    player_id: PlayerId,
    #[allow(dead_code)]
    players: Vec<PlayerId>,
    iteration: Iteration,
    #[allow(dead_code)]
    votes: HashMap<(Iteration, Option<BlockHash>), Vec<Vote>>,
    #[allow(dead_code)]
    finalizes: HashMap<Iteration, Vec<Finalize>>,
}

impl Consensus {
    pub fn new(player_id: PlayerId, players: Vec<PlayerId>) -> Self {
        Self {
            player_id,
            players,
            iteration: Iteration(1),
            votes: HashMap::new(),
            finalizes: HashMap::new(),
        }
    }

    pub fn current_iteration(&self) -> Iteration {
        self.iteration
    }

    pub fn handle_event(&mut self, event: Event) -> Result<Vec<Action>, Error> {
        let _ = event;
        Ok(Vec::new())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Iteration, PlayerId, TimerId};
    use alloc::vec;

    fn three_players() -> (PlayerId, Vec<PlayerId>) {
        let me = PlayerId(vec![1u8; 32]);
        let players = vec![
            PlayerId(vec![1u8; 32]),
            PlayerId(vec![2u8; 32]),
            PlayerId(vec![3u8; 32]),
        ];
        (me, players)
    }

    #[test]
    fn consensus_starts_at_iteration_one() {
        let (me, players) = three_players();
        let c = Consensus::new(me, players);
        assert_eq!(c.current_iteration(), Iteration(1));
    }

    #[test]
    fn handle_event_returns_ok_on_timer() {
        let (me, players) = three_players();
        let mut c = Consensus::new(me, players);
        let result = c.handle_event(Event::TimerExpired(TimerId(0)));
        assert!(result.is_ok());
    }
}
