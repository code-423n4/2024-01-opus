// Note on fixed point math in Absorber:
//
// Non-Wad/Ray fixed-point values (i.e., values whose number of decimals is something other than 18 or 27)
// are used extensively throughout the contract. However, these values also rely on
// wadray-fixed-point arithmetic functions in their calculations. Consequently,
// wadray's internal functions are used to perform these calculations.
#[starknet::contract]
mod absorber {
    use access_control::access_control_component;
    use cmp::min;
    use integer::u256_safe_divmod;
    use opus::core::roles::absorber_roles;
    use opus::interfaces::IAbsorber::{IAbsorber, IBlesserDispatcher, IBlesserDispatcherTrait};
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::types::{AssetBalance, DistributionInfo, Provision, Request, Reward};
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use wadray::{Ray, RayZeroable, u128_wdiv, u128_wmul, Wad, WadZeroable};

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

    // If the amount of yin Wad per share drops below this threshold, the epoch is incremented
    // to reset the yin per share ratio to 1 : 1 parity for accounting. Otherwise, there will
    // eventually be an overflow when converting yin to shares (and vice versa)
    // as yin per share approaches 0.
    const YIN_PER_SHARE_THRESHOLD: u128 = 1000000000000000; // 10**15 = 0.001 (Wad)

    // Shares to be minted without a provider to avoid first provider front-running
    const INITIAL_SHARES: u128 = 1000; // 10 ** 3 (Wad);

    // Minimum total shares, including the initial shares, for each epoch
    // to prevent overflows in fixed point operations when the divisor (total shares)
    // is a very small number
    const MINIMUM_SHARES: u128 = 1000000; // 10 ** 6 (Wad);

    // First epoch of the Absorber
    const FIRST_EPOCH: u32 = 1;

    // Amount of time, in seconds, that needs to elapse after request is submitted before removal
    const REQUEST_BASE_TIMELOCK: u64 = 60;

    // Upper bound of time, in seconds, that needs to elapse after request is submitted before removal
    // 7 days * 24 hours per day * 60 minutes per hour * 60 seconds per minute
    const REQUEST_MAX_TIMELOCK: u64 = consteval_int!(7 * 24 * 60 * 60);

    // Multiplier for each request's timelock from the last value if a new request is submitted
    // before the cooldown of the previous request has elapsed
    const REQUEST_TIMELOCK_MULTIPLIER: u64 = 5;

    // Amount of time, in seconds, for which a request is valid, starting from expiry of the timelock
    // 60 minutes * 60 seconds per minute
    const REQUEST_VALIDITY_PERIOD: u64 = consteval_int!(60 * 60);

    // Amount of time that needs to elapse after a request is submitted before the timelock
    // for the next request is reset to the base value.
    // 7 days * 24 hours per day * 60 minutes per hour * 60 seconds per minute
    const REQUEST_COOLDOWN: u64 = consteval_int!(7 * 24 * 60 * 60);

