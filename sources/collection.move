//! Taken from https://github.com/MystenLabs/sui/pull/4887/files#diff-4097e0ffb7703cda3da51b586eba7657dfc6bfe919ca2b1be060aca6d71e8cd2
//! and modified.
//!
//! This will eventually be part of a different package.

module liquidity_layer::collection {
    use sui::balance::Balance;
    use sui::vec_set::{Self, VecSet};
    use std::vector;
    use sui::object::{Self, ID, UID};
    use sui::transfer::transfer_to_object;
    use sui::tx_context::TxContext;
    use std::option::{Self, Option};

    struct Collection<phantom W, phantom T> has key, store {
        id: UID,
    }

    struct TradingWhitelist<phantom W, phantom C> has key {
        id: UID,
        authority: address,
        /// If None, then there's no whitelist and everyone is allowed.
        /// Otherwise the ID must be in the vec set.
        ///
        /// Then we assert that the source from `TradeReceipt` is included in
        /// this set.
        entities: Option<VecSet<ID>>,
    }

    struct TradeReceipt<phantom W> has key, store {
        id: UID,
        /// ID of the source entity which began the trade.
        source: ID,
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
    ///
    /// Settlement
    ///
    /// The assumption here is that getting a reference to a UID can be only
    /// done from within the contract that created an entity. Therefore, this
    /// is kind of similar to a witness pattern but works with UID instead.
    public fun begin_nft_trade<W>(
        source: &UID,
        ctx: &mut TxContext,
    ): TradeReceipt<W> {
        TradeReceipt {
            id: object::new(ctx),
            source: object::uid_to_inner(source),
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
        // TODO: wait for feature which enables us to reach child objects
        // dynamically https://github.com/MystenLabs/sui/issues/4203
        abort(0)
    }

    public fun has_some_nft_payment<W>(trade: &TradeReceipt<W>): bool {
        !vector::is_empty(&trade.payments)
    }

    public fun is_trade_source_whitelisted<W, C>(
        trade: &TradeReceipt<W>,
        whitelist: &TradingWhitelist<W, C>,
    ): bool {
        if (option::is_none(&whitelist.entities)) {
            return true
        };

        let entities = option::borrow(&whitelist.entities);

        vec_set::contains(entities, &trade.source)
    }
}
