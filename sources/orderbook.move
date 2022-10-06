module liquidity_layer::orderbook {
    //! Orderbook where bids are fungible tokens and asks are NFTs.
    //! A bid is a request to buy one NFT from a specific collection.
    //! An ask is one NFT with a min price condition.
    //!
    //! One can
    //! - create a new orderbook between a given collection and a bid token
    //!     (witness pattern protected);
    //! - set publicly accessible actions to be witness protected;
    //! - open a new bid;
    //! - cancel an existing bid they own;
    //! - offer an NFT if collection matches OB collection;
    //! - cancel an existing NFT offer;
    //! - instantly buy an specific NFT.

    // TODO: collect commision on trade
    // TODO: protocol toll

    use std::vector;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID, UID};
    use sui::transfer::transfer;
    use sui::tx_context::{Self, TxContext};
    use liquidity_layer::collection;
    use liquidity_layer::crit_bit::{Self, CB as CBTree};
    use liquidity_layer::err;
    use liquidity_layer::safe::{Self, Safe, TransferCap};

    /// A critbit order book implementation. Contains two ordered trees:
    /// 1. bids ASC
    /// 2. asks DESC
    struct Orderbook<phantom Wness, phantom Col, phantom FT> has key {
        id: UID,
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
    struct Bid<phantom T> has store {
        /// How many "T"okens are being offered by the order issuer for one NFT.
        offer: Balance<T>,
        /// The address of the user who created this bid and who will receive an
        /// NFT in exchange for their tokens.
        owner: address,
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
        nft_cap: TransferCap,
        /// Who owns the NFT.
        owner: address,
    }

    /// How many (`price`) fungible tokens should be taken from sender's wallet
    /// and put into the orderbook with the intention of exchanging them for
    /// 1 NFT.
    ///
    /// If the `price` is higher than the lowest ask requested price, then we
    /// execute a trade straight away. Otherwise we add the bid to the
    /// orderbook's state.
    public entry fun create_bid<Wness, Col: key + store, FT>(
        book: &mut Orderbook<Wness, Col, FT>,
        price: u64,
        wallet: &mut Coin<FT>,
        safe: &mut Safe<Col>, // !!!
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.create_bid, err::action_not_public());
        create_bid_(book, price, wallet, safe, ctx)
    }
    public fun create_bid_protected<Wness: drop, Col: key + store, FT>(
        _witness: Wness,
        book: &mut Orderbook<Wness, Col, FT>,
        price: u64,
        wallet: &mut Coin<FT>,
        safe: &mut Safe<Col>, // !!!
        ctx: &mut TxContext,
    ) {
        create_bid_(book, price, wallet, safe, ctx)
    }

    /// Cancel a bid owned by the sender at given price. If there are two bids
    /// with the same price, the one created later is cancelled.
    public entry fun cancel_bid<Wness, Col, FT>(
        book: &mut Orderbook<Wness, Col, FT>,
        requested_bid_offer_to_cancel: u64,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.cancel_bid, err::action_not_public());
        cancel_bid_(book, requested_bid_offer_to_cancel, wallet, ctx)
    }
    public fun cancel_bid_protected<Wness: drop, Col, FT>(
        _witness: Wness,
        book: &mut Orderbook<Wness, Col, FT>,
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
    public entry fun create_ask<Wness, Col: key + store, FT>(
        book: &mut Orderbook<Wness, Col, FT>,
        requsted_tokens: u64,
        nft_cap: TransferCap,
        safe: &mut Safe<Col>,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.create_ask, err::action_not_public());
        create_ask_(book, requsted_tokens, nft_cap, safe, ctx)
    }
    public fun create_ask_protected<Wness: drop, Col: key + store, FT>(
        _witness: Wness,
        book: &mut Orderbook<Wness, Col, FT>,
        requsted_tokens: u64,
        nft_cap: TransferCap,
        safe: &mut Safe<Col>,
        ctx: &mut TxContext,
    ) {
        create_ask_(book, requsted_tokens, nft_cap, safe, ctx)
    }

    /// We could remove the NFT requested price from the argument, but then the
    /// search for the ask would be O(n) instead of O(log n).
    ///
    /// This API might be improved in future as we use a different data
    /// structure for the orderbook.
    public entry fun cancel_ask<Wness, Col, FT>(
        book: &mut Orderbook<Wness, Col, FT>,
        nft_price: u64,
        nft_id: ID,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.cancel_ask, err::action_not_public());
        cancel_ask_(book, nft_price, nft_id, ctx)
    }
    public entry fun cancel_ask_protected<Wness: drop, Col, FT>(
        _witness: Wness,
        book: &mut Orderbook<Wness, Col, FT>,
        nft_price: u64,
        nft_id: ID,
        ctx: &mut TxContext,
    ) {
        cancel_ask_(book, nft_price, nft_id, ctx)
    }

    /// Buys a specific NFT from the orderbook. This is an atypical OB API as
    /// with fungible tokens, you just want to get the cheapest ask.
    /// However, with NFTs, you might want to get a specific one.
    public entry fun buy_nft<Wness, Col: key + store, FT>(
        book: &mut Orderbook<Wness, Col, FT>,
        nft_id: ID,
        price: u64,
        wallet: &mut Coin<FT>,
        safe: &mut Safe<Col>,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.buy_nft, err::action_not_public());
        buy_nft_(book, nft_id, price, wallet, safe, ctx)
    }
    public entry fun buy_nft_protected<Wness: drop, Col: key + store, FT>(
        _witness: Wness,
        book: &mut Orderbook<Wness, Col, FT>,
        nft_id: ID,
        price: u64,
        wallet: &mut Coin<FT>,
        safe: &mut Safe<Col>,
        ctx: &mut TxContext,
    ) {
        buy_nft_(book, nft_id, price, wallet, safe, ctx)
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
    public fun create<Wness: drop, Col: key, FT>(
        _witness: Wness,
        ctx: &mut TxContext,
    ): Orderbook<Wness, Col, FT> {
        create_<Wness, Col, FT>(no_protection(), ctx)
    }

    public fun toggle_protection_on_buy_nft<Wness: drop, Col, FT>(
        _witness: Wness,
        book: &mut Orderbook<Wness, Col, FT>,
    ) {
        book.protected_actions.buy_nft =
            !book.protected_actions.buy_nft;
    }
    public fun toggle_protection_on_cancel_ask<Wness: drop, Col, FT>(
        _witness: Wness,
        book: &mut Orderbook<Wness, Col, FT>,
    ) {
        book.protected_actions.cancel_ask =
            !book.protected_actions.cancel_ask;
    }
    public fun toggle_protection_on_cancel_bid<Wness: drop, Col, FT>(
        _witness: Wness,
        book: &mut Orderbook<Wness, Col, FT>,
    ) {
        book.protected_actions.cancel_bid =
            !book.protected_actions.cancel_bid;
    }
    public fun toggle_protection_on_create_ask<Wness: drop, Col, FT>(
        _witness: Wness,
        book: &mut Orderbook<Wness, Col, FT>,
    ) {
        book.protected_actions.create_ask =
            !book.protected_actions.create_ask;
    }
    public fun toggle_protection_on_create_bid<Wness: drop, Col, FT>(
        _witness: Wness,
        book: &mut Orderbook<Wness, Col, FT>,
    ) {
        book.protected_actions.create_bid =
            !book.protected_actions.create_bid;
    }

    public fun borrow_bids<Wness, Col, FT>(
        book: &Orderbook<Wness, Col, FT>,
    ): &CBTree<vector<Bid<FT>>> {
        &book.bids
    }

    public fun bid_offer<FT>(bid: &Bid<FT>): &Balance<FT> {
        &bid.offer
    }

    public fun bid_owner<FT>(bid: &Bid<FT>): address {
        bid.owner
    }

    public fun borrow_asks<Wness, Col, FT>(
        book: &Orderbook<Wness, Col, FT>,
    ): &CBTree<vector<Ask>> {
        &book.asks
    }

    public fun ask_price(ask: &Ask): u64 {
        ask.price
    }

    public fun ask_nft(ask: &Ask): &TransferCap {
        &ask.nft_cap
    }

    public fun ask_owner(ask: &Ask): address {
        ask.owner
    }

    fun create_<Wness, Col: key, FT>(
        protected_actions: WitnessProtectedActions,
        ctx: &mut TxContext,
    ): Orderbook<Wness, Col, FT> {
        let id = object::new(ctx);

        Orderbook<Wness, Col, FT> {
            id,
            protected_actions,
            asks: crit_bit::empty(),
            bids: crit_bit::empty(),
        }
    }

    fun create_bid_<Wness, Col: key + store, FT>(
        book: &mut Orderbook<Wness, Col, FT>,
        price: u64,
        wallet: &mut Coin<FT>,
        safe: &mut Safe<Col>, // !!!
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
            let lowest_ask_price = crit_bit::min_key(asks); // TODO: recomputed
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
                owner: seller,
                nft_cap,
            } = ask;
            assert!(safe::safe_owner(safe) == seller, 0);
            let trade = collection::begin_nft_trade_with(bid_offer, ctx);
            let nft = safe::trade_nft<Wness, Col, FT>(nft_cap, trade, safe);
            transfer(nft, buyer);
            object::delete(id);
        } else {
            let order = Bid { offer: bid_offer, owner: buyer };

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

    fun cancel_bid_<Wness, Col, FT>(
        book: &mut Orderbook<Wness, Col, FT>,
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

        let Bid { offer, owner: _owner } = vector::remove(price_level, index);

        balance::join(
            coin::balance_mut(wallet),
            offer,
        );
    }

    fun create_ask_<Wness, Col: key + store, FT>(
        book: &mut Orderbook<Wness, Col, FT>,
        price: u64,
        nft_cap: TransferCap,
        safe: &mut Safe<Col>,
        ctx: &mut TxContext,
    ) {
        assert!(
            object::id(safe) == safe::transfer_cap_safe_id(&nft_cap),
            err::nft_collection_mismatch(),
        );
        assert!(
            safe::transfer_cap_is_exclusive(&nft_cap),
            err::nft_not_exclusive(),
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
            } = bid;
            let trade = collection::begin_nft_trade_with(bid_offer, ctx);
            let nft = safe::trade_nft<Wness, Col, FT>(nft_cap, trade, safe);
            transfer(nft, buyer);
        } else {
            let id = object::new(ctx);
            let ask = Ask {
                id,
                price,
                owner: seller,
                nft_cap,
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

    fun cancel_ask_<Wness, Col, FT>(
        book: &mut Orderbook<Wness, Col, FT>,
        nft_price: u64,
        nft_id: ID,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);

        let Ask {
            owner,
            id,
            price: _,
            nft_cap
        } = remove_ask(
            &mut book.asks,
            nft_price,
            nft_id,
        );

        assert!(owner != sender, err::order_owner_must_be_sender());

        object::delete(id);
        transfer(nft_cap, sender);
    }

    fun buy_nft_<Wness, Col: key + store, FT>(
        book: &mut Orderbook<Wness, Col, FT>,
        nft_id: ID,
        price: u64,
        wallet: &mut Coin<FT>,
        safe: &mut Safe<Col>,
        ctx: &mut TxContext,
    ) {
        let buyer = tx_context::sender(ctx);

        let Ask {
            id,
            nft_cap,
            owner: _,
            price: _,
        } = remove_ask(
            &mut book.asks,
            price,
            nft_id,
        );
        object::delete(id);

        let offer = balance::split(coin::balance_mut(wallet), price);

        let trade = collection::begin_nft_trade_with(offer, ctx);
        let nft = safe::trade_nft<Wness, Col, FT>(nft_cap, trade, safe);
        transfer(nft, buyer);
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
            if (nft_id == safe::transfer_cap_nft_id(&ask.nft_cap)) {
                break
            };

            index = index + 1;
        };

        assert!(index < asks_count, err::order_does_not_exist());

        vector::remove(price_level, index)
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
