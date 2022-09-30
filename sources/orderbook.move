module syrup::orderbook {
    //! Orderbook where bids are fungible tokens and asks are NFTs.
    //! A bid is a request to buy one NFT from a specific collection.
    //! An ask is one NFT with a min price condition.
    //!
    //! One can
    //! - create a new orderbook between a given collection and a bid token
    //!     (witness pattern protected);
    //! - collect fees (witness pattern protected);
    //! - set publicly accessible actions to be witness protected;
    //! - open a new bid;
    //! - cancel an existing bid they own;
    //! - offer an NFT if collection matches OB collection;
    //! - cancel an existing NFT offer;
    //! - instantly buy an specific NFT.

    // TODO: collect fees on trade

    use nft_protocol::nft::{Self, NftOwned};
    use syrup::err;
    use std::fixed_point32::FixedPoint32;
    use std::vector;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID, UID};
    use sui::transfer::{transfer, transfer_to_object};
    use sui::tx_context::{Self, TxContext};
    use syrup::crit_bit::{Self, CB as CBTree};

    /// A critbit order book implementation. Contains two ordered trees:
    /// 1. bids ASC
    /// 2. asks DESC
    struct Orderbook<phantom C, phantom FT> has key {
        id: UID,
        /// Only NFTs belonging to this collection can be traded.
        collection: ID,
        /// Actions which have a flag set to true can only be called via a
        /// witness protected implementation.
        protected_actions: WitnessProtectedActions,
        /// Collects fees in fungible tokens.
        fees: Fees<FT>,
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

    struct Fees<phantom FT> has store {
        /// All fees during trading are collected here and the witness protected
        /// method [`collect_fees`] is implemented by downstream packages.
        ///
        /// For example, in case of standard art collections, these fees
        /// represent royalties.
        uncollected: Balance<FT>,
        /// in iterval `[0; 1)`
        fee: FixedPoint32,
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
        /// The pointer to the offered NFT.
        nft: ID,
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
    public entry fun create_bid<C, FT>(
        book: &mut Orderbook<C, FT>,
        price: u64,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.create_bid, err::action_not_public());
        create_bid_(book, price, wallet, ctx)
    }
    public fun create_bid_protected<C: drop, FT>(
        _witness: C,
        book: &mut Orderbook<C, FT>,
        price: u64,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        create_bid_(book, price, wallet, ctx)
    }

    /// Cancel a bid owned by the sender at given price. If there are two bids
    /// with the same price, the one created later is cancelled.
    public entry fun cancel_bid<C, FT>(
        book: &mut Orderbook<C, FT>,
        requested_bid_offer_to_cancel: u64,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.cancel_bid, err::action_not_public());
        cancel_bid_(book, requested_bid_offer_to_cancel, wallet, ctx)
    }
    public fun cancel_bid_protected<C: drop, FT>(
        _witness: C,
        book: &mut Orderbook<C, FT>,
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
    public entry fun create_ask<C, FT, Nft: store, Meta: store>(
        book: &mut Orderbook<C, FT>,
        requsted_tokens: u64,
        nft: NftOwned<Nft, Meta>,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.create_ask, err::action_not_public());
        create_ask_(book, requsted_tokens, nft, ctx)
    }
    public fun create_ask_protected<C: drop, FT, Nft: store, Meta: store>(
        _witness: C,
        book: &mut Orderbook<C, FT>,
        requsted_tokens: u64,
        nft: NftOwned<Nft, Meta>,
        ctx: &mut TxContext,
    ) {
        create_ask_(book, requsted_tokens, nft, ctx)
    }

    /// We could remove the NFT requested price from the argument, but then the
    /// search for the ask would be O(n) instead of O(log n).
    ///
    /// This API might be improved in future as we use a different data
    /// structure for the orderbook.
    public entry fun cancel_ask<C, FT>(
        book: &mut Orderbook<C, FT>,
        requested_price_to_cancel: u64,
        nft_id: ID,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.cancel_ask, err::action_not_public());
        cancel_ask_(book, requested_price_to_cancel, nft_id, ctx)
    }
    public entry fun cancel_ask_protected<C: drop, FT>(
        _witness: C,
        book: &mut Orderbook<C, FT>,
        requested_price_to_cancel: u64,
        nft_id: ID,
        ctx: &mut TxContext,
    ) {
        cancel_ask_(book, requested_price_to_cancel, nft_id, ctx)
    }

    /// Buys a specific NFT from the orderbook. This is an atypical OB API as
    /// with fungible tokens, you just want to get the cheapest ask.
    /// However, with NFTs, you might want to get a specific one.
    public entry fun buy_nft<C, FT>(
        book: &mut Orderbook<C, FT>,
        nft_id: ID,
        price: u64,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        assert!(book.protected_actions.buy_nft, err::action_not_public());
        buy_nft_(book, nft_id, price, wallet, ctx)
    }
    public entry fun buy_nft_protected<C: drop, FT>(
        _witness: C,
        book: &mut Orderbook<C, FT>,
        nft_id: ID,
        price: u64,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        buy_nft_(book, nft_id, price, wallet, ctx)
    }

    /// After a bid is matched with an ask, the buyer can claim the NFT via this
    /// method, because they will have received the ownership of the
    /// corresponding [`Ask`] object.
    public entry fun claim_nft<T: store, Meta: store>(
        ask: Ask,
        nft: NftOwned<T, Meta>,
        ctx: &mut TxContext,
    ) {
        claim_nft_(ask, nft, ctx)
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
    public fun create<C: drop, FT>(
        _witness: C,
        collection: ID,
        fee: FixedPoint32,
        ctx: &mut TxContext,
    ): Orderbook<C, FT> {
        create_<C, FT>(collection, fee, no_protection(), ctx)
    }

    public fun toggle_protection_on_buy_nft<C: drop, FT>(
        _witness: C,
        book: &mut Orderbook<C, FT>,
    ) {
        book.protected_actions.buy_nft =
            !book.protected_actions.buy_nft;
    }
    public fun toggle_protection_on_cancel_ask<C: drop, FT>(
        _witness: C,
        book: &mut Orderbook<C, FT>,
    ) {
        book.protected_actions.cancel_ask =
            !book.protected_actions.cancel_ask;
    }
    public fun toggle_protection_on_cancel_bid<C: drop, FT>(
        _witness: C,
        book: &mut Orderbook<C, FT>,
    ) {
        book.protected_actions.cancel_bid =
            !book.protected_actions.cancel_bid;
    }
    public fun toggle_protection_on_create_ask<C: drop, FT>(
        _witness: C,
        book: &mut Orderbook<C, FT>,
    ) {
        book.protected_actions.create_ask =
            !book.protected_actions.create_ask;
    }
    public fun toggle_protection_on_create_bid<C: drop, FT>(
        _witness: C,
        book: &mut Orderbook<C, FT>,
    ) {
        book.protected_actions.create_bid =
            !book.protected_actions.create_bid;
    }

    /// The contract which instantiated the OB implements logic for distibuting
    /// the fee based on its requirements.
    public fun fees_balance<C: drop, FT>(
        _witness: C,
        orderbook: &mut Orderbook<C, FT>,
    ): &mut Balance<FT> {
        fees_balance_(orderbook)
    }

    public fun collection_id<C, FT>(
        book: &Orderbook<C, FT>,
    ): ID {
        book.collection
    }

    public fun borrow_bids<C, FT>(
        book: &Orderbook<C, FT>,
    ): &CBTree<vector<Bid<FT>>> {
        &book.bids
    }

    public fun bid_offer<FT>(bid: &Bid<FT>): &Balance<FT> {
        &bid.offer
    }

    public fun bid_owner<FT>(bid: &Bid<FT>): address {
        bid.owner
    }

    public fun borrow_asks<C, FT>(
        book: &Orderbook<C, FT>,
    ): &CBTree<vector<Ask>> {
        &book.asks
    }

    public fun ask_price(ask: &Ask): u64 {
        ask.price
    }

    public fun ask_nft_id(ask: &Ask): ID {
        ask.nft
    }

    public fun ask_owner(ask: &Ask): address {
        ask.owner
    }

    fun create_<C, FT>(
        collection: ID,
        fee: FixedPoint32,
        protected_actions: WitnessProtectedActions,
        ctx: &mut TxContext,
    ): Orderbook<C, FT> {
        let id = object::new(ctx);
        let fees = Fees {
            uncollected: balance::zero(),
            fee,
        };

        Orderbook<C, FT> {
            id,
            collection,
            fees,
            protected_actions,
            asks: crit_bit::empty(),
            bids: crit_bit::empty(),
        }
    }

    fun fees_balance_<C, FT>(
        orderbook: &mut Orderbook<C, FT>,
    ): &mut Balance<FT> {
        &mut orderbook.fees.uncollected
    }

    fun create_bid_<C, FT>(
        book: &mut Orderbook<C, FT>,
        price: u64,
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

            transfer(coin::from_balance(bid_offer, ctx), ask.owner);
            transfer(ask, buyer);
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

    fun cancel_bid_<C, FT>(
        book: &mut Orderbook<C, FT>,
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

    fun create_ask_<C, FT, Nft: store, Meta: store>(
        book: &mut Orderbook<C, FT>,
        price: u64,
        nft: NftOwned<Nft, Meta>,
        ctx: &mut TxContext,
    ) {
        assert!(
            nft::collection_id(&nft) == book.collection,
            err::nft_collection_mismatch(),
        );

        let seller = tx_context::sender(ctx);

        let bids = &mut book.bids;

        let can_be_filled = !crit_bit::is_empty(bids) &&
            crit_bit::max_key(bids) <= price;

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
            // transfer FT to NFT owner
            transfer(coin::from_balance(bid_offer, ctx), seller);
            // transfer NFT to FT owner
            transfer(nft, buyer); // TODO: use the nft transfer fn
        } else {
            let id = object::new(ctx);
            let ask = Ask {
                id,
                price,
                nft: object::id(&nft),
                owner: seller,
            };
            // the NFT is now owned by the Ask object
            transfer_to_object(nft, &mut ask);
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

    fun cancel_ask_<C, FT>(
        book: &mut Orderbook<C, FT>,
        requested_price_to_cancel: u64,
        nft_id: ID,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);

        let ask = remove_ask(
            &mut book.asks,
            requested_price_to_cancel,
            nft_id,
        );

        assert!(ask.owner != sender, err::order_owner_must_be_sender());

        // TODO: figure out whether we can provide NftOwned here and do the
        // transfer without the intermediary step
        transfer(ask, sender);
    }

    fun buy_nft_<C, FT>(
        book: &mut Orderbook<C, FT>,
        nft_id: ID,
        price: u64,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext,
    ) {
        let buyer = tx_context::sender(ctx);

        let ask = remove_ask(
            &mut book.asks,
            price,
            nft_id,
        );

        // pay the NFT owner
        coin::split_and_transfer(wallet, price, ask.owner, ctx);

        // TODO: figure out whether we can provide NftOwned here and do the
        // transfer without the intermediary step
        transfer(ask, buyer);
    }

    /// The NFT is owned by the ask object, the ownership is transferred in
    /// the [`create_ask`] function.
    /// Here, we destruct the ask and give the ownership of the NFT to the owner
    /// of the ask object.
    /// To become an owner of an ask object, one has to create a bid which is
    /// filled.
    fun claim_nft_<T: store, Meta: store>(
        ask: Ask,
        nft: NftOwned<T, Meta>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);

        let Ask {
            nft: nft_id,
            id: ask_id,
            price: _,
            owner: _,
        } = ask;

        assert!(nft_id == object::id(&nft), err::nft_id_mismatch());

        object::delete(ask_id);
        transfer(nft, sender); // TODO: transfer must be done by the nft module
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
            if (nft_id == ask.nft) {
                break
            };

            index = index + 1;
        };

        assert!(index < asks_count, err::order_owner_must_be_sender());

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
