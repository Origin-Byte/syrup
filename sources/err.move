module liquidity_layer::err {
    //! Exports error functions. All errors in this smart contract have a prefix
    //! which distinguishes them from errors in other packages.

    const Prefix: u64 = 967100;

    public fun order_does_not_exist(): u64 {
        return Prefix + 00
    }

    public fun order_owner_must_be_sender(): u64 {
        return Prefix + 01
    }

    public fun nft_collection_mismatch(): u64 {
        return Prefix + 02
    }

    public fun nft_id_mismatch(): u64 {
        return Prefix + 03
    }

    public fun action_not_public(): u64 {
        return Prefix + 04
    }
}
