mod shrine_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use integer::{U128sFromFelt252Result, u128s_from_felt252, u128_safe_divmod, u128_try_as_non_zero};
    use opus::core::roles::shrine_roles;
    use opus::core::shrine::shrine as shrine_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::types::{Health, YangRedistribution};
    use opus::utils::exp::exp;
    use snforge_std::{
        declare, ContractClass, ContractClassTrait, start_prank, stop_prank, start_warp, CheatTarget, PrintTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{
        ContractAddress, contract_address_to_felt252, contract_address_try_from_felt252, get_block_timestamp
    };
    use wadray::{Ray, RayZeroable, RAY_ONE, Wad, WadZeroable, WAD_ONE};

    //
    // Constants
    //

    // Arbitrary timestamp set to approximately 18 May 2023, 7:55:28am UTC
    const DEPLOYMENT_TIMESTAMP: u64 = 1684390000_u64;

    // Number of seconds in an interval

    const FEED_LEN: u64 = 10;
    const PRICE_CHANGE: u128 = 25000000000000000000000000; // 2.5%

    // Shrine ERC-20 constants
    const YIN_NAME: felt252 = 'Cash';
    const YIN_SYMBOL: felt252 = 'CASH';

    // Shrine constants
    const MINIMUM_TROVE_VALUE: u128 = 50000000000000000000; // 50 (Wad)
    const DEBT_CEILING: u128 = 20000000000000000000000; // 20_000 (Wad)

    // Yang constants
    const YANG1_THRESHOLD: u128 = 800000000000000000000000000; // 80% (Ray)
    const YANG1_START_PRICE: u128 = 2000000000000000000000; // 2_000 (Wad)
    const YANG1_BASE_RATE: u128 = 20000000000000000000000000; // 2% (Ray)

    const YANG2_THRESHOLD: u128 = 750000000000000000000000000; // 75% (Ray)
    const YANG2_START_PRICE: u128 = 500000000000000000000; // 500 (Wad)
    const YANG2_BASE_RATE: u128 = 30000000000000000000000000; // 3% (Ray)

    const YANG3_THRESHOLD: u128 = 850000000000000000000000000; // 85% (Ray)
    const YANG3_START_PRICE: u128 = 1000000000000000000000; // 1_000 (Wad)
    const YANG3_BASE_RATE: u128 = 25000000000000000000000000; // 2.5% (Ray)

    const INITIAL_YANG_AMT: u128 = 0;

    const TROVE1_YANG1_DEPOSIT: u128 = 5000000000000000000; // 5 (Wad)
    const TROVE1_YANG2_DEPOSIT: u128 = 8000000000000000000; // 8 (Wad)
    const TROVE1_YANG3_DEPOSIT: u128 = 6000000000000000000; // 6 (Wad)
    const TROVE1_FORGE_AMT: u128 = 3000000000000000000000; // 3_000 (Wad)

    const WHALE_TROVE_YANG1_DEPOSIT: u128 = 1000000000000000000000; // 1000 (wad)
    const WHALE_TROVE_FORGE_AMT: u128 = 1000000000000000000000000; // 1,000,000 (wad)

    const RECOVERY_TESTS_TROVE1_FORGE_AMT: u128 = 7500000000000000000000; // 7500 (wad)

    //
    // Address constants
    //

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('shrine admin').unwrap()
    }

    fn yin_user_addr() -> ContractAddress {
        contract_address_try_from_felt252('yin user').unwrap()
    }

    fn yang1_addr() -> ContractAddress {
        contract_address_try_from_felt252('yang 1').unwrap()
    }

    fn yang2_addr() -> ContractAddress {
        contract_address_try_from_felt252('yang 2').unwrap()
    }

    fn yang3_addr() -> ContractAddress {
        contract_address_try_from_felt252('yang 3').unwrap()
    }

    fn invalid_yang_addr() -> ContractAddress {
        contract_address_try_from_felt252('invalid yang').unwrap()
    }

    //
    // Convenience helpers
    //

    // Wrapper function for Shrine
    #[inline(always)]
    fn shrine(shrine_addr: ContractAddress) -> IShrineDispatcher {
        IShrineDispatcher { contract_address: shrine_addr }
    }

    #[inline(always)]
    fn yin(shrine_addr: ContractAddress) -> IERC20Dispatcher {
        IERC20Dispatcher { contract_address: shrine_addr }
    }

    // Returns the interval ID for the given timestamp
    #[inline(always)]
    fn get_interval(timestamp: u64) -> u64 {
        timestamp / shrine_contract::TIME_INTERVAL
    }

    #[inline(always)]
    fn deployment_interval() -> u64 {
        get_interval(DEPLOYMENT_TIMESTAMP)
    }

    #[inline(always)]
    fn current_interval() -> u64 {
        get_interval(get_block_timestamp())
    }

    //
    // Test setup helpers
    //

    // Helper function to advance timestamp by one interval
    #[inline(always)]
    fn advance_interval() {
        common::advance_intervals(1);
    }

    fn two_yang_addrs() -> Span<ContractAddress> {
        let mut yang_addrs: Array<ContractAddress> = array![yang1_addr(), yang2_addr()];
        yang_addrs.span()
    }

    fn three_yang_addrs() -> Span<ContractAddress> {
        let mut yang_addrs: Array<ContractAddress> = array![yang1_addr(), yang2_addr(), yang3_addr()];
        yang_addrs.span()
    }

    // Note that iteration of yangs (e.g. in redistribution) start from the latest yang ID
    // and terminates at yang ID 0. This affects which yang receives any rounding of
    // debt that falls below the rounding threshold.
    fn two_yang_addrs_reversed() -> Span<ContractAddress> {
        let mut yang_addrs: Array<ContractAddress> = array![yang2_addr(), yang1_addr()];
        yang_addrs.span()
    }

    fn three_yang_addrs_reversed() -> Span<ContractAddress> {
        let mut yang_addrs: Array<ContractAddress> = array![yang3_addr(), yang2_addr(), yang1_addr(),];
        yang_addrs.span()
    }

    fn three_yang_start_prices() -> Span<Wad> {
        array![YANG1_START_PRICE.into(), YANG2_START_PRICE.into(), YANG3_START_PRICE.into(),].span()
    }

    fn declare_shrine() -> ContractClass {
        declare('shrine')
    }

    fn shrine_deploy(shrine_class: Option<ContractClass>) -> ContractAddress {
        let shrine_class = match shrine_class {
            Option::Some(class) => class,
            Option::None => declare_shrine()
        };

        let calldata: Array<felt252> = array![contract_address_to_felt252(admin()), YIN_NAME, YIN_SYMBOL,];

        start_warp(CheatTarget::All, DEPLOYMENT_TIMESTAMP);

        let shrine_addr = shrine_class.deploy(@calldata).expect('shrine deploy failed');

        shrine_addr
    }

    fn make_root(shrine_addr: ContractAddress, user: ContractAddress) {
        start_prank(CheatTarget::One(shrine_addr), admin());
        IAccessControlDispatcher { contract_address: shrine_addr }.grant_role(shrine_roles::all_roles(), user);
        stop_prank(CheatTarget::One(shrine_addr));
    }

    fn setup_debt_ceiling(shrine_addr: ContractAddress) {
        make_root(shrine_addr, admin());
        // Set debt ceiling
        start_prank(CheatTarget::One(shrine_addr), admin());
        let shrine = shrine(shrine_addr);
        shrine.set_debt_ceiling(DEBT_CEILING.into());
        // Reset contract address
        stop_prank(CheatTarget::One(shrine_addr));
    }

    fn shrine_setup(shrine_addr: ContractAddress) {
        setup_debt_ceiling(shrine_addr);
        let shrine = shrine(shrine_addr);
        start_prank(CheatTarget::One(shrine_addr), admin());

        // Add yangs
        shrine
            .add_yang(
                yang1_addr(),
                YANG1_THRESHOLD.into(),
                YANG1_START_PRICE.into(),
                YANG1_BASE_RATE.into(),
                INITIAL_YANG_AMT.into()
            );
        shrine
            .add_yang(
                yang2_addr(),
                YANG2_THRESHOLD.into(),
                YANG2_START_PRICE.into(),
                YANG2_BASE_RATE.into(),
                INITIAL_YANG_AMT.into()
            );
        shrine
            .add_yang(
                yang3_addr(),
                YANG3_THRESHOLD.into(),
                YANG3_START_PRICE.into(),
                YANG3_BASE_RATE.into(),
                INITIAL_YANG_AMT.into()
            );

        // Set minimum trove value
        shrine.set_minimum_trove_value(MINIMUM_TROVE_VALUE.into());

        // Reset contract address
        stop_prank(CheatTarget::One(shrine_addr));
    }

    // Advance the prices for two yangs, starting from the current interval and up to current interval + `num_intervals` - 1
    fn advance_prices_and_set_multiplier(
        shrine: IShrineDispatcher, num_intervals: u64, yangs: Span<ContractAddress>, yang_prices: Span<Wad>,
    ) -> Span<Span<Wad>> {
        assert(yangs.len() == yang_prices.len(), 'Array lengths mismatch');

        let mut yang_feeds: Array<Span<Wad>> = ArrayTrait::new();

        let mut yangs_copy = yangs;
        let mut yang_prices_copy = yang_prices;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(_) => { yang_feeds.append(generate_yang_feed(*yang_prices_copy.pop_front().unwrap())); },
                Option::None => { break; },
            };
        };
        let yang_feeds = yang_feeds.span();

        let mut idx: u32 = 0;
        let feed_len: u32 = num_intervals.try_into().unwrap();
        let mut timestamp: u64 = get_block_timestamp();

        start_prank(CheatTarget::One(shrine.contract_address), admin());
        loop {
            if idx == feed_len {
                break;
            }

            start_warp(CheatTarget::All, timestamp);

            let mut yangs_copy = yangs;
            let mut yang_feeds_copy = yang_feeds;
            loop {
                match yangs_copy.pop_front() {
                    Option::Some(yang) => { shrine.advance(*yang, *(*yang_feeds_copy.pop_front().unwrap()).at(idx)); },
                    Option::None => { break; },
                };
            };

            shrine.set_multiplier(RAY_ONE.into());

            timestamp += shrine_contract::TIME_INTERVAL;

            idx += 1;
        };

        // Reset contract address
        stop_prank(CheatTarget::One(shrine.contract_address));

        yang_feeds
    }

    #[inline(always)]
    fn shrine_setup_with_feed(shrine_class: Option<ContractClass>) -> IShrineDispatcher {
        let shrine_addr: ContractAddress = shrine_deploy(shrine_class);
        shrine_setup(shrine_addr);

        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_addr };
        advance_prices_and_set_multiplier(shrine, FEED_LEN, three_yang_addrs(), three_yang_start_prices());
        shrine
    }

    #[inline(always)]
    fn trove1_deposit(shrine: IShrineDispatcher, amt: Wad) {
        start_prank(CheatTarget::One(shrine.contract_address), admin());
        shrine.deposit(yang1_addr(), common::TROVE_1, amt);
        // Reset contract address
        stop_prank(CheatTarget::One(shrine.contract_address));
    }

    #[inline(always)]
    fn trove1_withdraw(shrine: IShrineDispatcher, amt: Wad) {
        start_prank(CheatTarget::One(shrine.contract_address), admin());
        shrine.withdraw(yang1_addr(), common::TROVE_1, amt);
        // Reset contract address
        stop_prank(CheatTarget::One(shrine.contract_address));
    }

    #[inline(always)]
    fn trove1_forge(shrine: IShrineDispatcher, amt: Wad) {
        start_prank(CheatTarget::One(shrine.contract_address), admin());
        shrine.forge(common::trove1_owner_addr(), common::TROVE_1, amt, WadZeroable::zero());
        // Reset contract address
        stop_prank(CheatTarget::One(shrine.contract_address));
    }

    #[inline(always)]
    fn trove1_melt(shrine: IShrineDispatcher, amt: Wad) {
        start_prank(CheatTarget::One(shrine.contract_address), admin());
        shrine.melt(common::trove1_owner_addr(), common::TROVE_1, amt);
        // Reset contract address
        stop_prank(CheatTarget::One(shrine.contract_address));
    }

    //
    // Test helpers
    //

    fn consume_first_bit(ref hash: u128) -> bool {
        let (reduced_hash, remainder) = u128_safe_divmod(hash, u128_try_as_non_zero(2_u128).unwrap());
        hash = reduced_hash;
        remainder != 0_u128
    }

    // Helper function to generate a price feed for a yang given a starting price
    // Currently increases the price at a fixed percentage per step
    fn generate_yang_feed(price: Wad) -> Span<Wad> {
        let mut prices: Array<Wad> = ArrayTrait::new();
        let mut price: Wad = price.into();
        let mut idx: u64 = 0;

        let price_hash: felt252 = pedersen::pedersen(price.val.into(), price.val.into());
        let mut price_hash = match u128s_from_felt252(price_hash) {
            U128sFromFelt252Result::Narrow(i) => { i },
            U128sFromFelt252Result::Wide((i, _)) => { i },
        };

        loop {
            if idx == FEED_LEN {
                break prices.span();
            }

            let price_change: Wad = wadray::rmul_wr(price, PRICE_CHANGE.into());
            let increase_price: bool = consume_first_bit(ref price_hash);
            if increase_price {
                price += price_change;
            } else {
                price -= price_change;
            }
            prices.append(price);

            idx += 1;
        }
    }

    // Helper function to get the prices for an array of yangs
    fn get_yang_prices(shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>) -> Span<Wad> {
        let mut yang_prices: Array<Wad> = ArrayTrait::new();
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang);
                    yang_prices.append(yang_price);
                },
                Option::None => { break; },
            };
        };
        yang_prices.span()
    }

    // Helper function to calculate the maximum forge amount given a tuple of three ordered arrays of
    // 1. yang prices
    // 2. yang amounts
    // 3. yang thresholds
    fn calculate_max_forge(
        mut yang_prices: Span<Wad>, mut yang_amts: Span<Wad>, mut yang_thresholds: Span<Ray>
    ) -> Wad {
        let (threshold, value) = calculate_trove_threshold_and_value(yang_prices, yang_amts, yang_thresholds);
        wadray::rmul_wr(value, threshold)
    }

    // Helper function to calculate the trove value and threshold given a tuple of three ordered arrays of
    // 1. yang prices
    // 2. yang amounts
    // 3. yang thresholds
    fn calculate_trove_threshold_and_value(
        mut yang_prices: Span<Wad>, mut yang_amts: Span<Wad>, mut yang_thresholds: Span<Ray>
    ) -> (Ray, Wad) {
        let mut cumulative_value = WadZeroable::zero();
        let mut cumulative_threshold = RayZeroable::zero();

        loop {
            match yang_prices.pop_front() {
                Option::Some(yang_price) => {
                    let amt: Wad = *yang_amts.pop_front().unwrap();
                    let threshold: Ray = *yang_thresholds.pop_front().unwrap();

                    let value = amt * *yang_price;
                    cumulative_value += value;
                    cumulative_threshold += wadray::wmul_wr(value, threshold);
                },
                Option::None => { break (wadray::wdiv_rw(cumulative_threshold, cumulative_value), cumulative_value); },
            };
        }
    }

    /// Helper function to calculate the compounded debt over a given set of intervals.
    ///
    /// Arguments
    ///
    /// * `yang_base_rates_history` - Ordered list of the lists of base rates of each yang at each rate update interval
    ///    over the time period `end_interval - start_interval`.
    ///    e.g. [[rate at update interval 1 for yang 1, ..., rate at update interval 1 for yang 2],
    ///          [rate at update interval n for yang 1, ..., rate at update interval n for yang 2]]`
    ///
    /// * `yang_rate_update_intervals` - Ordered list of the intervals at which each of the updates to the base rates were made.
    ///    The first interval in this list should be <= `start_interval`.
    ///
    /// * `yang_amts` - Ordered list of the amounts of each Yang over the given time period
    ///
    /// * `yang_avg_prices` - Ordered list of the average prices of each yang over each
    ///    base rate "era" (time period over which the base rate doesn't change).
    ///    [[yang1_price_era1, yang2_price_era1], [yang1_price_era2, yang2_price_era2]]
    ///    The first average price of each yang should be from `start_interval` to `yang_rate_update_intervals[1]`,
    ///    and from `yang_rate_update_intervals[i]` to `[i+1]` for the rest
    ///
    /// * `avg_multipliers` - List of average multipliers over each base rate "era"
    ///    (time period over which the base rate doesn't change).
    ///    The first average multiplier should be from `start_interval` to `yang_rate_update_intervals[1]`,
    ///    and from `yang_rate_update_intervals[i]` to `[i+1]` for the rest
    ///
    /// * `start_interval` - Start interval for the compounding period. This should be greater than or equal to the first interval
    ///    in `yang_rate_update_intervals`.
    ///
    /// * `end_interval` - End interval for the compounding period. This should be greater than or equal to the last interval
    ///    in  `yang_rate_update_intervals`.
    ///
    /// * `debt` - Amount of debt at `start_interval`
    fn compound(
        mut yang_base_rates_history: Span<Span<Ray>>,
        mut yang_rate_update_intervals: Span<u64>,
        mut yang_amts: Span<Wad>,
        mut yang_avg_prices: Span<Span<Wad>>,
        mut avg_multipliers: Span<Ray>,
        start_interval: u64,
        end_interval: u64,
        mut debt: Wad
    ) -> Wad {
        // Sanity check on input array lengths
        assert(yang_base_rates_history.len() == yang_rate_update_intervals.len(), 'array length mismatch');
        assert(yang_base_rates_history.len() == yang_avg_prices.len(), 'array length mismatch');
        assert(yang_base_rates_history.len() == avg_multipliers.len(), 'array length mismatch');
        assert((*yang_base_rates_history.at(0)).len() == yang_amts.len(), 'array length mismatch');
        let mut yang_base_rates_history_copy = yang_base_rates_history;
        let mut yang_avg_prices_copy = yang_avg_prices;
        loop {
            match yang_base_rates_history_copy.pop_front() {
                Option::Some(base_rates_history) => {
                    assert(
                        (*base_rates_history).len() == (*yang_avg_prices_copy.pop_front().unwrap()).len(),
                        'array length mismatch'
                    );
                },
                Option::None => { break; }
            };
        };

        // Start of tests

        let eras_count: usize = yang_base_rates_history.len();
        let yangs_count: usize = yang_amts.len();

        let mut i: usize = 0;
        loop {
            if i == eras_count {
                break debt;
            }

            let mut weighted_rate_sum: Ray = RayZeroable::zero();
            let mut total_avg_yang_value: Wad = WadZeroable::zero();

            let mut j: usize = 0;
            loop {
                if j == yangs_count {
                    break;
                }
                let yang_value: Wad = *yang_amts[j] * *yang_avg_prices.at(i)[j];
                total_avg_yang_value += yang_value;

                let weighted_rate: Ray = wadray::wmul_rw(*yang_base_rates_history.at(i)[j], yang_value);
                weighted_rate_sum += weighted_rate;

                j += 1;
            };
            let base_rate: Ray = wadray::wdiv_rw(weighted_rate_sum, total_avg_yang_value);
            let rate: Ray = base_rate * *avg_multipliers[i];

            // By default, the start interval for the current era is read from the provided array.
            // However, if it is the first era, we set the start interval to the start interval
            // for the entire compound operation.
            let mut era_start_interval: u64 = *yang_rate_update_intervals[i];
            if i == 0 {
                era_start_interval = start_interval;
            }

            // For any era other than the latest era, the length for a given era to compound for is the
            // difference between the start interval of the next era and the start interval of the current era.
            // For the latest era, then it is the difference between the end interval and the start interval
            // of the current era.
            let mut intervals_in_era: u64 = 0;
            if i == eras_count - 1 {
                intervals_in_era = end_interval - era_start_interval;
            } else {
                intervals_in_era = *yang_rate_update_intervals[i + 1] - era_start_interval;
            }

            let t: u128 = intervals_in_era.into() * shrine_contract::TIME_INTERVAL_DIV_YEAR;

            debt *= exp(wadray::rmul_rw(rate, t.into()));
            i += 1;
        }
    }

    // Compound function for a single yang, within a single era
    fn compound_for_single_yang(
        base_rate: Ray, avg_multiplier: Ray, start_interval: u64, end_interval: u64, debt: Wad,
    ) -> Wad {
        let intervals: u128 = (end_interval - start_interval).into();
        let t: Wad = (intervals * shrine_contract::TIME_INTERVAL_DIV_YEAR).into();
        debt * exp(wadray::rmul_rw(base_rate * avg_multiplier, t))
    }

    // Helper function to calculate average price of a yang over a period of intervals
    fn get_avg_yang_price(
        shrine: IShrineDispatcher, yang_addr: ContractAddress, start_interval: u64, end_interval: u64
    ) -> Wad {
        let feed_len: u128 = (end_interval - start_interval).into();
        let (_, start_cumulative_price) = shrine.get_yang_price(yang_addr, start_interval);
        let (_, end_cumulative_price) = shrine.get_yang_price(yang_addr, end_interval);

        ((end_cumulative_price - start_cumulative_price).val / feed_len).into()
    }

    // Helper function to calculate the average multiplier over a period of intervals
    // TODO: Do we need this? Maybe for when the controller is up
    fn get_avg_multiplier(shrine: IShrineDispatcher, start_interval: u64, end_interval: u64) -> Ray {
        let feed_len: u128 = (end_interval - start_interval).into();

        let (_, start_cumulative_multiplier) = shrine.get_multiplier(start_interval);
        let (_, end_cumulative_multiplier) = shrine.get_multiplier(end_interval);

        ((end_cumulative_multiplier - start_cumulative_multiplier).val / feed_len).into()
    }

    fn create_whale_trove(shrine: IShrineDispatcher) {
        start_prank(CheatTarget::One(shrine.contract_address), admin());
        // Deposit 1000 of yang1
        shrine.deposit(yang1_addr(), common::WHALE_TROVE, WHALE_TROVE_YANG1_DEPOSIT.into());
        // Mint 1 million yin (50% LTV at yang1's start price)
        shrine.forge(common::trove1_owner_addr(), common::WHALE_TROVE, WHALE_TROVE_FORGE_AMT.into(), 0_u128.into());
        stop_prank(CheatTarget::One(shrine.contract_address));
    }

    fn recovery_mode_test_setup(shrine_class: Option<ContractClass>) -> IShrineDispatcher {
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_deploy(shrine_class) };
        shrine_setup(shrine.contract_address);

        // Setting the debt and collateral ceilings high enough to accomodate a very large trove
        start_prank(CheatTarget::One(shrine.contract_address), admin());
        shrine.set_debt_ceiling((2000000 * WAD_ONE).into());

        // This creates the larger trove
        create_whale_trove(shrine);

        // Next, we create a trove with a 75% LTV (yang1's liquidation threshold is 80%)
        let trove1_deposit: Wad = TROVE1_YANG1_DEPOSIT.into();
        trove1_deposit(shrine, trove1_deposit); // yang1 price is 2000 (wad)
        trove1_forge(shrine, RECOVERY_TESTS_TROVE1_FORGE_AMT.into());
        shrine
    }

    //
    // Invariant helpers
    //

    // Asserts that for each yang, the total yang amount is less than or equal to the sum of
    // all troves' deposited amount, including any unpulled exceptional redistributions, and
    // the initial yang amount.
    // We do not check for strict equality because there may be loss of precision when
    // exceptionally redistributed yang are pulled into troves.
    fn assert_total_yang_invariant(shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>, troves_count: u64) {
        let troves_loop_end: u64 = troves_count + 1;

        let mut yang_id: u32 = 1;
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let initial_amt: Wad = shrine.get_initial_yang_amt(*yang);

                    let mut trove_id: u64 = 1;
                    let mut troves_cumulative_amt: Wad = WadZeroable::zero();
                    loop {
                        if trove_id == troves_loop_end {
                            break;
                        }

                        let mut trove_amt: Wad = shrine.get_deposit(*yang, trove_id);
                        let (mut redistributed_yangs, _) = shrine.get_redistributions_attributed_to_trove(trove_id);

                        loop {
                            match redistributed_yangs.pop_front() {
                                Option::Some(redistributed_yang) => {
                                    if *redistributed_yang.yang_id == yang_id {
                                        trove_amt += *redistributed_yang.amount;
                                    }
                                },
                                Option::None => { break; },
                            };
                        };
                        troves_cumulative_amt += trove_amt;

                        trove_id += 1;
                    };

                    let derived_yang_amt: Wad = troves_cumulative_amt + initial_amt;
                    let actual_yang_amt: Wad = shrine.get_yang_total(*yang);
                    assert(derived_yang_amt <= actual_yang_amt, 'yang invariant failed #1');

                    let error_margin: Wad = 100_u128.into();
                    common::assert_equalish(
                        derived_yang_amt, actual_yang_amt, error_margin, 'yang invariant failed #2'
                    );

                    yang_id += 1;
                },
                Option::None => { break; },
            };
        };
    }

    // Asserts that the total troves debt is less than or equal to the sum of all troves' debt, 
    // including all unpulled redistributions.
    // We do not check for strict equality because there may be loss of precision when 
    // redistributed debt are pulled into troves.
    fn assert_total_troves_debt_invariant(
        shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>, troves_count: u64,
    ) {
        let troves_loop_end: u64 = troves_count + 1;

        let mut total: Wad = WadZeroable::zero();
        let mut trove_id: u64 = 1;

        start_prank(CheatTarget::One(shrine.contract_address), admin());
        loop {
            if trove_id == troves_loop_end {
                break;
            }

            // Accrue interest on trove
            shrine.melt(admin(), trove_id, WadZeroable::zero());

            let trove_health: Health = shrine.get_trove_health(trove_id);
            total += trove_health.debt;

            trove_id += 1;
        };
        stop_prank(CheatTarget::One(shrine.contract_address));

        let redistributions_count: u32 = shrine.get_redistributions_count();

        let mut errors = WadZeroable::zero();
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let mut redistribution_id: u32 = redistributions_count;
                    loop {
                        if redistribution_id == 0 {
                            break;
                        }
                        let yang_redistribution: YangRedistribution = shrine
                            .get_redistribution_for_yang(*yang, redistribution_id);

                        // Find the last error for yang
                        if yang_redistribution.error.is_non_zero() {
                            errors += yang_redistribution.error;
                            break;
                        }

                        if yang_redistribution.unit_debt.is_zero() {
                            break;
                        }

                        redistribution_id -= 1;
                    };
                },
                Option::None => { break; },
            };
        };

        total += errors;

        let shrine_health: Health = shrine.get_shrine_health();
        assert(total <= shrine_health.debt, 'debt invariant failed #1');

        let error_margin: Wad = 10_u128.into();
        common::assert_equalish(total, shrine_health.debt, error_margin, 'debt invariant failed #2');
    }

    fn assert_shrine_invariants(shrine: IShrineDispatcher, yangs: Span<ContractAddress>, troves_count: u64) {
        assert_total_yang_invariant(shrine, yangs, troves_count);
        assert_total_troves_debt_invariant(shrine, yangs, troves_count);
    }
}
