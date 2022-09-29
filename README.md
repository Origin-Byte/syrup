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

One can

- create a new orderbook between a given collection and a bid token
  (witness pattern protected);
- collect fees (witness pattern protected);
- set publicly accessible actions to be witness protected;
- open a new bid;
- cancel an existing bid they own;
- offer an NFT if collection matches OB collection;
- cancel an existing NFT offer;
- instantly buy an specific NFT.

The contract which creates the orderbook can restrict specific actions
to be only callable with a witness pattern and not via the entry point
function.
This means contracts can build on top of this orderbook their custom
logic if they desire so, or they can just use the entry point functions
which might be good enough for most use cases.

If a method is protected, then clients call instead of the relevant
endpoint in the orderbook a standardized endpoint in the witness-owning
smart contract.
Another way to think about this from marketplace or wallet POV:
if I see that an action is protected, I can decide to either call
the downstream implementation in the collection smart contract, or just
not enable to perform that specific action at all.

**Ask** is an object which is associated with a single NFT.
When _ask_ is created, we transfer the ownership of the NFT to this
new object.
When an ask is matched with a bid, we transfer the ownership of the
_ask_ object to the bid owner (buyer).
The buyer can then claim the NFT via `claim_nft` endpoint.

TBD: Can this be misused by removing the option to cancel an ask/bin?
