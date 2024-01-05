#[starknet::contract]
mod purger {
    use access_control::access_control_component;
    use cmp::min;
    use core::math::Oneable;
    use core::zeroable::Zeroable;
    use opus::core::roles::purger_roles;
    use opus::interfaces::IAbsorber::{IAbsorberDispatcher, IAbsorberDispatcherTrait};
    use opus::interfaces::IPurger::IPurger;
    use opus::interfaces::ISeer::{ISeerDispatcher, ISeerDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::types::{AssetBalance, Health};
    use opus::utils::reentrancy_guard::reentrancy_guard_component;
    use starknet::{ContractAddress, get_caller_address};
    use wadray::{Ray, RayZeroable, RAY_ONE, Wad, WadZeroable};

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    component!(path: reentrancy_guard_component, storage: reentrancy_guard, event: ReentrancyGuardEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    impl ReentrancyGuardHelpers = reentrancy_guard_component::ReentrancyGuardHelpers<ContractState>;

    //
    // Constants
    //

    // This is multiplied by a trove's threshold to determine the target LTV
    // the trove should have after a liquidation, which in turn determines the
    // maximum amount of the trove's debt that can be liquidated.
    const THRESHOLD_SAFETY_MARGIN: u128 = 900000000000000000000000000; // 0.9 (ray)

    // Maximum liquidation penalty (ray): 0.125 * RAY_ONE
    const MAX_PENALTY: u128 = 125000000000000000000000000;

    // Minimum liquidation penalty (ray): 0.03 * RAY_ONE
    const MIN_PENALTY: u128 = 30000000000000000000000000;

    // Bounds on the penalty scalar for absorber liquidations
    const MIN_PENALTY_SCALAR: u128 = 970000000000000000000000000; // 0.97 (ray) (1 - MIN_PENALTY)
    const MAX_PENALTY_SCALAR: u128 = 1060000000000000000000000000; // 1.06 (ray)

    // LTV past which the second precondition for `absorb` is satisfied even if
    // the trove's penalty is not at the absolute maximum given the LTV.
    const ABSORPTION_THRESHOLD: u128 = 900000000000000000000000000; // 0.9 (ray)

    // Maximum percentage of trove collateral that
    // is transferred to caller of `absorb` as compensation 3% = 0.03 (ray)
    const COMPENSATION_PCT: u128 = 30000000000000000000000000;

    // Cap on compensation value: 50 (Wad)
    const COMPENSATION_CAP: u128 = 50000000000000000000;

    // Minimum threshold for the penalty calculation, under which the
    // minimum penalty is automatically returned to avoid division by zero/overflow
    const MIN_THRESHOLD_FOR_PENALTY_CALCS: u128 = 10000000000000000000000000; // RAY_ONE = 1% (ray)

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        #[substorage(v0)]
        reentrancy_guard: reentrancy_guard_component::Storage,
        // the Shrine associated with this Purger
        shrine: IShrineDispatcher,
        // the Sentinel associated with the Shrine and this Purger
        sentinel: ISentinelDispatcher,
        // the Absorber associated with this Purger
        absorber: IAbsorberDispatcher,
        // the Seer module
        seer: ISeerDispatcher,
        // Scalar for multiplying penalties above `ABSORPTION_THRESHOLD`
        penalty_scalar: Ray,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
        PenaltyScalarUpdated: PenaltyScalarUpdated,
        Purged: Purged,
        Compensate: Compensate,
        // Component events
        ReentrancyGuardEvent: reentrancy_guard_component::Event
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct PenaltyScalarUpdated {
        new_scalar: Ray
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Purged {
        #[key]
        trove_id: u64,
        purge_amt: Wad,
        percentage_freed: Ray,
        #[key]
        funder: ContractAddress,
        #[key]
        recipient: ContractAddress,
        freed_assets: Span<AssetBalance>
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Compensate {
        #[key]
        recipient: ContractAddress,
        compensation: Span<AssetBalance>
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        shrine: ContractAddress,
        sentinel: ContractAddress,
        absorber: ContractAddress,
        seer: ContractAddress,
    ) {
        self.access_control.initializer(admin, Option::Some(purger_roles::default_admin_role()));

        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.absorber.write(IAbsorberDispatcher { contract_address: absorber });
        self.seer.write(ISeerDispatcher { contract_address: seer });

        self.penalty_scalar.write(RAY_ONE.into());
        self.emit(PenaltyScalarUpdated { new_scalar: RAY_ONE.into() });
    }

    #[abi(embed_v0)]
    impl IPurgerImpl of IPurger<ContractState> {
        //
        // View
        //

        // Returns a tuple of:
        // 1. the penalty (Ray)
        //    Returns 0 if trove is healthy, OR if the trove's LTV > 100%.
        //    Note that the penalty should not be used as a proxy to determine if a
        //    trove is liquidatable or not.
        // 2. the maximum amount of debt that can be liquidated for the trove (Wad)
        fn preview_liquidate(self: @ContractState, trove_id: u64) -> Option<(Ray, Wad)> {
            let trove_health: Health = self.shrine.read().get_trove_health(trove_id);
            preview_liquidate_internal(trove_health)
        }

        // Returns a tuple of:
        // 1. the penalty (Ray)
        //    Returns 0 if trove is healthy, OR not absorbable,
        //    OR if the trove's LTV after compensation is deducted exceeds 100%.
        //    Note that the penalty should not be used as a proxy to determine if a
        //    trove is absorbable or not.
        // 2. the maximum amount of debt that can be absorbed for the trove (Wad)
        // 3. the amount of compensation the caller will receive (Wad)
        fn preview_absorb(self: @ContractState, trove_id: u64) -> Option<(Ray, Wad, Wad)> {
            let trove_health: Health = self.shrine.read().get_trove_health(trove_id);

            match self.preview_absorb_internal(trove_health) {
                Option::Some((
                    penalty, max_absorption_amt, _, compensation, _, _,
                )) => { Option::Some((penalty, max_absorption_amt, compensation)) },
                Option::None => Option::None,
            }
        }

        fn is_absorbable(self: @ContractState, trove_id: u64) -> bool {
            let trove_health: Health = self.shrine.read().get_trove_health(trove_id);

            match self.preview_absorb_internal(trove_health) {
                Option::Some((_, _, _, _, _, _)) => true,
                Option::None => false,
            }
        }

        fn get_penalty_scalar(self: @ContractState) -> Ray {
            self.penalty_scalar.read()
        }

        //
        // External
        //
        fn set_penalty_scalar(ref self: ContractState, new_scalar: Ray) {
            self.access_control.assert_has_role(purger_roles::SET_PENALTY_SCALAR);
            assert(
                MIN_PENALTY_SCALAR.into() <= new_scalar && new_scalar <= MAX_PENALTY_SCALAR.into(), 'PU: Invalid scalar'
            );

            self.penalty_scalar.write(new_scalar);
            self.emit(PenaltyScalarUpdated { new_scalar });
        }

        // Performs searcher liquidations that requires the caller address to supply the amount of debt to repay
        // and the recipient address to send the freed collateral to.
        // Reverts if:
        // - the trove is not liquidatable (i.e. LTV > threshold).
        // - if the trove's LTV is worse off than before the liquidation (should not be possible, but as a precaution)
        // Returns an array of `AssetBalance` struct for the freed collateral due to the recipient for performing
        // the liquidation.
        fn liquidate(
            ref self: ContractState, trove_id: u64, amt: Wad, recipient: ContractAddress
        ) -> Span<AssetBalance> {
            let shrine: IShrineDispatcher = self.shrine.read();

            let trove_health: Health = shrine.get_trove_health(trove_id);

            let (trove_penalty, max_close_amt) = preview_liquidate_internal(trove_health)
                .expect('PU: Not liquidatable');

            // Cap the liquidation amount to the trove's maximum close amount
            let purge_amt: Wad = min(amt, max_close_amt);

            let percentage_freed: Ray = get_percentage_freed(
                trove_health.ltv, trove_health.value, trove_health.debt, trove_penalty, purge_amt
            );

            let funder: ContractAddress = get_caller_address();

            // Melt from the funder address directly
            // This step is also crucial because it would revert if the Shrine has been killed, thereby
            // preventing further liquidations.
            shrine.melt(funder, trove_id, purge_amt);

            // Free collateral corresponding to the purged amount
            let freed_assets: Span<AssetBalance> = self.free(shrine, trove_id, percentage_freed, recipient);

            // Safety check to ensure the new LTV is not worse off
            let updated_trove_health: Health = shrine.get_trove_health(trove_id);
            assert(updated_trove_health.ltv <= trove_health.ltv, 'PU: LTV increased');

            self.emit(Purged { trove_id, purge_amt, percentage_freed, funder, recipient, freed_assets });

            freed_assets
        }

        // Performs stability pool liquidations to pay down a trove's debt in full and transfer the
        // freed collateral to the stability pool. If the stability pool does not have sufficient yin,
        // the trove's debt and collateral will be proportionally redistributed among all troves
        // containing the trove's collateral.
        // - Amount of debt distributed to each collateral = (value of collateral / trove value) * trove debt
        // Reverts if the trove's LTV is not above the maximum penalty LTV
        // - This also checks the trove is liquidatable because threshold must be lower than max penalty LTV.
        // Returns an array of `AssetBalance` struct for the freed collateral due to the caller as compensation.
        fn absorb(ref self: ContractState, trove_id: u64) -> Span<AssetBalance> {
            let shrine: IShrineDispatcher = self.shrine.read();

            let trove_health: Health = shrine.get_trove_health(trove_id);

            let (
                trove_penalty,
                max_purge_amt,
                pct_value_to_compensate,
                _,
                ltv_after_compensation,
                value_after_compensation
            ) =
                self
                .preview_absorb_internal(trove_health)
                .expect('PU: Not absorbable');

            let caller: ContractAddress = get_caller_address();
            let absorber: IAbsorberDispatcher = self.absorber.read();

            // If the absorber is operational, cap the purge amount to the absorber's balance
            // (including if it is zero).
            let purge_amt = if absorber.is_operational() {
                min(max_purge_amt, shrine.get_yin(absorber.contract_address))
            } else {
                WadZeroable::zero()
            };

            // Transfer a percentage of the penalty to the caller as compensation
            let compensation_assets: Span<AssetBalance> = self.free(shrine, trove_id, pct_value_to_compensate, caller);

            // Melt the trove's debt using the absorber's yin directly
            // This needs to be called even if `purge_amt` is 0 so that accrued interest
            // will be charged on the trove before `shrine.redistribute`.
            // This step is also crucial because it would revert if the Shrine has been killed, thereby
            // preventing further liquidations.
            shrine.melt(absorber.contract_address, trove_id, purge_amt);

            let can_absorb_some: bool = purge_amt.is_non_zero();
            let is_fully_absorbed: bool = purge_amt == max_purge_amt;

            let pct_value_to_purge: Ray = if can_absorb_some {
                get_percentage_freed(
                    ltv_after_compensation, value_after_compensation, trove_health.debt, trove_penalty, purge_amt
                )
            } else {
                RayZeroable::zero()
            };

            // Only update the absorber and emit the `Purged` event if Absorber has some yin
            // to melt the trove's debt and receive freed trove assets in return
            if can_absorb_some {
                // Free collateral corresponding to the purged amount
                let absorbed_assets: Span<AssetBalance> = self
                    .free(shrine, trove_id, pct_value_to_purge, absorber.contract_address);
                absorber.update(absorbed_assets);

                self
                    .emit(
                        Purged {
                            trove_id,
                            purge_amt,
                            percentage_freed: pct_value_to_purge,
                            funder: absorber.contract_address,
                            recipient: absorber.contract_address,
                            freed_assets: absorbed_assets
                        }
                    );
            }

            // If it is not a full absorption, perform redistribution.
            if !is_fully_absorbed {
                // This is guaranteed to be greater than zero.
                let debt_to_redistribute: Wad = max_purge_amt - purge_amt;

                let redistribute_trove_debt_in_full: bool = max_purge_amt == trove_health.debt;
                let pct_value_to_redistribute: Ray = if redistribute_trove_debt_in_full {
                    RAY_ONE.into()
                } else {
                    let debt_after_absorption: Wad = trove_health.debt - purge_amt;
                    let value_after_absorption: Wad = value_after_compensation
                        - wadray::rmul_rw(pct_value_to_purge, value_after_compensation);
                    let ltv_after_absorption: Ray = wadray::rdiv_ww(debt_after_absorption, value_after_absorption);

                    get_percentage_freed(
                        ltv_after_absorption,
                        value_after_absorption,
                        debt_after_absorption,
                        trove_penalty,
                        debt_to_redistribute
                    )
                };
                shrine.redistribute(trove_id, debt_to_redistribute, pct_value_to_redistribute);

                // Update yang prices due to an appreciation in ratio of asset to yang from
                // redistribution
                self.seer.read().update_prices();
            }

            // Safety check to ensure the new LTV is not worse off
            let updated_trove_health: Health = shrine.get_trove_health(trove_id);
            assert(updated_trove_health.ltv <= trove_health.ltv, 'PU: LTV increased');

            self.emit(Compensate { recipient: caller, compensation: compensation_assets });

            compensation_assets
        }
    }


    //
    // Internal
    //

    #[generate_trait]
    impl PurgerHelpers of PurgerHelpersTrait {
        // Internal function to transfer the given percentage of a trove's collateral to the given
        // recipient address.
        // Returns an array of `AssetBalance` struct.
        fn free(
            ref self: ContractState,
            shrine: IShrineDispatcher,
            trove_id: u64,
            percentage_freed: Ray,
            recipient: ContractAddress,
        ) -> Span<AssetBalance> {
            self.reentrancy_guard.start();
            let sentinel: ISentinelDispatcher = self.sentinel.read();
            let yangs: Span<ContractAddress> = sentinel.get_yang_addresses();
            let mut freed_assets: Array<AssetBalance> = ArrayTrait::new();

            let mut yangs_copy: Span<ContractAddress> = yangs;

            // Loop through yang addresses and transfer to recipient
            loop {
                match yangs_copy.pop_front() {
                    Option::Some(yang) => {
                        let deposited_yang_amt: Wad = shrine.get_deposit(*yang, trove_id);

                        let freed_asset_amt: u128 = if deposited_yang_amt.is_zero() {
                            0
                        } else {
                            let freed_yang: Wad = wadray::rmul_wr(deposited_yang_amt, percentage_freed);
                            let exit_amt: u128 = sentinel.exit(*yang, recipient, trove_id, freed_yang);
                            shrine.seize(*yang, trove_id, freed_yang);
                            exit_amt
                        };

                        freed_assets.append(AssetBalance { address: *yang, amount: freed_asset_amt });
                    },
                    Option::None => { break; }
                };
            };

            self.reentrancy_guard.end();
            freed_assets.span()
        }

        // Returns `Option::None` if the trove is not absorbable, otherwise returns the absorption penalty
        // A trove is absorbable if and only if:
        // 1. ltv > threshold; and
        // 2. either of the following is true:
        //    a) its threshold is greater than `ABSORPTION_THRESHOLD`; or
        //    b) the penalty is at the maximum possible for the current LTV such that the post-liquidation
        //       LTV is not worse off (i.e. penalty == (1 - usable_ltv)/usable_ltv).
        //
        // If threshold exceeds ABSORPTION_THRESHOLD, the marginal penalty is scaled by `penalty_scalar`.
        fn get_absorption_penalty_internal(
            self: @ContractState, threshold: Ray, ltv: Ray, ltv_after_compensation: Ray
        ) -> Option<Ray> {
            if ltv <= threshold {
                return Option::None;
            }

            // It's possible for `ltv_after_compensation` to be greater than one, so we handle this case
            // to avoid underflow. Note that this also guarantees `ltv` is lesser than one.
            if ltv_after_compensation > RAY_ONE.into() {
                return Option::Some(RayZeroable::zero());
            }

            // If the threshold is below the given minimum, we automatically
            // return the maximum penalty to avoid division by zero/overflow, or the largest possible penalty,
            // whichever is smaller.
            if threshold < MIN_THRESHOLD_FOR_PENALTY_CALCS.into() {
                // This check is to avoid overflow in the event that the
                // trove's LTV is also extremely low.
                if ltv >= MIN_THRESHOLD_FOR_PENALTY_CALCS.into() {
                    return Option::Some(
                        min(MAX_PENALTY.into(), (RAY_ONE.into() - ltv_after_compensation) / ltv_after_compensation)
                    );
                }
                return Option::Some(MAX_PENALTY.into());
            }

            // The `ltv_after_compensation` is used to calculate the maximum penalty that can be charged
            // at the trove's current LTV after deducting compensation, while ensuring the LTV is not worse off
            // after absorption.
            let mut max_possible_penalty: Ray = min(
                (RAY_ONE.into() - ltv_after_compensation) / ltv_after_compensation, MAX_PENALTY.into()
            );

            if threshold > ABSORPTION_THRESHOLD.into() {
                let s = self.penalty_scalar.read();
                let penalty = min(MIN_PENALTY.into() + s * ltv / threshold - RAY_ONE.into(), max_possible_penalty);

                return Option::Some(penalty);
            }

            let penalty = min(MIN_PENALTY.into() + ltv / threshold - RAY_ONE.into(), max_possible_penalty);

            if penalty == max_possible_penalty {
                Option::Some(penalty)
            } else {
                Option::None
            }
        }

        // Helper function to return the following for a trove:
        // 1. absorption penalty (zero if trove is not absorbable)
        // 2. maximum absorption amount (zero if trove is not absorbable)
        // 3. compensation as a percentage of the trove's value (zero if trove is not absorbable)
        // 4. amount of compensation due to the caller (zero if trove is not absorbable)
        // 5. LTV after compensation (unchanged if trove is not absorbable)
        // 6. value after compensation (unchanged if trove is not absorbable)
        fn preview_absorb_internal(
            self: @ContractState, trove_health: Health
        ) -> Option<(Ray, Wad, Ray, Wad, Ray, Wad)> {
            let (compensation_pct, compensation) = get_compensation(trove_health.value);
            let ltv_after_compensation: Ray = trove_health.ltv / (RAY_ONE.into() - compensation_pct);

            match self
                .get_absorption_penalty_internal(trove_health.threshold, trove_health.ltv, ltv_after_compensation) {
                Option::Some(penalty) => {
                    let value_after_compensation: Wad = wadray::rmul_rw(
                        RAY_ONE.into() - compensation_pct, trove_health.value
                    );

                    // LTV and value after compensation are used to calculate the max purge amount
                    let max_absorption_amt: Wad = get_max_close_amount_internal(
                        trove_health.threshold, value_after_compensation, trove_health.debt, penalty
                    );

                    if max_absorption_amt.is_non_zero() {
                        Option::Some(
                            (
                                penalty,
                                max_absorption_amt,
                                compensation_pct,
                                compensation,
                                ltv_after_compensation,
                                value_after_compensation
                            )
                        )
                    } else {
                        Option::None
                    }
                },
                Option::None => Option::None,
            }
        }
    }

    //
    // Pure functions
    //

    // Returns the maximum amount of debt that can be paid off in a given liquidation
    // Note: this function reverts if the trove's LTV is below its threshold multiplied by `THRESHOLD_SAFETY_MARGIN`
    // because `debt - wadray::rmul_wr(value, target_ltv)` would underflow
    #[inline(always)]
    fn get_max_close_amount_internal(threshold: Ray, value: Wad, debt: Wad, penalty: Ray) -> Wad {
        let penalty_multiplier = RAY_ONE.into() + penalty;
        let target_ltv = THRESHOLD_SAFETY_MARGIN.into() * threshold;

        min(
            wadray::rdiv_wr(
                debt - wadray::rmul_wr(value, target_ltv), RAY_ONE.into() - penalty_multiplier * target_ltv
            ),
            debt
        )
    }

    // Returns `Option::None` if the trove is not liquidatable, otherwise returns the liquidation penalty
    fn get_liquidation_penalty_internal(threshold: Ray, ltv: Ray) -> Option<Ray> {
        if ltv <= threshold {
            return Option::None;
        }

        // Handling the case where `ltv > 1` to avoid underflow
        if ltv >= RAY_ONE.into() {
            return Option::Some(RayZeroable::zero());
        }

        // If the threshold is below the given minimum, we automatically
        // return the minimum penalty to avoid division by zero/overflow, or the largest possible penalty,
        // whichever is smaller.
        if threshold < MIN_THRESHOLD_FOR_PENALTY_CALCS.into() {
            // This check is to avoid overflow in the event that the
            // trove's LTV is also extremely low.
            if ltv >= MIN_THRESHOLD_FOR_PENALTY_CALCS.into() {
                return Option::Some(min(MAX_PENALTY.into(), (RAY_ONE.into() - ltv) / ltv));
            }
            return Option::Some(MAX_PENALTY.into());
        }

        let penalty = min(
            min(MIN_PENALTY.into() + ltv / threshold - RAY_ONE.into(), MAX_PENALTY.into()), (RAY_ONE.into() - ltv) / ltv
        );

        Option::Some(penalty)
    }

    // Helper function to return the following for a trove:
    // 1. liquidation penalty (zero if trove is not liquidatable)
    // 2. maximum liquidation amount (zero if trove is not liquidatable)
    fn preview_liquidate_internal(trove_health: Health) -> Option<(Ray, Wad)> {
        match get_liquidation_penalty_internal(trove_health.threshold, trove_health.ltv) {
            Option::Some(penalty) => {
                let max_close_amt = get_max_close_amount_internal(
                    trove_health.threshold, trove_health.value, trove_health.debt, penalty
                );

                if max_close_amt.is_non_zero() {
                    Option::Some((penalty, max_close_amt))
                } else {
                    Option::None
                }
            },
            Option::None => Option::None,
        }
    }

    // Helper function to calculate percentage of collateral freed.
    // If LTV <= 100%, calculate based on the sum of amount paid down and liquidation penalty divided by total trove value.
    // If LTV > 100%, pro-rate based on amount paid down divided by total debt.
    fn get_percentage_freed(trove_ltv: Ray, trove_value: Wad, trove_debt: Wad, penalty: Ray, purge_amt: Wad) -> Ray {
        if trove_ltv.val <= RAY_ONE {
            let penalty_amt: Wad = wadray::rmul_wr(purge_amt, penalty);
            wadray::rdiv_ww(purge_amt + penalty_amt, trove_value)
        } else {
            wadray::rdiv_ww(purge_amt, trove_debt)
        }
    }

    // Returns:
    // 1. the amount of compensation due to the caller of `absorb` as a percentage of
    //    the value of the trove's collateral, capped at 3% of the trove's value or the
    //    percentage of the trove's value equivalent to `COMPENSATION_CAP`
    // 2. the value of (1) in Wad
    fn get_compensation(trove_value: Wad) -> (Ray, Wad) {
        let default_compensation_pct: Ray = COMPENSATION_PCT.into();
        let default_compensation: Wad = wadray::rmul_wr(trove_value, default_compensation_pct);
        if default_compensation.val < COMPENSATION_CAP {
            (default_compensation_pct, default_compensation)
        } else {
            (wadray::rdiv_ww(COMPENSATION_CAP.into(), trove_value), COMPENSATION_CAP.into())
        }
    }
}
