module liquidity_layer::bidding {
    use liquidity_layer::collection::{Self, TradeReceipt, TradingWhitelist};
    use liquidity_layer::err;
    use liquidity_layer::safe::{Self, Safe, TransferCap};
    use std::option::{Self, Option};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID, UID};
    use sui::transfer::{transfer, share_object};
    use sui::tx_context::{Self, TxContext};

    struct Bidding has key {
        id: UID,
    }

    struct Bid<phantom FT> has key {
        id: UID,
        nft: ID,
        buyer: address,
        offer: Balance<FT>,
        commission: Option<BidCommission<FT>>,
    }

    /// Enables collection of wallet/marketplace collection for buying NFTs.
    /// 1. user bids via wallet to buy NFT for `p`, wallet wants fee `f`
    /// 2. when executed, `p` goes to seller and `f` goes to wallet.
    ///
    ///
    /// TODO: deduplicate with OB
    struct BidCommission<phantom FT> has store {
        /// This is given to the facilitator of the trade.
        cut: Balance<FT>,
        /// A new `Coin` object is created and sent to this address.
        beneficiary: address,
    }

    /// TODO: deduplicate with OB
    struct AskCommission has store, drop {
        /// How many tokens of the transferred amount should go to the party
        /// which holds the private key of `beneficiary` address.
        ///
        /// Always less than ask price.
        cut: u64,
        /// A new `Coin` object is created and sent to this address.
        beneficiary: address,
    }

    public entry fun create_bid<FT>(
        _nft: address,
        _amount: u64,
        _wallet: &mut Coin<FT>,
        _ctx: &mut TxContext,
    ) {
        abort(0)
    }

    // TODO: opt commission
    public entry fun sell_nft<W, C: key, FT>(
        contract: &Bidding,
        bid: &mut Bid<FT>,
        nft_cap: TransferCap,
        safe: &mut Safe<C>,
        whitelist: &TradingWhitelist<W, C>,
        ctx: &mut TxContext,
    ) {
        assert!(
            object::id(safe) == safe::transfer_cap_safe_id(&nft_cap),
            err::nft_collection_mismatch(),
        );
        assert!(
            bid.nft == safe::transfer_cap_nft_id(&nft_cap),
            err::nft_collection_mismatch(),
        );

        let trade = collection::begin_nft_trade(&contract.id, ctx);
        let ask_commission = option::none();
        pay_for_nft(
            &mut trade,
            &mut bid.offer,
            bid.buyer,
            &mut ask_commission,
            ctx,
        );
        option::destroy_none(ask_commission);

        let nft = safe::trade_nft<W, C>(nft_cap, trade, whitelist, safe);
        transfer(nft, bid.buyer);

        transfer_bid_commission(&mut bid.commission, ctx);
    }

    // TODO: dedup
    fun pay_for_nft<W, FT>(
        trade: &mut TradeReceipt<W>,
        paid: &mut Balance<FT>,
        buyer: address,
        maybe_commission: &mut Option<AskCommission>,
        ctx: &mut TxContext,
    ) {
        let amount = balance::value(paid);

        if (option::is_some(maybe_commission)) {
            // the `p`aid amount for the NFT and the commission `c`ut

            let AskCommission {
                cut, beneficiary,
            } = option::extract(maybe_commission);

            // `p` - `c` goes to seller
            collection::add_nft_payment(
                trade,
                balance::split(paid, amount - cut),
                buyer,
                ctx,
            );
            // `c` goes to the marketplace
            collection::add_nft_payment(
                trade,
                balance::split(paid, cut),
                beneficiary,
                ctx,
            );
        } else {
            // no commission, all `p` goes to seller

            collection::add_nft_payment(
                trade,
                balance::split(paid, amount),
                buyer,
                ctx,
            );
        };
    }

    // TODO: dedup
    fun transfer_bid_commission<FT>(
        commission: &mut Option<BidCommission<FT>>,
        ctx: &mut TxContext,
    ) {
        if (option::is_some(commission)) {
            let BidCommission { beneficiary, cut } =
                option::extract(commission);

            transfer(coin::from_balance(cut, ctx), beneficiary);
        };
    }
}
