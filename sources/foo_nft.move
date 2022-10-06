module liquidity_layer::foo_nft {
    use sui::object::UID;
    use liquidity_layer::collection::{TradeReceipt, TradePayment};
    use liquidity_layer::safe::Safe;

    struct Witness {}

    /// The NFT itself.
    struct Foo has key, store {
        id: UID,
        // ...
    }

    public fun collect_fees<FT>(
        _receipt: TradeReceipt<Witness>,
        _payment: TradePayment<FT>,
        _safe: &mut Safe<Foo>,
    ) {
        abort(0)
    }
}
