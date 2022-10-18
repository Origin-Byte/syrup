//! Taken from https://github.com/MystenLabs/sui/pull/4887/files#diff-96b0dc07cabd79292618c993cd473c43ca81cd2f742266014967cdea1a7c6186
//! and modified.
//!
//! This will eventually be part of a different package.

module liquidity_layer::safe {
    use sui::object::{ID, UID};
    use sui::transfer::transfer_to_object;
    use liquidity_layer::collection::{Self, TradeReceipt, TradingWhitelist};

    /// A shared object for storing NFT's of type `T`, owned by the holder of a unique `OwnerCap`.
    /// Permissions to allow others to list NFT's can be granted via TransferCap's and BorrowCap's
    struct Safe<phantom C> has key {
        id: UID,
        owner: address,
        // ... contains the fields from MR
    }

    /// A unique capability held by the owner of a particular `Safe`.
    /// The holder can issue and revoke `TransferCap`'s and `BorrowCap`'s.
    /// Can be used an arbitrary number of times
    struct OwnerCap has key, store {
        id: UID,
        /// The ID of the safe that this capability grants permissions to
        safe_id: ID,
    }

    /// Gives the holder permission to transfer the nft with id `nft_id` out of
    /// the safe with id `safe_id`. Can only be used once.
    struct TransferCap has key, store {
        id: UID,
        safe_id: ID,
        nft_id: ID,
    }

    // TODO: should this be a separate type? it's more explicit, but need to
    // duplicate fns. we could also have it as a flag on `TransferCap`
    struct ExclusiveTransferCap has key, store {
        id: UID,
        safe_id: ID,
        nft_id: ID,
    }

    /// Produce a `TransferCap` for the NFT with `id` in `safe`.
    /// This `TransferCap` can be (e.g.) used to list the NFT on a marketplace.
    public fun sell_nft<T>(_owner_cap: &OwnerCap, _id: ID, _safe: &mut T): TransferCap {
        abort(0)
    }

    public fun trade_nft<W, C>(
        _cap: TransferCap,
        _trade: TradeReceipt<W>,
        _whitelist: &TradingWhitelist<W, C>,
        _safe: &mut Safe<C>,
    ): C {
        abort(0)
    }

    public fun trade_nft_exclusive<W, C>(
        _cap: ExclusiveTransferCap,
        trade: TradeReceipt<W>,
        whitelist: &TradingWhitelist<W, C>,
        safe: &mut Safe<C>,
    ): C {
        // we cannot know whether the trade payment was honest or whether there
        // was a side payment, but at least we know that the payment was
        // considered and therefore if a contract wanted to avoid royalties,
        // they'd have to be _explicitly_ malicious
        assert!(collection::has_some_nft_payment(&trade), 0);

        assert!(collection::is_trade_source_whitelisted(&trade, whitelist), 0);

        transfer_to_object(trade, safe);

        abort(0)
    }

    public fun safe_owner<Col>(safe: &Safe<Col>): address {
        safe.owner
    }

    public fun exclusive_transfer_cap_safe_id(cap: &ExclusiveTransferCap): ID {
        cap.safe_id
    }

    public fun exclusive_transfer_cap_nft_id(cap: &ExclusiveTransferCap): ID {
        cap.nft_id
    }

    public fun transfer_cap_safe_id(cap: &TransferCap): ID {
        cap.safe_id
    }

    public fun transfer_cap_nft_id(cap: &TransferCap): ID {
        cap.nft_id
    }
}
