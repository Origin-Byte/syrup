module syrup::custom_collection {
    //! A simple showcase how to participate in the liquidity layer as a custom
    //! collection implementor.
    //!
    //! The common use case to trade art NFTs would be implemented by the
    //! `StdCollection` of the OriginByte nft protocol (will be a standalone
    //! contract so no circular dependencies.)
    //!
    //! In a nutshell, the `StdCollection` implements a default desired behavior
    //! for creators to list their collections in the liquidity layer.
    //!
    //! It would implements royalty distribution based on a business logic which
    //! makes most sense for art NFTs.

    use syrup::orderbook::{Self, Orderbook};
    use std::fixed_point32;
    use sui::object::{Self, UID};
    use sui::balance;
    use sui::coin;
    use sui::transfer::{Self, transfer};
    use sui::sui::SUI;
    use sui::tx_context::{Self, TxContext};

    // TODO: remove `store` once new version of nft-protocol lands
    struct Witness has drop, store {}

    struct MyCollection has key, store {
        id: UID,
        admin: address,
    }

    public entry fun create_orderbook<FT>(
        my_collection: &MyCollection,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == my_collection.admin, 0);

        let royalty = fixed_point32::create_from_rational(1, 100); // 1%

        transfer::share_object(orderbook::create<Witness, SUI>(
            Witness {},
            object::id(my_collection),
            royalty,
            ctx,
        ));
    }

    public entry fun collect_royalties(
        my_collection: &MyCollection,
        ob: &mut Orderbook<Witness, SUI>,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == my_collection.admin, 0);

        let balance = orderbook::fees_balance(Witness {}, ob);
        let total = balance::value(balance);
        transfer(coin::take(balance, total, ctx), my_collection.admin);
    }
}
