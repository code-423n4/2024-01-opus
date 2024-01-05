#[starknet::contract]
mod abbot {
    use opus::interfaces::IAbbot::IAbbot;
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::types::AssetBalance;
    use opus::utils::reentrancy_guard::reentrancy_guard_component;
    use starknet::{ContractAddress, get_caller_address};
    use wadray::{BoundedWad, Wad};

    // 
    // Components 
    // 

    component!(path: reentrancy_guard_component, storage: reentrancy_guard, event: ReentrancyGuardEvent);

    impl ReentrancyGuardHelpers = reentrancy_guard_component::ReentrancyGuardHelpers<ContractState>;

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        reentrancy_guard: reentrancy_guard_component::Storage,
        // Shrine associated with this Abbot
        shrine: IShrineDispatcher,
        // Sentinel associated with this Abbot
        sentinel: ISentinelDispatcher,
        // total number of troves in a Shrine; monotonically increasing
        // also used to calculate the next ID (count+1) when opening a new trove
        // in essence, it serves as an index / primary key in a SQL table
        troves_count: u64,
        // the total number of troves of a particular address;
        // used to build the tuple key of `user_troves` variable
        // (user) -> (number of troves opened)
        user_troves_count: LegacyMap<ContractAddress, u64>,
        // a mapping of an address and index to a trove ID
        // belonging to this address; the index is a number from 0
        // up to `user_troves_count` for that address
        // (user, idx) -> (trove ID)
        user_troves: LegacyMap<(ContractAddress, u64), u64>,
        // a mapping of a trove ID to the contract address which
        // was used to open the trove
        // (trove ID) -> (owner)
        trove_owner: LegacyMap<u64, ContractAddress>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        TroveOpened: TroveOpened,
        TroveClosed: TroveClosed,
        // Component events
        ReentrancyGuardEvent: reentrancy_guard_component::Event
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct TroveOpened {
        #[key]
        user: ContractAddress,
        #[key]
        trove_id: u64
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct TroveClosed {
        #[key]
        trove_id: u64
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(ref self: ContractState, shrine: ContractAddress, sentinel: ContractAddress) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
    }

    //
    // External Abbot functions
    //

    #[abi(embed_v0)]
    impl IAbbotImpl of IAbbot<ContractState> {
        //
        // Getters
        //

        fn get_trove_owner(self: @ContractState, trove_id: u64) -> Option<ContractAddress> {
            let owner = self.trove_owner.read(trove_id);
            if owner.is_zero() {
                Option::None
            } else {
                Option::Some(owner)
            }
        }

        fn get_user_trove_ids(self: @ContractState, user: ContractAddress) -> Span<u64> {
            let mut trove_ids: Array<u64> = ArrayTrait::new();
            let user_troves_count: u64 = self.user_troves_count.read(user);
            let mut idx: u64 = 0;

            loop {
                if idx == user_troves_count {
                    break trove_ids.span();
                }
                trove_ids.append(self.user_troves.read((user, idx)));
                idx += 1;
            }
        }

        fn get_troves_count(self: @ContractState) -> u64 {
            self.troves_count.read()
        }

        fn get_trove_asset_balance(self: @ContractState, trove_id: u64, yang: ContractAddress) -> u128 {
            self.sentinel.read().convert_to_assets(yang, self.shrine.read().get_deposit(yang, trove_id))
        }

        //
        // Core functions
        //

        // create a new trove in the system with Yang deposits,
        // optionally forging Yin in the same operation (if `forge_amount` is 0, no Yin is created)
        fn open_trove(
            ref self: ContractState, mut yang_assets: Span<AssetBalance>, forge_amount: Wad, max_forge_fee_pct: Wad
        ) -> u64 {
            assert(yang_assets.len().is_non_zero(), 'ABB: No yangs');

            let troves_count: u64 = self.troves_count.read();
            self.troves_count.write(troves_count + 1);

            let user = get_caller_address();
            let user_troves_count: u64 = self.user_troves_count.read(user);
            self.user_troves_count.write(user, user_troves_count + 1);

            let new_trove_id: u64 = troves_count + 1;
            self.user_troves.write((user, user_troves_count), new_trove_id);
            self.trove_owner.write(new_trove_id, user);

            // deposit all requested Yangs into the system
            loop {
                match yang_assets.pop_front() {
                    Option::Some(yang_asset) => { self.deposit_helper(new_trove_id, user, *yang_asset); },
                    Option::None => { break; }
                };
            };

            // forge Yin
            self.shrine.read().forge(user, new_trove_id, forge_amount, max_forge_fee_pct);

            self.emit(TroveOpened { user, trove_id: new_trove_id });

            new_trove_id
        }

        // close a trove, repaying its debt in full and withdrawing all the Yangs
        fn close_trove(ref self: ContractState, trove_id: u64) {
            let user = get_caller_address();
            self.assert_trove_owner(user, trove_id);

            let shrine = self.shrine.read();
            // melting "max Wad" to instruct Shrine to melt *all* of trove's debt
            shrine.melt(user, trove_id, BoundedWad::max());

            let mut yangs: Span<ContractAddress> = self.sentinel.read().get_yang_addresses();
            // withdraw each and every Yang belonging to the trove from the system
            loop {
                match yangs.pop_front() {
                    Option::Some(yang) => {
                        let yang_amount: Wad = shrine.get_deposit(*yang, trove_id);
                        if yang_amount.is_zero() {
                            continue;
                        }
                        self.withdraw_helper(trove_id, user, *yang, yang_amount);
                    },
                    Option::None => { break; }
                };
            };

            self.emit(TroveClosed { trove_id });
        }

        // add Yang (an asset) to a trove
        fn deposit(ref self: ContractState, trove_id: u64, yang_asset: AssetBalance) {
            // There is no need to check the yang address is non-zero because the
            // Sentinel does not allow a zero address yang to be added.

            assert(trove_id != 0, 'ABB: Trove ID cannot be 0');
            assert(trove_id <= self.troves_count.read(), 'ABB: Non-existent trove');
            // note that caller does not need to be the trove's owner to deposit

            self.deposit_helper(trove_id, get_caller_address(), yang_asset);
        }

        // remove Yang (an asset) from a trove
        fn withdraw(ref self: ContractState, trove_id: u64, yang_asset: AssetBalance) {
            // There is no need to check the yang address is non-zero because the
            // Sentinel does not allow a zero address yang to be added.

            let user = get_caller_address();
            self.assert_trove_owner(user, trove_id);

            let yang_amt: Wad = self.sentinel.read().convert_to_yang(yang_asset.address, yang_asset.amount);
            self.withdraw_helper(trove_id, user, yang_asset.address, yang_amt);
        }

        // create Yin in a trove
        fn forge(ref self: ContractState, trove_id: u64, amount: Wad, max_forge_fee_pct: Wad) {
            let user = get_caller_address();
            self.assert_trove_owner(user, trove_id);
            self.shrine.read().forge(user, trove_id, amount, max_forge_fee_pct);
        }

        // destroy Yin from a trove
        fn melt(ref self: ContractState, trove_id: u64, amount: Wad) {
            // note that caller does not need to be the trove's owner to melt
            self.shrine.read().melt(get_caller_address(), trove_id, amount);
        }
    }

    //
    // Internal Abbot functions
    //

    #[generate_trait]
    impl AbbotHelpers of AbbotHelpersTrait {
        #[inline(always)]
        fn assert_trove_owner(self: @ContractState, user: ContractAddress, trove_id: u64) {
            assert(user == self.trove_owner.read(trove_id), 'ABB: Not trove owner')
        }

        #[inline(always)]
        fn deposit_helper(ref self: ContractState, trove_id: u64, user: ContractAddress, yang_asset: AssetBalance) {
            // reentrancy guard is used as a precaution
            self.reentrancy_guard.start();

            let yang_amt: Wad = self.sentinel.read().enter(yang_asset.address, user, trove_id, yang_asset.amount);
            self.shrine.read().deposit(yang_asset.address, trove_id, yang_amt);

            self.reentrancy_guard.end();
        }

        #[inline(always)]
        fn withdraw_helper(
            ref self: ContractState, trove_id: u64, user: ContractAddress, yang: ContractAddress, yang_amt: Wad
        ) {
            // reentrancy guard is used as a precaution
            self.reentrancy_guard.start();

            self.sentinel.read().exit(yang, user, trove_id, yang_amt);
            self.shrine.read().withdraw(yang, trove_id, yang_amt);

            self.reentrancy_guard.end();
        }
    }
}
