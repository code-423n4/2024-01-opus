#[starknet::contract]
mod equalizer {
    use access_control::access_control_component;
    use cmp::min;
    use opus::core::roles::equalizer_roles;
    use opus::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IEqualizer::IEqualizer;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::types::Health;
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use wadray::{Ray, Signed, SignedWad, Wad, WadZeroable};

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        // the Allocator to read the current allocation of recipients of any minted
        // surplus debt, and their respective percentages
        allocator: IAllocatorDispatcher,
        // the Shrine that this Equalizer mints surplus debt for
        shrine: IShrineDispatcher,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
        Allocate: Allocate,
        AllocatorUpdated: AllocatorUpdated,
        Equalize: Equalize,
        Normalize: Normalize
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct AllocatorUpdated {
        old_address: ContractAddress,
        new_address: ContractAddress
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Equalize {
        yin_amt: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Normalize {
        #[key]
        caller: ContractAddress,
        yin_amt: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Allocate {
        recipients: Span<ContractAddress>,
        percentages: Span<Ray>,
        amount: Wad
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState, admin: ContractAddress, shrine: ContractAddress, allocator: ContractAddress
    ) {
        self.access_control.initializer(admin, Option::Some(equalizer_roles::default_admin_role()));

        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.allocator.write(IAllocatorDispatcher { contract_address: allocator });
    }

    //
    // External Equalizer functions
    //

    #[abi(embed_v0)]
    impl IEqualizerImpl of IEqualizer<ContractState> {
        //
        // Getters
        //

        fn get_allocator(self: @ContractState) -> ContractAddress {
            self.allocator.read().contract_address
        }

        //
        // Setters
        //

        // Update the Allocator's address
        fn set_allocator(ref self: ContractState, allocator: ContractAddress) {
            self.access_control.assert_has_role(equalizer_roles::SET_ALLOCATOR);

            let old_address: ContractAddress = self.allocator.read().contract_address;
            self.allocator.write(IAllocatorDispatcher { contract_address: allocator });

            self.emit(AllocatorUpdated { old_address, new_address: allocator });
        }

        //
        // Core functions - External
        //

        // Mint surplus debt to the Equalizer.
        // Returns the amount of surplus debt minted.
        fn equalize(ref self: ContractState) -> Wad {
            let shrine: IShrineDispatcher = self.shrine.read();

            let budget: SignedWad = shrine.get_budget();

            // `is_negative` is an inadequate check for performing an early return
            // here because it does not catch the case where budget is exactly zero.
            if !budget.is_positive() {
                return WadZeroable::zero();
            }

            let minted_surplus: Wad = budget.try_into().unwrap();

            // temporarily increase the debt ceiling by the injected amount 
            // so that surplus debt can still be minted when total yin is at
            // or exceeds the debt ceiling. Note that we need to adjust the 
            // budget first or the Shrine would double-count the injected amount 
            // and revert because the debt ceiling would be exceeded
            let ceiling: Wad = shrine.get_debt_ceiling();
            let total_yin: Wad = shrine.get_total_yin();
            let adjust_ceiling: bool = total_yin + minted_surplus > ceiling;
            if adjust_ceiling {
                shrine.set_debt_ceiling(total_yin + minted_surplus);
            }

            shrine.adjust_budget(SignedWad { val: minted_surplus.val, sign: true });
            shrine.inject(get_contract_address(), minted_surplus);

            if adjust_ceiling {
                shrine.set_debt_ceiling(ceiling);
            }

            self.emit(Equalize { yin_amt: minted_surplus });

            minted_surplus
        }

        // Allocate the yin balance of the Equalizer to the recipients in the allocation 
        // retrieved from the Allocator according to their respective percentage share.
        // Assumes the allocation from the Allocator has already been checked:
        // - both arrays of recipient addresses and percentages are of equal length;
        // - there is at least one recipient;
        // - the percentages add up to one Ray.
        fn allocate(ref self: ContractState) {
            let shrine: IShrineDispatcher = self.shrine.read();

            let yin = IERC20Dispatcher { contract_address: shrine.contract_address };
            let balance: Wad = shrine.get_yin(get_contract_address());

            if balance.is_zero() {
                return;
            }

            // Loop over equalizer's balance and transfer to recipients
            let allocator: IAllocatorDispatcher = self.allocator.read();
            let (recipients, percentages) = allocator.get_allocation();

            let mut amount_allocated: Wad = WadZeroable::zero();
            let mut recipients_copy = recipients;
            let mut percentages_copy = percentages;
            loop {
                match recipients_copy.pop_front() {
                    Option::Some(recipient) => {
                        let amount: Wad = wadray::rmul_wr(balance, *(percentages_copy.pop_front().unwrap()));

                        yin.transfer(*recipient, amount.into());
                        amount_allocated += amount;
                    },
                    Option::None => { break; }
                };
            };

            self.emit(Allocate { recipients, percentages, amount: amount_allocated });
        }

        // Burn yin from the caller's balance to wipe off any budget deficit in Shrine.
        // Anyone can call this function.
        // Returns the amount of deficit wiped.
        fn normalize(ref self: ContractState, yin_amt: Wad) -> Wad {
            let shrine: IShrineDispatcher = self.shrine.read();
            let budget: SignedWad = shrine.get_budget();
            if budget.is_negative() {
                let wipe_amt: Wad = min(yin_amt, budget.val.into());
                let caller: ContractAddress = get_caller_address();
                shrine.eject(caller, wipe_amt);
                shrine.adjust_budget(wipe_amt.into());

                self.emit(Normalize { caller, yin_amt: wipe_amt });

                wipe_amt
            } else {
                WadZeroable::zero()
            }
        }
    }
}