    // Helper constant to set the starting index for iterating over the Rewards
    // in the order they were added
    const REWARDS_LOOP_START: u8 = 1;

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        // Sentinel associated with the Shrine for this Absorber
        sentinel: ISentinelDispatcher,
        // Shrine associated with this Absorber
        shrine: IShrineDispatcher,
        // boolean flag indicating whether the Absorber is live or not
        // once the Absorber is killed,
        // 1. users can no longer `provide` yin
        // 2. distribution of rewards via `bestow` stops
        is_live: bool,
        // epoch starts from 1
        // both shares and absorptions are tied to an epoch
        // the epoch is incremented when the amount of yin per share drops below the threshold.
        // this includes when the absorber's yin balance is completely depleted.
        current_epoch: u32,
        // absorptions start from 1.
        absorptions_count: u32,
        // mapping from a provider to the last absorption ID accounted for
        provider_last_absorption: LegacyMap::<ContractAddress, u32>,
        // mapping of address to a struct of
        // 1. epoch in which the provider's shares are issued
        // 2. number of shares for the provider in the above epoch
        provisions: LegacyMap::<ContractAddress, Provision>,
        // mapping from an absorption to its epoch
        absorption_epoch: LegacyMap::<u32, u32>,
        // total number of shares for current epoch
        total_shares: Wad,
        // mapping of a tuple of asset and absorption ID to a struct of
        // 1. the amount of that asset in its decimal precision absorbed per share Wad for an absorption
        // 2. the rounding error from calculating (1) that is to be added to the next absorption
        asset_absorption: LegacyMap::<(ContractAddress, u32), DistributionInfo>,
        // conversion rate of an epoch's shares to the next
        // if an update causes the yin per share to drop below the threshold,
        // the epoch is incremented and yin per share is reset to one Ray.
        // a provider with shares in that epoch will receive new shares in the next epoch
        // based on this conversion rate.
        // if the absorber's yin balance is wiped out, the conversion rate will be 0.
        epoch_share_conversion_rate: LegacyMap::<u32, Ray>,
        // total number of reward tokens, starting from 1
        // a reward token cannot be removed once added.
        rewards_count: u8,
        // mapping from a reward token address to its id for iteration
        reward_id: LegacyMap::<ContractAddress, u8>,
        // mapping from a reward token ID to its Reward struct:
        // 1. the ERC-20 token address
        // 2. the address of the vesting contract (blesser) implementing `IBlesser` for the ERC-20 token
        // 3. a boolean indicating if the blesser should be called
        rewards: LegacyMap::<u8, Reward>,
        // mapping from a reward token address and epoch to a struct of
        // 1. the cumulative amount of that reward asset in its decimal precision per share Wad in that epoch
        // 2. the rounding error from calculating (1) that is to be added to the next reward distribution
        cumulative_reward_amt_by_epoch: LegacyMap::<(ContractAddress, u32), DistributionInfo>,
        // mapping from a provider and reward token address to its last cumulative amount of that reward
        // per share Wad in the epoch of the provider's Provision struct
        provider_last_reward_cumulative: LegacyMap::<(ContractAddress, ContractAddress), u128>,
        // Mapping from a provider to its latest request for removal
        provider_request: LegacyMap::<ContractAddress, Request>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
        RewardSet: RewardSet,
        EpochChanged: EpochChanged,
        Provide: Provide,
        RequestSubmitted: RequestSubmitted,
        Remove: Remove,
        Reap: Reap,
        Gain: Gain,
        Bestow: Bestow,
        Killed: Killed,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct RewardSet {
        #[key]
        asset: ContractAddress,
        #[key]
        blesser: ContractAddress,
        is_active: bool
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct EpochChanged {
        old_epoch: u32,
        new_epoch: u32
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Provide {
        #[key]
        provider: ContractAddress,
        epoch: u32,
        yin: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct RequestSubmitted {
        #[key]
        provider: ContractAddress,
        timestamp: u64,
        timelock: u64
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Remove {
        #[key]
        provider: ContractAddress,
        epoch: u32,
        yin: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Reap {
        #[key]
        provider: ContractAddress,
        absorbed_assets: Span<AssetBalance>,
        reward_assets: Span<AssetBalance>
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Gain {
        assets: Span<AssetBalance>,
        total_recipient_shares: Wad,
        epoch: u32,
        absorption_id: u32
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Bestow {
        assets: Span<AssetBalance>,
        total_recipient_shares: Wad,
        epoch: u32
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Killed {}

    //
    // Constructor
    //
    #[constructor]
    fn constructor(
        ref self: ContractState, admin: ContractAddress, shrine: ContractAddress, sentinel: ContractAddress,
    ) {
        self.access_control.initializer(admin, Option::Some(absorber_roles::default_admin_role()));

        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.is_live.write(true);
        self.current_epoch.write(FIRST_EPOCH);
    }

    //
    // External Absorber functions
    //

    #[abi(embed_v0)]
    impl IAbsorberImpl of IAbsorber<ContractState> {
        //
        // Getters
        //

        fn get_rewards_count(self: @ContractState) -> u8 {
            self.rewards_count.read()
        }

        fn get_rewards(self: @ContractState) -> Span<Reward> {
            let rewards_count: u8 = self.rewards_count.read();

            let mut reward_id: u8 = REWARDS_LOOP_START;
            let mut rewards: Array<Reward> = ArrayTrait::new();

            loop {
                if reward_id == REWARDS_LOOP_START + rewards_count {
                    break rewards.span();
                }

                rewards.append(self.rewards.read(reward_id));
                reward_id += 1;
            }
        }

        fn get_current_epoch(self: @ContractState) -> u32 {
            self.current_epoch.read()
        }

        fn get_absorptions_count(self: @ContractState) -> u32 {
            self.absorptions_count.read()
        }

        fn get_absorption_epoch(self: @ContractState, absorption_id: u32) -> u32 {
            self.absorption_epoch.read(absorption_id)
        }

        fn get_total_shares_for_current_epoch(self: @ContractState) -> Wad {
            self.total_shares.read()
        }

        fn get_provision(self: @ContractState, provider: ContractAddress) -> Provision {
            self.provisions.read(provider)
        }

        fn get_provider_last_absorption(self: @ContractState, provider: ContractAddress) -> u32 {
            self.provider_last_absorption.read(provider)
        }

        fn get_provider_request(self: @ContractState, provider: ContractAddress) -> Request {
            self.provider_request.read(provider)
        }

        fn get_asset_absorption(self: @ContractState, asset: ContractAddress, absorption_id: u32) -> DistributionInfo {
            self.asset_absorption.read((asset, absorption_id))
        }

        fn get_cumulative_reward_amt_by_epoch(
            self: @ContractState, asset: ContractAddress, epoch: u32
        ) -> DistributionInfo {
            self.cumulative_reward_amt_by_epoch.read((asset, epoch))
        }

        fn get_provider_last_reward_cumulative(
            self: @ContractState, provider: ContractAddress, asset: ContractAddress
        ) -> u128 {
            self.provider_last_reward_cumulative.read((provider, asset))
        }

        fn get_live(self: @ContractState) -> bool {
            self.is_live.read()
        }


        //
        // View
        //

        // Returns true if the total shares in current epoch is at least `MINIMUM_SHARES`, so as
        // to prevent underflows when distributing absorbed assets and rewards.
        fn is_operational(self: @ContractState) -> bool {
            is_operational_helper(self.total_shares.read())
        }

        // Returns the maximum amount of yin removable by a provider.
        fn preview_remove(self: @ContractState, provider: ContractAddress) -> Wad {
            let provision: Provision = self.provisions.read(provider);
            let current_epoch: u32 = self.current_epoch.read();
            let current_provider_shares: Wad = self
                .convert_epoch_shares(provision.epoch, current_epoch, provision.shares);

            self.convert_to_yin(current_provider_shares)
        }


        // Returns the absorbed assets and rewards that a provider will receive based on
        // the current on-chain conditions
        fn preview_reap(self: @ContractState, provider: ContractAddress) -> (Span<AssetBalance>, Span<AssetBalance>) {
            let provision: Provision = self.provisions.read(provider);
            let current_epoch: u32 = self.current_epoch.read();

            let total_shares: Wad = self.total_shares.read();
            let current_provider_shares: Wad = self
                .convert_epoch_shares(provision.epoch, current_epoch, provision.shares);
            let include_pending_rewards: bool = is_operational_helper(total_shares)
                && current_provider_shares.is_non_zero();
            let (absorbed_assets, rewarded_assets) = self
                .get_absorbed_and_rewarded_assets_for_provider(provider, provision, include_pending_rewards);

            // NOTE: both absorbed assets and rewarded assets will be empty arrays
            // if `provision.shares` is zero.
            (absorbed_assets, rewarded_assets)
        }


        //
        // Setters
        //

        // Note: rewards ID start from index 1. This allows `set_reward` to be used for both
        // adding a new reward and updating an existing reward based on whether the initial
        // reward ID is zero (new reward) or non-zero (existing reward).
        fn set_reward(ref self: ContractState, asset: ContractAddress, blesser: ContractAddress, is_active: bool) {
            self.access_control.assert_has_role(absorber_roles::SET_REWARD);

            assert(asset.is_non_zero() && blesser.is_non_zero(), 'ABS: Address cannot be 0');

            let reward: Reward = Reward { asset, blesser: IBlesserDispatcher { contract_address: blesser }, is_active };

            // If this reward token hasn't been added yet, add it to the list
            let reward_id: u8 = self.reward_id.read(asset);

            if reward_id == 0 {
                let current_count: u8 = self.rewards_count.read();
                let new_count = current_count + 1;

                self.rewards_count.write(new_count);
                self.reward_id.write(asset, new_count);
                self.rewards.write(new_count, reward);
            } else {
                // Otherwise, update the existing reward
                self.rewards.write(reward_id, reward);
            }

            // Emit event
            self.emit(RewardSet { asset, blesser, is_active });
        }

        //
        // Core Absorber functions
        //

        // Supply yin to the absorber.
        // Requires the caller to have approved spending by the absorber.
        fn provide(ref self: ContractState, amount: Wad) {
            self.assert_live();

            let provider: ContractAddress = get_caller_address();

            // Withdraw absorbed collateral before updating shares
            let provision: Provision = self.provisions.read(provider);
            self.reap_helper(provider, provision);

            // Calculate number of shares to issue to provider and to add to total for current epoch
            // The two values deviate only when it is the first provision of an epoch and
            // total shares is below the minimum initial shares.
            let (new_provision_shares, issued_shares) = self.convert_to_shares(amount, false);

            // If epoch has changed, convert shares in previous epoch to new epoch's shares
            let current_epoch: u32 = self.current_epoch.read();
            let converted_shares: Wad = self.convert_epoch_shares(provision.epoch, current_epoch, provision.shares);

            let new_shares: Wad = converted_shares + new_provision_shares;
            self.provisions.write(provider, Provision { epoch: current_epoch, shares: new_shares });

            // Update total shares for current epoch
            self.total_shares.write(self.total_shares.read() + issued_shares);

            // Perform transfer of yin
            let absorber: ContractAddress = get_contract_address();

            let success: bool = self.yin_erc20().transfer_from(provider, absorber, amount.into());
            assert(success, 'ABS: Transfer failed');

            // Event emission
            self.emit(Provide { provider, epoch: current_epoch, yin: amount });
        }


        // Submit a request to `remove` that is valid for a fixed period of time after a variable timelock.
        // - This is intended to prevent atomic removals to avoid risk-free yield (from rewards and interest)
        //   frontrunning tactics.
        //   The timelock increases if another request is submitted before the previous has cooled down.
        // - A request is expended by either (1) a removal; (2) expiry; or (3) submitting a new request.
        // - Note: A request may become valid in the next epoch if a provider in the previous epoch
        //         submitted a request, a draining absorption occurs, and the provider provides again
        //         in the next epoch. This is expected to be rare, and the maximum risk-free profit is
        //         in any event greatly limited.
        fn request(ref self: ContractState) {
            let provider: ContractAddress = get_caller_address();
            assert_provider(self.provisions.read(provider));

            let request: Request = self.provider_request.read(provider);
            let current_timestamp: u64 = get_block_timestamp();

            let mut timelock: u64 = REQUEST_BASE_TIMELOCK;
            if request.timestamp + REQUEST_COOLDOWN > current_timestamp {
                timelock = request.timelock * REQUEST_TIMELOCK_MULTIPLIER;
            }

            let capped_timelock: u64 = min(timelock, REQUEST_MAX_TIMELOCK);
            self
                .provider_request
                .write(
                    provider, Request { timestamp: current_timestamp, timelock: capped_timelock, has_removed: false }
                );
            self.emit(RequestSubmitted { provider, timestamp: current_timestamp, timelock: capped_timelock });
        }

        // Withdraw yin (if any) and all absorbed collateral assets from the absorber.
        fn remove(ref self: ContractState, amount: Wad) {
            let provider: ContractAddress = get_caller_address();
            let provision: Provision = self.provisions.read(provider);
            assert_provider(provision);

            let mut request: Request = self.provider_request.read(provider);
            self.assert_can_remove(request);

            // Withdraw absorbed collateral before updating shares
            self.reap_helper(provider, provision);

            // Fetch the shares for current epoch
            let current_epoch: u32 = self.current_epoch.read();
            let current_provider_shares: Wad = self
                .convert_epoch_shares(provision.epoch, current_epoch, provision.shares);

            if current_provider_shares.is_zero() {
                // If no remaining shares after converting across epochs,
                // provider's deposit has been completely absorbed.
                // Since absorbed collateral have been reaped,
                // we can update the provision to current epoch and shares.
                self.provisions.write(provider, Provision { epoch: current_epoch, shares: WadZeroable::zero() });

                request.has_removed = true;
                self.provider_request.write(provider, request);

                // Event emission
                self.emit(Remove { provider, epoch: current_epoch, yin: WadZeroable::zero() });
            } else {
                // Calculations for yin need to be performed before updating total shares.
                // Cap `amount` to maximum removable for provider, then derive the number of shares.
                let max_removable_yin: Wad = self.convert_to_yin(current_provider_shares);
                let yin_amt: Wad = min(amount, max_removable_yin);

                // Due to precision loss, if the amount to remove is the max removable,
                // set the shares to be removed as the provider's balance to avoid
                // any remaining dust shares.
                let mut shares_to_remove = current_provider_shares;
                if yin_amt != max_removable_yin {
                    let (shares_to_remove_ceiled, _) = self.convert_to_shares(yin_amt, true);
                    shares_to_remove = shares_to_remove_ceiled;
                }

                self.total_shares.write(self.total_shares.read() - shares_to_remove);

                // Update provision
                let new_provider_shares: Wad = current_provider_shares - shares_to_remove;
                self.provisions.write(provider, Provision { epoch: current_epoch, shares: new_provider_shares });

                self
                    .provider_request
                    .write(
                        provider,
                        Request { timestamp: request.timestamp, timelock: request.timelock, has_removed: true }
                    );

                let success: bool = self.yin_erc20().transfer(provider, yin_amt.into());
                assert(success, 'ABS: Transfer failed');

                // Event emission
                self.emit(Remove { provider, epoch: current_epoch, yin: yin_amt });
            }
        }

        // Withdraw absorbed collateral only from the absorber
        // Note that `reap` alone will not update a caller's Provision in storage
        fn reap(ref self: ContractState) {
            let provider: ContractAddress = get_caller_address();
            let provision: Provision = self.provisions.read(provider);
            assert_provider(provision);

            self.reap_helper(provider, provision);

            // Update provider's epoch and shares to current epoch's
            // Epoch must be updated to prevent provider from repeatedly claiming rewards
            let current_epoch: u32 = self.current_epoch.read();
            let current_provider_shares: Wad = self
                .convert_epoch_shares(provision.epoch, current_epoch, provision.shares);
            self.provisions.write(provider, Provision { epoch: current_epoch, shares: current_provider_shares });
        }

        // Update assets received after an absorption
        fn update(ref self: ContractState, asset_balances: Span<AssetBalance>) {
            self.access_control.assert_has_role(absorber_roles::UPDATE);

            let current_epoch: u32 = self.current_epoch.read();

            // Trigger issuance of rewards
            self.bestow();

            // Increment absorption ID
            let current_absorption_id: u32 = self.absorptions_count.read() + 1;
            self.absorptions_count.write(current_absorption_id);

            // Update epoch for absorption ID
            self.absorption_epoch.write(current_absorption_id, current_epoch);

            // Exclude initial shares from the total amount of shares receiving absorbed assets
            let total_shares: Wad = self.total_shares.read();
            let total_recipient_shares: Wad = total_shares - INITIAL_SHARES.into();

            let mut asset_balances_copy = asset_balances;
            loop {
                match asset_balances_copy.pop_front() {
                    Option::Some(asset_balance) => {
                        self.update_absorbed_asset(current_absorption_id, total_recipient_shares, *asset_balance);
                    },
                    Option::None => { break; }
                };
            };

            //
            // Increment epoch ID only if yin per share drops below threshold or stability pool is emptied
            //

            let absorber: ContractAddress = get_contract_address();
            let yin_balance: Wad = self.yin_erc20().balance_of(absorber).try_into().unwrap();
            let yin_per_share: Wad = yin_balance / total_shares;

            // This also checks for absorber's yin balance being emptied because yin per share will be
            // below threshold if yin balance is 0.
            if YIN_PER_SHARE_THRESHOLD > yin_per_share.val {
                let new_epoch: u32 = current_epoch + 1;
                self.current_epoch.write(new_epoch);

                // If new epoch's yin balance exceeds the initial minimum shares, deduct the initial
                // minimum shares worth of yin from the yin balance so that there is at least such amount
                // of yin that cannot be removed in the next epoch.
                if INITIAL_SHARES < yin_balance.val {
                    let epoch_share_conversion_rate: Ray = wadray::rdiv_ww(
                        yin_balance - INITIAL_SHARES.into(), total_recipient_shares
                    );

                    self.epoch_share_conversion_rate.write(current_epoch, epoch_share_conversion_rate);
                    self.total_shares.write(yin_balance);
                } else {
                    // Otherwise, set the epoch share conversion rate to 0 and total shares to 0.
                    // This is to prevent an attacker from becoming a majority shareholder
                    // in a new epoch when the number of shares is very small, which would
                    // allow them to execute an attack similar to a first-deposit front-running attack.
                    // This would cause a negligible loss to the previous epoch's providers, but
                    // partially compensates the first provider in the new epoch for the deducted
                    // minimum initial amount.
                    self.epoch_share_conversion_rate.write(current_epoch, RayZeroable::zero());
                    self.total_shares.write(WadZeroable::zero());
                }

                self.emit(EpochChanged { old_epoch: current_epoch, new_epoch });

                // Transfer reward errors of current epoch to the next epoch
                self.propagate_reward_errors(current_epoch);
            }

            self
                .emit(
                    Gain {
                        assets: asset_balances,
                        total_recipient_shares,
                        epoch: current_epoch,
                        absorption_id: current_absorption_id
                    }
                );
        }

        fn kill(ref self: ContractState) {
            self.access_control.assert_has_role(absorber_roles::KILL);
            self.is_live.write(false);
            self.emit(Killed {});
        }
    }

    //
    // Internal Absorber functions
    //

    #[generate_trait]
    impl AbsorberHelpers of AbsorberHelpersTrait {
        //
        // Internal
        //

        #[inline(always)]
        fn assert_live(self: @ContractState) {
            assert(self.is_live.read(), 'ABS: Not live');
        }

        // Helper function to return a Yin ERC20 contract
        #[inline(always)]
        fn yin_erc20(self: @ContractState) -> IERC20Dispatcher {
            IERC20Dispatcher { contract_address: self.shrine.read().contract_address }
        }

        //
        // Internal - helpers for accounting of shares
        //

        // Convert to shares with a flag for whether the value should be rounded up or rounded down.
        // When converting to shares, we always favour the Absorber to the expense of the provider.
        // - Round down for `provide` (default for integer division)
        // - Round up for `remove`
        // Returns a tuple of the shares to be issued to the provider, and the total number of shares
        // issued for the system.
        // - There will be a difference between the two values only if it is the first `provide` of an epoch and
        //   the total shares is less than the minimum initial shares.
        fn convert_to_shares(self: @ContractState, yin_amt: Wad, round_up: bool) -> (Wad, Wad) {
            let total_shares: Wad = self.total_shares.read();

            if INITIAL_SHARES > total_shares.val {
                // By subtracting the initial shares from the first provider's shares, we ensure that
                // there is a non-removable amount of shares. This subtraction also prevents a user
                // from providing an amount less than the minimum shares.
                assert(yin_amt.val >= INITIAL_SHARES, 'ABS: provision < minimum');
                return ((yin_amt.val - INITIAL_SHARES).into(), yin_amt);
            }

            let absorber: ContractAddress = get_contract_address();
            let yin_balance: u256 = self.yin_erc20().balance_of(absorber);

            let (computed_shares, r, _) = u256_safe_divmod(
                yin_amt.into() * total_shares.into(), yin_balance.try_into().expect('Division by zero')
            );
            let computed_shares: u128 = computed_shares.try_into().unwrap();
            if round_up && r.is_non_zero() {
                return ((computed_shares + 1).into(), (computed_shares + 1).into());
            }
            (computed_shares.into(), computed_shares.into())
        }

        // This implementation is slightly different from Gate because the concept of shares is
        // used for internal accounting only, and both shares and yin are wads.
        fn convert_to_yin(self: @ContractState, shares_amt: Wad) -> Wad {
            let total_shares: Wad = self.total_shares.read();

            // If no shares are issued yet, then it is a new epoch and absorber is emptied.
            if total_shares.is_zero() {
                return WadZeroable::zero();
            }

            let absorber: ContractAddress = get_contract_address();
            let yin_balance: Wad = self.yin_erc20().balance_of(absorber).try_into().unwrap();

            (shares_amt * yin_balance) / total_shares
        }

        // Convert an epoch's shares to a subsequent epoch's shares
        fn convert_epoch_shares(self: @ContractState, start_epoch: u32, end_epoch: u32, start_shares: Wad) -> Wad {
            if start_epoch == end_epoch {
                return start_shares;
            }

            let epoch_conversion_rate: Ray = self.epoch_share_conversion_rate.read(start_epoch);
            let new_shares: Wad = wadray::rmul_wr(start_shares, epoch_conversion_rate);

            self.convert_epoch_shares(start_epoch + 1, end_epoch, new_shares)
        }

        //
        // Internal - helpers for `update`
        //

        // Helper function to update each provider's entitlement of an absorbed asset
        fn update_absorbed_asset(
            ref self: ContractState, absorption_id: u32, total_recipient_shares: Wad, asset_balance: AssetBalance
        ) {
            if asset_balance.amount.is_zero() {
                return;
            }

            let last_error: u128 = self.get_recent_asset_absorption_error(asset_balance.address, absorption_id);
            let total_amount_to_distribute: u128 = asset_balance.amount + last_error;

            let asset_amt_per_share: u128 = u128_wdiv(total_amount_to_distribute, total_recipient_shares.val);
            let actual_amount_distributed: u128 = u128_wmul(asset_amt_per_share, total_recipient_shares.val);
            let error: u128 = total_amount_to_distribute - actual_amount_distributed;

            self
                .asset_absorption
                .write((asset_balance.address, absorption_id), DistributionInfo { asset_amt_per_share, error });
        }

        // Returns the last error for an asset at a given `absorption_id` if the `asset_amt_per_share` is non-zero.
        // Otherwise, check `absorption_id - 1` recursively for the last error.
        fn get_recent_asset_absorption_error(self: @ContractState, asset: ContractAddress, absorption_id: u32) -> u128 {
            if absorption_id == 0 {
                return 0;
            }

            let absorption: DistributionInfo = self.asset_absorption.read((asset, absorption_id));
            // asset_amt_per_share is checked because it is possible for the error to be zero.
            // On the other hand, asset_amt_per_share may be zero in extreme edge cases with
            // a non-zero error that is spilled over to the next absorption.
            if absorption.asset_amt_per_share.is_non_zero() || absorption.error.is_non_zero() {
                return absorption.error;
            }

            self.get_recent_asset_absorption_error(asset, absorption_id - 1)
        }

        //
        // Internal - helpers for `reap`
        //

        // Wrapper function over `get_absorbed_assets_for_provider_helper` and
        // `get_provider_rewards` for re-use by `preview_reap` and
        // `reap_helper`
        fn get_absorbed_and_rewarded_assets_for_provider(
            self: @ContractState, provider: ContractAddress, provision: Provision, include_pending_rewards: bool
        ) -> (Span<AssetBalance>, Span<AssetBalance>) {
            let absorbed_assets: Span<AssetBalance> = self.get_absorbed_assets_for_provider_helper(provider, provision);
            let rewarded_assets: Span<AssetBalance> = self
                .get_provider_rewards(provider, provision, include_pending_rewards);

            (absorbed_assets, rewarded_assets)
        }

        // Internal function to be called whenever a provider takes an action to ensure absorbed assets
        // are properly transferred to the provider before updating the provider's information
        fn reap_helper(ref self: ContractState, provider: ContractAddress, provision: Provision) {
            // Trigger issuance of rewards
            self.bestow();

            // NOTE: both absorbed assets and rewarded assets will be empty arrays
            // if `provision.shares` is zero.
            let (absorbed_assets, rewarded_assets) = self
                .get_absorbed_and_rewarded_assets_for_provider(provider, provision, false);

            // Get and update provider's absorption ID
            self.provider_last_absorption.write(provider, self.absorptions_count.read());

            // Loop over absorbed and rewarded assets and transfer
            self.transfer_assets(provider, absorbed_assets);
            self.transfer_assets(provider, rewarded_assets);

            // NOTE: it is very important that this function is called, even for a new provider.
            // If a new provider's cumulative rewards are not updated to the current epoch,
            // then they will be zero, and the next time `reap_helper` is called, the provider
            // will receive all of the cumulative rewards for the current epoch, when they
            // should only receive the rewards for the current epoch since the last time
            // `reap_helper` was called.
            //
            // NOTE: We cannot rely on the array of reward addresses returned by
            // `get_absorbed_and_rewarded_assets_for_provider` because it returns an empty array when
            // `provision.shares` is zero. This would result in a bug where the reward cumulatives
            // for new providers are not updated to the latest epoch's values and start at 0. This
            // wrongly entitles a new provider to receive rewards from epoch 0 up to the
            // latest epoch's values, which would eventually result in an underflow when
            // transferring rewards during a `reap_helper` call.
            self.update_provider_cumulative_rewards(provider);

            self.emit(Reap { provider, absorbed_assets, reward_assets: rewarded_assets });
        }

        // Internal function to calculate the absorbed assets that a provider is entitled to
        // Returns a tuple of an array of assets and an array of amounts of each asset
        fn get_absorbed_assets_for_provider_helper(
            self: @ContractState, provider: ContractAddress, provision: Provision,
        ) -> Span<AssetBalance> {
            let mut absorbed_assets: Array<AssetBalance> = ArrayTrait::new();

            let current_absorption_id: u32 = self.absorptions_count.read();
            let provided_absorption_id: u32 = self.provider_last_absorption.read(provider);

            // Early termination by returning empty arrays

            if provision.shares.is_zero() || (current_absorption_id == provided_absorption_id) {
                return absorbed_assets.span();
            }

            let assets: Span<ContractAddress> = self.sentinel.read().get_yang_addresses();

            // Loop over all assets and calculate the amount of
            // each asset that the provider is entitled to
            let mut assets_copy = assets;
            loop {
                match assets_copy.pop_front() {
                    Option::Some(asset) => {
                        // Loop over all absorptions from `provided_absorption_id` for the current asset and add
                        // the amount of the asset that the provider is entitled to for each absorption to `absorbed_amt`.
                        let mut absorbed_amt: u128 = 0;
                        let mut start_absorption_id = provided_absorption_id;

                        loop {
                            if start_absorption_id == current_absorption_id {
                                break;
                            }

                            start_absorption_id += 1;
                            let absorption_epoch: u32 = self.absorption_epoch.read(start_absorption_id);

                            // If `provision.epoch == absorption_epoch`, then `adjusted_shares == provision.shares`.
                            let adjusted_shares: Wad = self
                                .convert_epoch_shares(provision.epoch, absorption_epoch, provision.shares);

                            // Terminate if provider does not have any shares for current epoch
                            if adjusted_shares.is_zero() {
                                break;
                            }

                            let absorption: DistributionInfo = self
                                .asset_absorption
                                .read((*asset, start_absorption_id));

                            absorbed_amt += u128_wmul(adjusted_shares.val, absorption.asset_amt_per_share);
                        };

                        absorbed_assets.append(AssetBalance { address: *asset, amount: absorbed_amt });
                    },
                    Option::None => { break absorbed_assets.span(); }
                };
            }
        }

        // Helper function to iterate over an array of assets to transfer to an address
        fn transfer_assets(ref self: ContractState, to: ContractAddress, mut asset_balances: Span<AssetBalance>) {
            loop {
                match asset_balances.pop_front() {
                    Option::Some(asset_balance) => {
                        if (*asset_balance.amount).is_non_zero() {
                            IERC20Dispatcher { contract_address: *asset_balance.address }
                                .transfer(to, (*asset_balance.amount).into());
                        }
                    },
                    Option::None => { break; },
                };
            };
        }

        //
        // Internal - helpers for remove
        //

        fn assert_can_remove(self: @ContractState, request: Request) {
            let shrine = self.shrine.read();
            // Removal is not allowed if Shrine is live and in recovery mode.
            if shrine.get_live() {
                assert(!shrine.is_recovery_mode(), 'ABS: Recovery Mode active');
            }

            assert(request.timestamp.is_non_zero(), 'ABS: No request found');
            assert(!request.has_removed, 'ABS: Only 1 removal per request');

            let current_timestamp: u64 = starknet::get_block_timestamp();
            let removal_start_timestamp: u64 = request.timestamp + request.timelock;
            assert(removal_start_timestamp <= current_timestamp, 'ABS: Request is not valid yet');
            assert(current_timestamp <= removal_start_timestamp + REQUEST_VALIDITY_PERIOD, 'ABS: Request has expired');
        }

        //
        // Internal - helpers for rewards
        //

        fn bestow(ref self: ContractState) {
            // Rewards are no longer distributed once Absorber is killed, but absorptions can still occur
            if !self.is_live.read() {
                return;
            }

            // Defer rewards until at least one provider deposits
            let total_shares: Wad = self.total_shares.read();
            if !is_operational_helper(total_shares) {
                return;
            }

            // Trigger issuance of active rewards
            let total_recipient_shares: Wad = total_shares - INITIAL_SHARES.into();

            let epoch: u32 = self.current_epoch.read();
            let mut blessed_assets: Array<AssetBalance> = ArrayTrait::new();
            let mut current_rewards_id: u8 = REWARDS_LOOP_START;

            let loop_end: u8 = self.rewards_count.read() + REWARDS_LOOP_START;
            loop {
                if current_rewards_id == loop_end {
                    break;
                }

                let reward: Reward = self.rewards.read(current_rewards_id);
                if !reward.is_active {
                    current_rewards_id += 1;
                    continue;
                }

                let blessed_amt = reward.blesser.bless();

                if blessed_amt.is_non_zero() {
                    blessed_assets.append(AssetBalance { address: reward.asset, amount: blessed_amt });

                    let epoch_reward_info: DistributionInfo = self
                        .cumulative_reward_amt_by_epoch
                        .read((reward.asset, epoch));
                    let total_amount_to_distribute: u128 = blessed_amt + epoch_reward_info.error;

                    let asset_amt_per_share: u128 = u128_wdiv(total_amount_to_distribute, total_recipient_shares.val);
                    let actual_amount_distributed: u128 = u128_wmul(asset_amt_per_share, total_recipient_shares.val);
                    let error: u128 = total_amount_to_distribute - actual_amount_distributed;

                    let updated_asset_amt_per_share: u128 = epoch_reward_info.asset_amt_per_share + asset_amt_per_share;

                    self
                        .cumulative_reward_amt_by_epoch
                        .write(
                            (reward.asset, epoch),
                            DistributionInfo { asset_amt_per_share: updated_asset_amt_per_share, error }
                        );
                }

                current_rewards_id += 1;
            };

            if blessed_assets.len().is_non_zero() {
                self.emit(Bestow { assets: blessed_assets.span(), total_recipient_shares, epoch });
            }
        }

        // Helper function to loop over all rewards and calculate the amounts for a provider.
        // Returns an array of `AssetBalance` struct for accumulated rewards, or accumulated plus
        // pending rewards, depending on the `include_pending_rewards` flag.
        fn get_provider_rewards(
            self: @ContractState, provider: ContractAddress, provision: Provision, include_pending_rewards: bool
        ) -> Span<AssetBalance> {
            let mut reward_assets: Array<AssetBalance> = ArrayTrait::new();
            let mut current_rewards_id: u8 = REWARDS_LOOP_START;

            // Return empty arrays if the provider has no shares
            if provision.shares.is_zero() {
                return reward_assets.span();
            }

            let outer_loop_end: u8 = self.rewards_count.read() + REWARDS_LOOP_START;
            let current_epoch: u32 = self.current_epoch.read();
            let inner_loop_end: u32 = current_epoch + 1;
            loop {
                if current_rewards_id == outer_loop_end {
                    break reward_assets.span();
                }

                let reward: Reward = self.rewards.read(current_rewards_id);
                let mut reward_amt: u128 = 0;
                let mut epoch: u32 = provision.epoch;
                let mut epoch_shares: Wad = provision.shares;

                loop {
                    // Terminate after the current epoch because we need to calculate rewards for the current
                    // epoch first
                    // There is also an early termination if the provider has no shares in current epoch
                    if (epoch == inner_loop_end) || epoch_shares.is_zero() {
                        break;
                    }

                    let epoch_reward_info: DistributionInfo = self
                        .cumulative_reward_amt_by_epoch
                        .read((reward.asset, epoch));

                    let asset_amt_per_share: u128 = if include_pending_rewards && epoch == current_epoch {
                        let total_recipient_shares: Wad = self.total_shares.read() - INITIAL_SHARES.into();
                        let pending_amt: u128 = reward.blesser.preview_bless();
                        let pending_amt_per_share: u128 = u128_wdiv(
                            pending_amt + epoch_reward_info.error, total_recipient_shares.val
                        );
                        epoch_reward_info.asset_amt_per_share + pending_amt_per_share
                    } else {
                        epoch_reward_info.asset_amt_per_share
                    };

                    // Calculate the difference with the provider's cumulative value if it is the
                    // same epoch as the provider's Provision epoch.
                    // This is because the provider's cumulative value may not have been fully updated for that epoch.
                    let rate: u128 = if epoch == provision.epoch {
                        asset_amt_per_share - self.provider_last_reward_cumulative.read((provider, reward.asset))
                    } else {
                        asset_amt_per_share
                    };
                    reward_amt += u128_wmul(rate, epoch_shares.val);

                    epoch_shares = self.convert_epoch_shares(epoch, epoch + 1, epoch_shares);

                    epoch += 1;
                };

                reward_assets.append(AssetBalance { address: reward.asset, amount: reward_amt });

                current_rewards_id += 1;
            }
        }

        // Update a provider's cumulative rewards to the given epoch
        // All rewards should be updated for a provider because an inactive reward may be set to active,
        // receive a distribution, and set to inactive again. If a provider's cumulative is not updated
        // for this reward, the provider can repeatedly claim the difference and drain the absorber.
        fn update_provider_cumulative_rewards(ref self: ContractState, provider: ContractAddress) {
            let mut current_rewards_id: u8 = REWARDS_LOOP_START;
            let epoch: u32 = self.current_epoch.read();
            let loop_end: u8 = self.rewards_count.read() + REWARDS_LOOP_START;
            loop {
                if current_rewards_id == loop_end {
                    break;
                }

                let reward: Reward = self.rewards.read(current_rewards_id);
                let epoch_reward_info: DistributionInfo = self
                    .cumulative_reward_amt_by_epoch
                    .read((reward.asset, epoch));
                self
                    .provider_last_reward_cumulative
                    .write((provider, reward.asset), epoch_reward_info.asset_amt_per_share);

                current_rewards_id += 1;
            };
        }

        // Transfers the error for a reward from the given epoch to the next epoch
        // `current_rewards_id` should start at `1`.
        fn propagate_reward_errors(ref self: ContractState, epoch: u32) {
            let mut current_rewards_id: u8 = REWARDS_LOOP_START;
            let loop_end: u8 = self.rewards_count.read() + REWARDS_LOOP_START;
            loop {
                if current_rewards_id == loop_end {
                    break;
                }

                let reward: Reward = self.rewards.read(current_rewards_id);
                let epoch_reward_info: DistributionInfo = self
                    .cumulative_reward_amt_by_epoch
                    .read((reward.asset, epoch));
                let next_epoch_reward_info: DistributionInfo = DistributionInfo {
                    asset_amt_per_share: 0, error: epoch_reward_info.error,
                };
                self.cumulative_reward_amt_by_epoch.write((reward.asset, epoch + 1), next_epoch_reward_info);
                current_rewards_id += 1;
            };
        }
    }

    //
    // Internal functions for Absorber that do not access storage
    //

    #[inline(always)]
    fn assert_provider(provision: Provision) {
        assert(provision.shares.is_non_zero(), 'ABS: Not a provider');
    }

    #[inline(always)]
    fn is_operational_helper(total_shares: Wad) -> bool {
        total_shares >= MINIMUM_SHARES.into()
    }
}
