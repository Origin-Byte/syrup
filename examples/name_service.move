module nft_liquidity_layer::name_service {
    //! This example showcases custom implementation for logic creating an ask.
    //!
    //! Now, marketplaces and wallets have two options: implement creating ask
    //! for Sui NS (via the standard e.g.) or decide to only enable bids and
    //! buying of name addreses on their platform, but skip selling.
    //!
    //! We name this "name_service" because one of the teams building a NS on
    //! Sui wanted to make trading of expired NFTs impossible.

    use nft_protocol::collection::{Self, Collection};
    use nft_protocol::nft::NftOwned;
    use nft_liquidity_layer::orderbook::{Self, Orderbook};
    use std::fixed_point32;
    use std::option::Option;
    use std::string::String;
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    // witness pattern
    // TODO: remove `store` once new version of nft-protocol lands
    struct NS has drop, store {}

    // user NFT data
    struct NSNftMetadata has key, store {
        id: UID,
        // points to `NSDomain`
        domain: ID,
        // some expiry info which will be used in `fun is_expired`
        expires_at: u64,
    }

    // holds global information about the NS collection, such as tld, registered
    // domains etc
    struct NSCollMetadata has store {
        admin: address,
        registered_domains: vector<String>,
    }

    // info specific to a domain that's global, owned e.g. by the collection
    // object or shared and only accessible by some authority
    struct NSDomain has key {
        id: UID,
        name: String,
        current_nft: Option<ID>,
    }

    fun is_expired(_nft: &NftOwned<NS, NSNftMetadata>): bool {
        // TODO: implement logic for determining if the domain is expired

        false
    }

    /// Joins the NFT liquidity layer but restricts asks such that they can only
    /// be called via this contract.
    public entry fun create_orderbook<FT>(
        col: &Collection<NS, NSCollMetadata>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(collection::metadata(col).admin == sender, 0);

        let fee = fixed_point32::create_from_rational(1, 100); // 1%

        let ob = orderbook::create<NS, FT>(NS {}, object::id(col), fee, ctx);
        orderbook::toggle_protection_on_create_ask(NS {}, &mut ob);

        transfer::share_object(ob);
    }

    /// The NFT can only be listed for sale if the domain is not expired.
    public entry fun create_ask<FT>(
        book: &mut Orderbook<NS, FT>,
        requsted_tokens: u64,
        nft: NftOwned<NS, NSNftMetadata>,
        ctx: &mut TxContext,
    ) {
        assert!(!is_expired(&nft), 0);
        orderbook::create_ask_protected(NS {}, book, requsted_tokens, nft, ctx)
    }
}
