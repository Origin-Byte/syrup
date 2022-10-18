module liquidity_layer::foo_nft {
    use sui::object::UID;
    use liquidity_layer::collection::{TradeReceipt};
    use liquidity_layer::safe::Safe;

    struct Witness {}

    /// The NFT itself.
    struct Foo has key, store {
        id: UID,
        // ...
    }

    public fun collect_royalty<FT>(
        _receipt: TradeReceipt<Witness>,
        _safe: &mut Safe<Foo>,
    ) {
        abort(0)
    }
}
