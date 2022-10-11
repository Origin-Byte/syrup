//! Taken from https://github.com/MystenLabs/sui/pull/4887/files#diff-4097e0ffb7703cda3da51b586eba7657dfc6bfe919ca2b1be060aca6d71e8cd2
//! and modified.
//!
//! This will eventually be part of a different package.

module liquidity_layer::collection {
    use sui::balance::Balance;
    use std::vector;
    use sui::object::{Self, ID, UID};
    use sui::transfer::transfer_to_object;
    use sui::tx_context::TxContext;

    struct Collection<phantom W, phantom T> has key, store {
        id: UID,
    }

    /// Only owners of a trade cap are eligible to create `TradeReceipt`s.
    ///
    /// This enables optional whitelisting of trading contracts by creators.
    /// Optional because creators can decide to mint this capability to anyone
    /// who "asks" via a permission-less endpoint.
    ///
    /// `TradeCap` also serves as a bridge between the `Collection` and the
    /// witness (outside of the `Collection` type.)
    struct TradeCap<phantom W, phantom C> has key, store {
        id: UID,
    }

    struct TradeReceipt<phantom W> has key, store {
        id: UID,
        /// Each trade is done with one of more payments.
        ///
        /// IDs of `TradePayment` child objects of this receipt.
        payments: vector<ID>,
    }

    struct TradePayment<phantom FT> has key {
        id: UID,
        amount: Balance<FT>,
        /// The address where the amount should be transferred to.
        /// This could be either the payment for the seller or a marketplace's
        /// commision.
        beneficiary: address,
    }

    /// Resolve the trade with [`safe::trade_nft`]
    public fun begin_nft_trade<W, C>(
        _cap: &mut TradeCap<W, C>,
        ctx: &mut TxContext,
    ): TradeReceipt<W> {
        TradeReceipt {
            id: object::new(ctx),
            payments: vector::empty(),
        }
    }

    public fun add_nft_payment<W, FT>(
        trade: &mut TradeReceipt<W>,
        amount: Balance<FT>,
        beneficiary: address,
        ctx: &mut TxContext,
    ) {
        let payment = TradePayment {
            id: object::new(ctx),
            amount,
            beneficiary,
        };
        vector::push_back(&mut trade.payments, object::id(&payment));
        transfer_to_object(payment, trade);
    }

    public fun extract_next_nft_payment<W, FT>(
        _witness: W,
        _trade: TradeReceipt<W>,
    ): TradePayment<FT> {
        // TODO: wait for feature which enables us to reach child objects via
        // id
        abort(0)
    }
}
