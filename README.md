- Sui v0.9.0

NFT liquidity layer is a suite of modules which aim to bring NFT trading across
marketplaces to a single point, thereby concentrating the liquidity into a
common interface.

# Build

```
$ sui move build
```

# Orderbook

_(Orderbook is not optimized yet)_

Orderbook implementation where bids are fungible tokens and asks are NFTs.
A bid is a request to buy one NFT from a specific collection.
An ask is one NFT with a min price condition.

`Ask` is an object which is associated with a single NFT.
When `Ask` is created, we transfer the ownership of the NFT to this
new object.
When an `Ask` is matched with a bid, we transfer the ownership of the
`ask` object to the bid owner (buyer).
The buyer can then claim the NFT via `claim_nft` endpoint.

One can:

- create a new orderbook between a given collection and a BID token (witness
  pattern protected)
- collect fees (witness pattern protected)
- set publicly accessible actions to be witness protected
- open a new BID
- cancel an existing BID they own
- offer an NFT if collection matches OB collection
- cancel an existing NFT offer
- instantly buy a specific NFT

# Witness protected actions

The contract which creates the orderbook can restrict specific actions to be
called only with a witness pattern and not via the entry point function.
This means others can build contracts on top of the orderbook with their own
custom logic based on their requirements or they can just use the entry point
functions which cover other use cases.

If a method is protected, clients will need to call a standard endpoint in the
witness-owning smart contract instead of the relevant endpoint in the orderbook.
Another way to think about this from a marketplace or wallet POV:
if I see that an action is protected, I can decide to either call the downstream
implementation in the collection smart contract, or simply disable that specific
action.

An example of this would be an NFT which has an expiry date like a name service
which requires an additional check before an ask can be placed on the orderbook.
Marketplaces can choose to support this additional logic or simply use the
standard orderbook and enable bids but asks would be disabled until they decide
to support the additional checks.

The setting is stored on the orderbook object:

```move
struct WitnessProtectedActions has store {
    buy_nft: bool,
    cancel_ask: bool,
    cancel_bid: bool,
    create_ask: bool,
    create_bid: bool,
}
```

This means that the additional complexity is _(i)_ opt-in by the collection and
_(ii)_ reserved only to the particular action which warrants that complexity.

To reiterate, a marketplace can list NFTs from collections which have all
actions unprotected, ie. no special logic. Or they can just disable that
particular action which is disabled in the UI.

Additionally, if we created a standard interface for custom implementations of
the disabled actions, then the added opt-in complexity could be abstracted away
from the clients by our SDK.

TBD: Can this be misused by removing the option to cancel an ask/bin?
