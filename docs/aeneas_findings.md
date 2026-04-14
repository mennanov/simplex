# A list of things in Aeneas to be aware of

## `hashbrown` crate can't be used

I can't use the `hashbrown` crate for `no_std` compatible hashmaps as it produces the following error:
`Arrow types are not supported yet`.

According to Clause Opus 4.5: _because Aeneas's supported Rust subset intentionally omits closures, and
hashbrown's HashMap takes a hasher as a generic parameter with `Fn` trait bounds — which Aeneas sees as arrow types
(function types like `A → B`) that it can't translate to Lean._
