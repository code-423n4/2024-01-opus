// NOTE: make sure the data feed coming from the oracle is denominated in the same
//       asset as the synthetic in Shrine; typically, feeds are in USD, but if the
//       synth is denominated in something else than USD and there's no feed for it,
//       this module cannot be used as-is, since the price coming from the oracle
//       would need to be divided by the synthetic's USD denominated peg price in
//       order to get ASSET/SYN

#[starknet::contract]
mod pragma {
    use access_control::access_control_component;
    use opus::core::roles::pragma_roles;
    use opus::interfaces::IOracle::IOracle;
    use opus::interfaces::IPragma::IPragma;
    use opus::interfaces::external::{IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait};
    use opus::types::pragma::{DataType, PragmaPricesResponse, PriceValidityThresholds};
    use opus::utils::math::fixed_point_to_wad;
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::Wad;

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    //
    // Constants
    //

    // there are sanity bounds for settable values, i.e. they can never
    // be set outside of this hardcoded range
    // the range is [lower, upper]
    const LOWER_FRESHNESS_BOUND: u64 = 60; // 1 minute
    const UPPER_FRESHNESS_BOUND: u64 = consteval_int!(4 * 60 * 60); // 4 hours * 60 minutes * 60 seconds
    const LOWER_SOURCES_BOUND: u32 = 3;
    const UPPER_SOURCES_BOUND: u32 = 13;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        // interface to the Pragma oracle contract
        oracle: IPragmaOracleDispatcher,
        // values used to determine if we consider a price update fresh or stale:
        // `freshness` is the maximum number of seconds between block timestamp and
        // the last update timestamp (as reported by Pragma) for which we consider a
        // price update valid
        // `sources` is the minimum number of data publishers used to aggregate the
        // price value
        price_validity_thresholds: PriceValidityThresholds,
        // A mapping between a token's address and the ID Pragma uses
        // to identify the price feed
        // (yang address) -> (Pragma pair ID)
        yang_pair_ids: LegacyMap::<ContractAddress, felt252>
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
        InvalidPriceUpdate: InvalidPriceUpdate,
        PriceValidityThresholdsUpdated: PriceValidityThresholdsUpdated,
        YangPairIdSet: YangPairIdSet,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct InvalidPriceUpdate {
        #[key]
        yang: ContractAddress,
        price: Wad,
        pragma_last_updated_ts: u64,
        pragma_num_sources: u32,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct OracleAddressUpdated {
        old_address: ContractAddress,
        new_address: ContractAddress
    }


    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct PriceValidityThresholdsUpdated {
        old_thresholds: PriceValidityThresholds,
        new_thresholds: PriceValidityThresholds
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct YangPairIdSet {
        address: ContractAddress,
        pair_id: felt252
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        oracle: ContractAddress,
        freshness_threshold: u64,
        sources_threshold: u32
    ) {
        self.access_control.initializer(admin, Option::Some(pragma_roles::default_admin_role()));

        // init storage
        self.oracle.write(IPragmaOracleDispatcher { contract_address: oracle });
        let new_thresholds = PriceValidityThresholds { freshness: freshness_threshold, sources: sources_threshold };
        self.price_validity_thresholds.write(new_thresholds);

        self
            .emit(
                PriceValidityThresholdsUpdated {
                    old_thresholds: PriceValidityThresholds { freshness: 0, sources: 0 }, new_thresholds
                }
            );
    }

    //
    // External Pragma functions
    //

    #[abi(embed_v0)]
    impl IPragmaImpl of IPragma<ContractState> {
        fn set_yang_pair_id(ref self: ContractState, yang: ContractAddress, pair_id: felt252) {
            self.access_control.assert_has_role(pragma_roles::ADD_YANG);
            assert(pair_id != 0, 'PGM: Invalid pair ID');
            assert(yang.is_non_zero(), 'PGM: Invalid yang address');

            // doing a sanity check if Pragma actually offers a price feed
            // of the requested asset and if it's suitable for our needs
            let response: PragmaPricesResponse = self.oracle.read().get_data_median(DataType::SpotEntry(pair_id));
            // Pragma returns 0 decimals for an unknown pair ID
            assert(response.decimals.is_non_zero(), 'PGM: Unknown pair ID');
            assert(response.decimals <= 18, 'PGM: Too many decimals');

            self.yang_pair_ids.write(yang, pair_id);

            self.emit(YangPairIdSet { address: yang, pair_id });
        }

        fn set_price_validity_thresholds(ref self: ContractState, freshness: u64, sources: u32) {
            self.access_control.assert_has_role(pragma_roles::SET_PRICE_VALIDITY_THRESHOLDS);
            assert(
                LOWER_FRESHNESS_BOUND <= freshness && freshness <= UPPER_FRESHNESS_BOUND, 'PGM: Freshness out of bounds'
            );
            assert(LOWER_SOURCES_BOUND <= sources && sources <= UPPER_SOURCES_BOUND, 'PGM: Sources out of bounds');

            let old_thresholds: PriceValidityThresholds = self.price_validity_thresholds.read();
            let new_thresholds = PriceValidityThresholds { freshness, sources };
            self.price_validity_thresholds.write(new_thresholds);

            self.emit(PriceValidityThresholdsUpdated { old_thresholds, new_thresholds });
        }
    }

    //
    // External oracle functions
    //

    #[abi(embed_v0)]
    impl IOracleImpl of IOracle<ContractState> {
        fn get_name(self: @ContractState) -> felt252 {
            'Pragma'
        }

        fn get_oracle(self: @ContractState) -> ContractAddress {
            self.oracle.read().contract_address
        }

        fn fetch_price(ref self: ContractState, yang: ContractAddress, force_update: bool) -> Result<Wad, felt252> {
            let pair_id: felt252 = self.yang_pair_ids.read(yang);
            assert(pair_id.is_non_zero(), 'PGM: Unknown yang');

            let response: PragmaPricesResponse = self.oracle.read().get_data_median(DataType::SpotEntry(pair_id));

            // convert price value to Wad
            let price: Wad = fixed_point_to_wad(response.price, response.decimals.try_into().unwrap());

            // if we receive what we consider a valid price from the oracle,
            // return it back, otherwise emit an event about the update being invalid
            // the check can be overridden with the `force_update` flag
            if force_update || self.is_valid_price_update(response) {
                return Result::Ok(price);
            }

            self
                .emit(
                    InvalidPriceUpdate {
                        yang,
                        price,
                        pragma_last_updated_ts: response.last_updated_timestamp,
                        pragma_num_sources: response.num_sources_aggregated,
                    }
                );
            Result::Err('PGM: Invalid price update')
        }
    }

    //
    // Internal functions
    //

    #[generate_trait]
    impl PragmaInternalFunctions of PragmaInternalFunctionsTrait {
        fn is_valid_price_update(self: @ContractState, update: PragmaPricesResponse) -> bool {
            let required: PriceValidityThresholds = self.price_validity_thresholds.read();

            // check if the update is from enough sources
            let has_enough_sources = required.sources <= update.num_sources_aggregated;

            // it is possible that the last_updated_ts is greater than the block_timestamp (in other words,
            // it is from the future from the chain's perspective), because the update timestamp is coming
            // from a data publisher while the block timestamp from the sequencer, they can be out of sync
            //
            // in such a case, we base the whole validity check only on the number of sources and we trust
            // Pragma with regards to data freshness - they have a check in place where they discard
            // updates that are too far in the future
            //
            // we considered having our own "too far in the future" check but that could lead to us
            // discarding updates in cases where just a single publisher would push updates with future
            // timestamp; that could be disastrous as we would have stale prices
            let block_timestamp = get_block_timestamp();
            let last_updated_timestamp: u64 = update.last_updated_timestamp;

            if block_timestamp <= last_updated_timestamp {
                return has_enough_sources;
            }

            // the result of `block_timestamp - last_updated_timestamp` can
            // never be negative if the code reaches here
            let is_fresh = (block_timestamp - last_updated_timestamp) <= required.freshness;

            has_enough_sources && is_fresh
        }
    }
}
