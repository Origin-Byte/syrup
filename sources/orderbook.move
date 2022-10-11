module liquidity_layer::orderbook {
    //! Orderbook where bids are fungible tokens and asks are NFTs.
    //! A bid is a request to buy one NFT from a specific collection.
    //! An ask is one NFT with a min price condition.
    //!
    //! One can
    //! - create a new orderbook between a given collection and a bid token;
    //! - set publicly accessible actions to be witness protected;
    //! - open a new bid;
    //! - cancel an existing bid they own;
    //! - offer an NFT if collection matches OB collection;
    //! - cancel an existing NFT offer;
    //! - instantly buy a specific NFT;
    //! - open bids and asks with a commission on behalf of a user.

    // TODO: protocol toll

    use liquidity_layer::collection::{Self, TradeReceipt, TradeCap};
    use liquidity_layer::crit_bit::{Self, CB as CBTree};
    use liquidity_layer::err;
    use liquidity_layer::safe::{Self, Safe, ExclusiveTransferCap};
    use std::option::{Self, Option};
    use std::vector;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID, UID};
    use sui::transfer::{transfer, share_object};
    use sui::tx_context::{Self, TxContext};

    /// A critbit order book implementation. Contains two ordered trees:
    /// 1. bids ASC
    /// 2. asks DESC
    struct Orderbook<phantom W, phantom C, phantom FT> has key {
        id: UID,
        /// Given off by the collection creator to allow trading of the
        /// collection in orderbook.
        trade_cap: TradeCap<W, C>,
        /// Actions which have a flag set to true can only be called via a
        /// witness protected implementation.
        protected_actions: WitnessProtectedActions,
        /// An ask order stores an NFT to be traded. The price associated with
        /// such an order is saying:
        ///
        /// > for this NFT, I want to receive at least this amount of FT.
        asks: CBTree<vector<Ask>>,
        /// A bid order stores amount of tokens of type "B"(id) to trade. A bid
        /// order is saying:
        ///
        /// > for any NFT in this collection, I will spare this many tokens
        bids: CBTree<vector<Bid<FT>>>,
    }

    /// The contract which creates the orderbook can restrict specific actions
    /// to be only callable with a witness pattern and not via the entry point
    /// function.
    ///
    /// This means contracts can build on top of this orderbook their custom
    /// logic if they desire so, or they can just use the entry point functions
    /// which might be good enough for most use cases.
    ///
    /// # Important
    /// If a method is protected, then clients call instead of the relevant
    /// endpoint in the orderbook a standardized endpoint in the witness-owning
    /// smart contract.
    ///
    /// Another way to think about this from marketplace or wallet POV:
    /// If I see that an action is protected, I can decide to either call
    /// the downstream implementation in the collection smart contract, or just
    /// not enable to perform that specific action at all.
    struct WitnessProtectedActions has store {
        buy_nft: bool,
        cancel_ask: bool,
        cancel_bid: bool,
        create_ask: bool,
        create_bid: bool,
    }

    /// An offer for a single NFT in a collection.
    struct Bid<phantom FT> has store {
        /// How many "T"okens are being offered by the order issuer for one NFT.
        offer: Balance<FT>,
        /// The address of the user who created this bid and who will receive an
        /// NFT in exchange for their tokens.
        owner: address,
        /// If the NFT is offered via a marketplace or a wallet, the
        /// faciliatator can optionally set how many tokens they want to claim
        /// on top of the
        commission: Option<BidCommission<FT>>,
    }
    /// Enables collection of wallet/marketplace collection for buying NFTs.
    /// 1. user bids via wallet to buy NFT for `p`, wallet wants fee `f`
    /// 2. when executed, `p` goes to seller and `f` goes to wallet
    struct BidCommission<phantom FT> has store {
        /// This is given to the facilitator of the trade.
        cut: Balance<FT>,
        /// A new `Coin` object is created and sent to this address.
        beneficiary: address,
    }

    /// Object which is associated with a single NFT.
    ///
    /// When [`Ask`] is created, we transfer the ownership of the NFT to this
    /// new object.
    /// When an ask is matched with a bid, we transfer the ownership of the
    /// [`Ask`] object to the bid owner (buyer).
    /// The buyer can then claim the NFT via [`claim_nft`] endpoint.
    struct Ask has key, store {
        id: UID,
        /// How many tokens does the seller want for their NFT in exchange.
        price: u64,
        /// Capability to get an NFT from a safe.
        nft_cap: ExclusiveTransferCap,
        /// Who owns the NFT.
        owner: address,
        /// If the NFT is offered via a marketplace or a wallet, the
        /// faciliatator can optionally set how many tokens they want to claim
        /// from the price of the NFT for themselves as a commission.
        commission: Option<AskCommission>,
    }
    /// Enables collection of wallet/marketplace collection for listing an NFT.
    /// 1. user lists NFT via wallet for price `p`, wallet requests fee `f`
    /// 2. when executed, `p - f` goes to user and `f` goes to wallet
    struct AskCommission has store, drop {
        /// How many tokens of the transferred amount should go to the party
        /// which holds the private key of `beneficiary` address.
        ///
        /// Always less than ask price.
        cut: u64,
        /// A new `Coin` object is created and sent to this address.
        beneficiary: address,
    }

    /// We cannot just give the `ExclusiveTransferCap` to the buyer. They could
    /// decide to burn the NFT with their funds by never going to the
    /// `Safe` object and finishing the trade, but rather keeping the NFT's
    /// `ExlusiveTransferCap`.
    ///
    /// Therefore `TradeIntermediate` is made a share object and can be called
    /// permissionlessly.
    struct TradeIntermediate<phantom W, phantom FT> has key {
        id: UID,
        /// in option bcs we want to extract it but cannot destroy shared obj
        /// in Sui yet
        ///
        /// https://github.com/MystenLabs/sui/issues/2083
        nft_cap: Option<ExclusiveTransferCap>,
        /// in option bcs we want to extract it but cannot destroy shared obj
        /// in Sui yet
        ///
        /// https://github.com/MystenLabs/sui/issues/2083
        trade_receipt: Option<TradeReceipt<W>>,
        buyer: address,
        paid: Balance<FT>,
        commission: Option<AskCommission>,
    }

    /// How many (`price`) fungible tokens should be taken from sender's wallet
    /// and put into the orderbook with the intention of exchanging them for
    /// 1 NFT.
    ///
    /// If the `price` is higher than the lowest ask requested price, then we
    /// execute a trade straight away. Otherwise we add the bid to the
    /// orderbook's state.
    public entry fun create_bid<W, C: key + store, FT>(
        book: &mut Orderbook<W, C, FT>,
        price: u64,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.create_bid, err::action_not_public());
        create_bid_(book, price, option::none(), wallet, ctx)
    }
    public fun create_bid_protected<W: drop, C: key + store, FT>(
        _witness: W,
        book: &mut Orderbook<W, C, FT>,
        price: u64,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        create_bid_(book, price, option::none(), wallet, ctx)
    }
    public entry fun create_bid_with_commission<W, C: key + store, FT>(
        book: &mut Orderbook<W, C, FT>,
        price: u64,
        beneficiary: address,
        commission_ft: u64,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.create_bid, err::action_not_public());
        let commission = BidCommission {
            beneficiary,
            cut: balance::split(coin::balance_mut(wallet), commission_ft),
        };
        create_bid_(book, price, option::some(commission), wallet, ctx)
    }
    public fun create_bid_with_commission_protected<W: drop, C: key + store, FT>(
        _witness: W,
        book: &mut Orderbook<W, C, FT>,
        price: u64,
        beneficiary: address,
        commission_ft: u64,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        let commission = BidCommission {
            beneficiary,
            cut: balance::split(coin::balance_mut(wallet), commission_ft),
        };
        create_bid_(book, price, option::some(commission), wallet, ctx)
    }

    /// Cancel a bid owned by the sender at given price. If there are two bids
    /// with the same price, the one created later is cancelled.
    public entry fun cancel_bid<W, C, FT>(
        book: &mut Orderbook<W, C, FT>,
        requested_bid_offer_to_cancel: u64,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.cancel_bid, err::action_not_public());
        cancel_bid_(book, requested_bid_offer_to_cancel, wallet, ctx)
    }
    public fun cancel_bid_protected<W: drop, C, FT>(
        _witness: W,
        book: &mut Orderbook<W, C, FT>,
        requested_bid_offer_to_cancel: u64,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        cancel_bid_(book, requested_bid_offer_to_cancel, wallet, ctx)
    }

    /// Offer given NFT to be traded for given (`requsted_tokens`) tokens. If
    /// there exists a bid with higher offer than `requsted_tokens`, then trade
    /// is immeidately executed. Otherwise the NFT is transferred to a newly
    /// created ask object and the object is inserted to the orderbook.
    public entry fun create_ask<W, C: key + store, FT>(
        book: &mut Orderbook<W, C, FT>,
        requsted_tokens: u64,
        nft_cap: ExclusiveTransferCap,
        safe: &mut Safe<C>,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.create_ask, err::action_not_public());
        create_ask_(book, requsted_tokens, option::none(), nft_cap, safe, ctx)
    }
    public fun create_ask_protected<W: drop, C: key + store, FT>(
        _witness: W,
        book: &mut Orderbook<W, C, FT>,
        requsted_tokens: u64,
        nft_cap: ExclusiveTransferCap,
        safe: &mut Safe<C>,
        ctx: &mut TxContext,
    ) {
        create_ask_(book, requsted_tokens, option::none(), nft_cap, safe, ctx)
    }
    public entry fun create_ask_with_commission<W, C: key + store, FT>(
        book: &mut Orderbook<W, C, FT>,
        requsted_tokens: u64,
        nft_cap: ExclusiveTransferCap,
        safe: &mut Safe<C>,
        beneficiary: address,
        commission: u64,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.create_ask, err::action_not_public());
        let commission = AskCommission {
            cut: commission,
            beneficiary,
        };
        create_ask_(
            book, requsted_tokens, option::some(commission), nft_cap, safe, ctx
        )
    }
    public fun create_ask_with_commission_protected<W: drop, C: key + store, FT>(
        _witness: W,
        book: &mut Orderbook<W, C, FT>,
        requsted_tokens: u64,
        nft_cap: ExclusiveTransferCap,
        safe: &mut Safe<C>,
        beneficiary: address,
        commission: u64,
        ctx: &mut TxContext,
    ) {
        let commission = AskCommission {
            cut: commission,
            beneficiary,
        };
        create_ask_(
            book, requsted_tokens, option::some(commission), nft_cap, safe, ctx
        )
    }

    /// We could remove the NFT requested price from the argument, but then the
    /// search for the ask would be O(n) instead of O(log n).
    ///
    /// This API might be improved in future as we use a different data
    /// structure for the orderbook.
    public entry fun cancel_ask<W, C, FT>(
        book: &mut Orderbook<W, C, FT>,
        nft_price: u64,
        nft_id: ID,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.cancel_ask, err::action_not_public());
        cancel_ask_(book, nft_price, nft_id, ctx)
    }
    public entry fun cancel_ask_protected<W: drop, C, FT>(
        _witness: W,
        book: &mut Orderbook<W, C, FT>,
        nft_price: u64,
        nft_id: ID,
        ctx: &mut TxContext,
    ) {
        cancel_ask_(book, nft_price, nft_id, ctx)
    }

    /// Buys a specific NFT from the orderbook. This is an atypical OB API as
    /// with fungible tokens, you just want to get the cheapest ask.
    /// However, with NFTs, you might want to get a specific one.
    public entry fun buy_nft<W, C: key + store, FT>(
        book: &mut Orderbook<W, C, FT>,
        nft_id: ID,
        price: u64,
        wallet: &mut Coin<FT>,
        safe: &mut Safe<C>,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.buy_nft, err::action_not_public());
        buy_nft_(book, nft_id, price, wallet, safe, ctx)
    }
    public entry fun buy_nft_protected<W: drop, C: key + store, FT>(
        _witness: W,
        book: &mut Orderbook<W, C, FT>,
        nft_id: ID,
        price: u64,
        wallet: &mut Coin<FT>,
        safe: &mut Safe<C>,
        ctx: &mut TxContext,
    ) {
        buy_nft_(book, nft_id, price, wallet, safe, ctx)
    }

    /// When a bid is created and there's an ask with a lower price, then the
    /// trade cannot be resolved immiedately.
    /// That's because we don't know the `Safe` ID up front in OB.
    /// Therefore, the tx creates `TradeIntermediate` which then has to be
    /// permission-lessly resolved via this endpoint.
    public entry fun finish_trade<W, C: key + store, FT>(
        trade: &mut TradeIntermediate<W, FT>,
        safe: &mut Safe<C>,
        ctx: &mut TxContext,
    ) {
        finish_trade_(trade, safe, ctx)
    }

    /// `C`ollection kind of NFTs to be traded, and `F`ungible `T`oken to be
    /// quoted for an NFT in such a collection.
    ///
    /// By default, an orderbook has no restriction on actions, ie. all can be
    /// called with public entry functions.
    ///
    /// To implement specific logic in your smart contract, you can toggle the
    /// protection on specific actions. That will make them only accessible via
    /// witness protected methods.
    public entry fun create<W, C: key, FT>(
        trade_cap: TradeCap<W, C>,
        ctx: &mut TxContext,
    ) {
        let ob = create_<W, C, FT>(no_protection(), trade_cap, ctx);
        share_object(ob);
    }
    public fun create_protected<W: drop, C: key, FT>(
        _witness: W,
        trade_cap: TradeCap<W, C>,
        ctx: &mut TxContext,
    ): Orderbook<W, C, FT> {
        create_<W, C, FT>(no_protection(), trade_cap, ctx)
    }

    public fun toggle_protection_on_buy_nft<W: drop, C, FT>(
        _witness: W,
        book: &mut Orderbook<W, C, FT>,
    ) {
        book.protected_actions.buy_nft =
            !book.protected_actions.buy_nft;
    }
    public fun toggle_protection_on_cancel_ask<W: drop, C, FT>(
        _witness: W,
        book: &mut Orderbook<W, C, FT>,
    ) {
        book.protected_actions.cancel_ask =
            !book.protected_actions.cancel_ask;
    }
    public fun toggle_protection_on_cancel_bid<W: drop, C, FT>(
        _witness: W,
        book: &mut Orderbook<W, C, FT>,
    ) {
        book.protected_actions.cancel_bid =
            !book.protected_actions.cancel_bid;
    }
    public fun toggle_protection_on_create_ask<W: drop, C, FT>(
        _witness: W,
        book: &mut Orderbook<W, C, FT>,
    ) {
        book.protected_actions.create_ask =
            !book.protected_actions.create_ask;
    }
    public fun toggle_protection_on_create_bid<W: drop, C, FT>(
        _witness: W,
        book: &mut Orderbook<W, C, FT>,
    ) {
        book.protected_actions.create_bid =
            !book.protected_actions.create_bid;
    }

    public fun borrow_bids<W, C, FT>(
        book: &Orderbook<W, C, FT>,
    ): &CBTree<vector<Bid<FT>>> {
        &book.bids
    }

    public fun bid_offer<FT>(bid: &Bid<FT>): &Balance<FT> {
        &bid.offer
    }

    public fun bid_owner<FT>(bid: &Bid<FT>): address {
        bid.owner
    }

    public fun borrow_asks<W, C, FT>(
        book: &Orderbook<W, C, FT>,
    ): &CBTree<vector<Ask>> {
        &book.asks
    }

    public fun ask_price(ask: &Ask): u64 {
        ask.price
    }

    public fun ask_nft(ask: &Ask): &ExclusiveTransferCap {
        &ask.nft_cap
    }

    public fun ask_owner(ask: &Ask): address {
        ask.owner
    }

    fun create_<W, C: key, FT>(
        protected_actions: WitnessProtectedActions,
        trade_cap: TradeCap<W, C>,
        ctx: &mut TxContext,
    ): Orderbook<W, C, FT> {
        let id = object::new(ctx);

        Orderbook<W, C, FT> {
            id,
            trade_cap,
            protected_actions,
            asks: crit_bit::empty(),
            bids: crit_bit::empty(),
        }
    }

    fun create_bid_<W, C: key + store, FT>(
        book: &mut Orderbook<W, C, FT>,
        price: u64,
        bid_commission: Option<BidCommission<FT>>,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        let buyer = tx_context::sender(ctx);

        // take the amount that the sender wants to create a bid with from their
        // wallet
        let bid_offer = balance::split(coin::balance_mut(wallet), price);

        let asks = &mut book.asks;

        let can_be_filled = !crit_bit::is_empty(asks) &&
            crit_bit::min_key(asks) <= price;

        if (can_be_filled) {
            // OPTIMIZE: this is being recomputed
            let lowest_ask_price = crit_bit::min_key(asks);
            let price_level = crit_bit::borrow_mut(asks, lowest_ask_price);

            let ask = vector::remove(
                price_level,
                // remove zeroth for FIFO, must exist due to `can_be_filled`
                0,
            );
            if (vector::length(price_level) == 0) {
                // to simplify impl, always delete empty price level
                vector::destroy_empty(crit_bit::pop(asks, lowest_ask_price));
            };

            let Ask {
                id,
                price: _,
                owner: _,
                nft_cap,
                commission: ask_commission,
            } = ask;
            object::delete(id);

            // see also `finish_trade` entry point
            share_object(TradeIntermediate<W, FT> {
                id: object::new(ctx),
                nft_cap: option::some(nft_cap),
                commission: ask_commission,
                buyer,
                trade_receipt: option::some(collection::begin_nft_trade(
                    &mut book.trade_cap,
                    ctx,
                )),
                paid: bid_offer,
            });

            transfer_bid_commission(bid_commission, ctx);
        } else {
            let order = Bid {
                offer: bid_offer,
                owner: buyer,
                commission: bid_commission,
            };

            if (crit_bit::has_key(&book.bids, price)) {
                vector::push_back(
                    crit_bit::borrow_mut(&mut book.bids, price),
                    order
                );
            } else {
                crit_bit::insert(
                    &mut book.bids,
                    price,
                    vector::singleton(order),
                );
            }
        }
    }

    fun cancel_bid_<W, C, FT>(
        book: &mut Orderbook<W, C, FT>,
        requested_bid_offer_to_cancel: u64,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);

        let bids = &mut book.bids;

        assert!(
            crit_bit::has_key(bids, requested_bid_offer_to_cancel),
            err::order_does_not_exist()
        );

        let price_level = crit_bit::borrow_mut(bids, requested_bid_offer_to_cancel);

        let index = 0;
        let bids_count = vector::length(price_level);
        while (bids_count > index) {
            let bid = vector::borrow(price_level, index);
            if (bid.owner == sender) {
                break
            };

            index = index + 1;
        };


        assert!(index < bids_count, err::order_owner_must_be_sender());

        let Bid { offer, owner: _owner, commission } =
            vector::remove(price_level, index);

        balance::join(
            coin::balance_mut(wallet),
            offer,
        );

        if (option::is_some(&commission)) {
            let BidCommission { cut, beneficiary: _ } =
                option::extract(&mut commission);
            balance::join(
                coin::balance_mut(wallet),
                cut,
            );
        };
        option::destroy_none(commission);
    }

    fun create_ask_<W, C: key + store, FT>(
        book: &mut Orderbook<W, C, FT>,
        price: u64,
        ask_commission: Option<AskCommission>,
        nft_cap: ExclusiveTransferCap,
        safe: &mut Safe<C>,
        ctx: &mut TxContext,
    ) {
        assert!(
            object::id(safe) == safe::exclusive_transfer_cap_safe_id(&nft_cap),
            err::nft_collection_mismatch(),
        );

        let seller = tx_context::sender(ctx);

        let bids = &mut book.bids;

        let can_be_filled = !crit_bit::is_empty(bids) &&
            crit_bit::max_key(bids) >= price;

        if (can_be_filled) {
            let highest_bid_price = crit_bit::max_key(bids);
            let price_level = crit_bit::borrow_mut(bids, highest_bid_price);

            let bid = vector::remove(
                price_level,
                // remove zeroth for FIFO, must exist due to `can_be_filled`
                0,
            );
            if (vector::length(price_level) == 0) {
                // to simplify impl, always delete empty price level
                vector::destroy_empty(crit_bit::pop(bids, highest_bid_price));
            };

            let Bid {
                owner: buyer,
                offer: bid_offer,
                commission: bid_commission,
            } = bid;

            let trade = collection::begin_nft_trade(&mut book.trade_cap, ctx);
            pay_for_nft(
                &mut trade,
                &mut bid_offer,
                buyer,
                &mut ask_commission,
                ctx,
            );
            option::destroy_none(ask_commission);
            balance::destroy_zero(bid_offer);

            let nft = safe::trade_nft<W, C, FT>(nft_cap, trade, safe);
            transfer(nft, buyer);

            transfer_bid_commission(bid_commission, ctx);
        } else {
            let id = object::new(ctx);
            let ask = Ask {
                id,
                price,
                owner: seller,
                nft_cap,
                commission: ask_commission,
            };
            // store the Ask object
            if (crit_bit::has_key(&book.asks, price)) {
                vector::push_back(
                    crit_bit::borrow_mut(&mut book.asks, price),
                    ask
                );
            } else {
                crit_bit::insert(
                    &mut book.asks,
                    price,
                    vector::singleton(ask),
                );
            }
        }
    }

    fun cancel_ask_<W, C, FT>(
        book: &mut Orderbook<W, C, FT>,
        nft_price: u64,
        nft_id: ID,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);

        let Ask {
            owner,
            id,
            price: _,
            nft_cap,
            commission: _,
        } = remove_ask(
            &mut book.asks,
            nft_price,
            nft_id,
        );

        assert!(owner != sender, err::order_owner_must_be_sender());

        object::delete(id);
        transfer(nft_cap, sender);
    }

    fun buy_nft_<W, C: key + store, FT>(
        book: &mut Orderbook<W, C, FT>,
        nft_id: ID,
        price: u64,
        wallet: &mut Coin<FT>,
        safe: &mut Safe<C>,
        ctx: &mut TxContext,
    ) {
        let buyer = tx_context::sender(ctx);

        let Ask {
            id,
            nft_cap,
            owner: _,
            price: _,
            commission: maybe_commission,
        } = remove_ask(
            &mut book.asks,
            price,
            nft_id,
        );
        object::delete(id);

        let bid_offer = balance::split(coin::balance_mut(wallet), price);

        let trade = collection::begin_nft_trade(&mut book.trade_cap, ctx);
        pay_for_nft(
            &mut trade,
            &mut bid_offer,
            buyer,
            &mut maybe_commission,
            ctx,
        );
        option::destroy_none(maybe_commission);
        balance::destroy_zero(bid_offer);

        let nft = safe::trade_nft<W, C, FT>(nft_cap, trade, safe);
        transfer(nft, buyer);
    }

    fun finish_trade_<W, C: key + store, FT>(
        trade: &mut TradeIntermediate<W, FT>,
        safe: &mut Safe<C>,
        ctx: &mut TxContext,
    ) {
        let TradeIntermediate {
            id: _,
            nft_cap,
            trade_receipt,
            paid,
            buyer,
            commission: maybe_commission,
        } = trade;

        let trade = option::extract(trade_receipt);
        let nft_cap = option::extract(nft_cap);

        assert!(
            object::id(safe) == safe::exclusive_transfer_cap_safe_id(&nft_cap),
            err::nft_collection_mismatch(),
        );

        pay_for_nft(
            &mut trade,
            paid,
            *buyer,
            maybe_commission,
            ctx,
        );

        let nft = safe::trade_nft<W, C, FT>(nft_cap, trade, safe);
        transfer(nft, *buyer);
    }

    /// Finds an ask of a given NFT advertized for the given price. Removes it
    /// from the asks vector preserving order and returns it.
    fun remove_ask(asks: &mut CBTree<vector<Ask>>, price: u64, nft_id: ID): Ask {
        assert!(
            crit_bit::has_key(asks, price),
            err::order_does_not_exist()
        );

        let price_level = crit_bit::borrow_mut(asks, price);

        let index = 0;
        let asks_count = vector::length(price_level);
        while (asks_count > index) {
            let ask = vector::borrow(price_level, index);
            // on the same price level, we search for the specified NFT
            if (nft_id == safe::exclusive_transfer_cap_nft_id(&ask.nft_cap)) {
                break
            };

            index = index + 1;
        };

        assert!(index < asks_count, err::order_does_not_exist());

        vector::remove(price_level, index)
    }

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

    fun transfer_bid_commission<FT>(
        commission: Option<BidCommission<FT>>,
        ctx: &mut TxContext,
    ) {
        if (option::is_some(&commission)) {
            let BidCommission { beneficiary, cut } =
                option::extract(&mut commission);

            transfer(coin::from_balance(cut, ctx), beneficiary);
        };
        option::destroy_none(commission);
    }

    fun no_protection(): WitnessProtectedActions {
        WitnessProtectedActions {
            buy_nft: false,
            cancel_ask: false,
            cancel_bid: false,
            create_ask: false,
            create_bid: false,
        }
    }
}
