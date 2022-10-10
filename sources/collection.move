//! Taken from https://github.com/MystenLabs/sui/pull/4887/files#diff-4097e0ffb7703cda3da51b586eba7657dfc6bfe919ca2b1be060aca6d71e8cd2
//! and modified.

module liquidity_layer::collection {
    use sui::balance::Balance;
    use sui::object::{Self, ID, UID};
    use sui::transfer::transfer_to_object;
    use sui::tx_context::TxContext;

    struct Collection<phantom T> has key, store {
        id: UID,
    }

    struct TradeReceipt<phantom Wness> has key, store {
        id: UID,
    }

    struct TradePayment<phantom FT> has key {
        id: UID,
        /// Could be same as `TradePayment::id` if the NFT was sold for just one
        /// FT kind.
        /// However, can bind multiple `TradePayment` objects with a different
        /// generic into one logical unit if the royalty logic requires e.g.
        /// payment in both `SUI` and `USDC`.
        trade: ID,
        amount: Balance<FT>,
    }

    /// Resolve the trade with [`safe::trade_nft`]
    public fun begin_nft_trade_with<Wness, FT>(
        amount: Balance<FT>,
        ctx: &mut TxContext,
    ): TradeReceipt<Wness> {
        let trade = begin_nft_trade(ctx);
        pay_for_nft(&mut trade, amount, ctx);

        trade
    }

    /// Resolve the trade with [`safe::trade_nft`]
    public fun begin_nft_trade<Wness>(ctx: &mut TxContext): TradeReceipt<Wness> {
        TradeReceipt {
            id: object::new(ctx),
        }
    }

    public fun pay_for_nft<Wness, FT>(
        trade: &mut TradeReceipt<Wness>,
        amount: Balance<FT>,
        ctx: &mut TxContext,
    ) {
        let payment = TradePayment {
            id: object::new(ctx),
            trade: object::id(trade),
            amount,
        };
        transfer_to_object(payment, trade);
    }
}
