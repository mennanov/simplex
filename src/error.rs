use core::fmt;

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    InvalidMessage,
    QuorumNotReached,
    UnknownPlayer,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::format;

    #[test]
    fn display_invalid_message() {
        assert_eq!(format!("{}", Error::InvalidMessage), "InvalidMessage");
    }

    #[test]
    fn display_quorum_not_reached() {
        assert_eq!(format!("{}", Error::QuorumNotReached), "QuorumNotReached");
    }

    #[test]
    fn display_unknown_player() {
        assert_eq!(format!("{}", Error::UnknownPlayer), "UnknownPlayer");
    }
}
