//! Taken from https://github.com/MystenLabs/sui/pull/4887/files#diff-4097e0ffb7703cda3da51b586eba7657dfc6bfe919ca2b1be060aca6d71e8cd2
//! and modified.
//!
//! This will eventually be part of a different package.

module liquidity_layer::collection {
    use sui::balance::Balance;
    use sui::object::{Self, ID, UID};
    use sui::transfer::transfer_to_object;
    use sui::tx_context::TxContext;
    use sui::vec_set::{Self, VecSet};

    struct Collection<phantom T> has key, store {
        id: UID,
    }

    struct TradeReceipt<phantom W> has key, store {
        id: UID,
        /// Each trade is done with one of more payments.
        ///
        /// IDs of `TradePayment` child objects of this receipt.
        payments: VecSet<ID>,
    }

    struct TradePayment<phantom FT> has key {
        id: UID,
        trade_receipt: ID,
        amount: Balance<FT>,
        /// The address where the amount should be transferred to.
        /// This could be either the payment for the seller or a marketplace's
        /// commision.
        beneficiary: address,
    }

    /// Resolve the trade with [`safe::trade_nft`]
    public fun begin_nft_trade_with<W, FT>(
        amount: Balance<FT>,
        beneficiary: address,
        ctx: &mut TxContext,
    ): TradeReceipt<W> {
        let trade = begin_nft_trade(ctx);
        pay_for_nft(&mut trade, amount, beneficiary, ctx);

        trade
    }

    /// Resolve the trade with [`safe::trade_nft`]
    public fun begin_nft_trade<W>(ctx: &mut TxContext): TradeReceipt<W> {
        TradeReceipt {
            id: object::new(ctx),
            payments: vec_set::empty(),
        }
    }

    public fun pay_for_nft<W, FT>(
        trade: &mut TradeReceipt<W>,
        amount: Balance<FT>,
        beneficiary: address,
        ctx: &mut TxContext,
    ) {
        let payment = TradePayment {
            id: object::new(ctx),
            trade_receipt: object::id(trade),
            amount,
            beneficiary,
        };
        vec_set::insert(&mut trade.payments, object::id(&payment));
        transfer_to_object(payment, trade);
    }
}
