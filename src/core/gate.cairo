#[starknet::contract]
mod gate {
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::IGate;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::utils::math::{fixed_point_to_wad, pow};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use wadray::{Wad, WadZeroable, WAD_DECIMALS, WAD_ONE};

    // As the Gate is similar to a ERC-4626 vault, it therefore faces a similar issue whereby
    // the first depositor can artificially inflate a share price by depositing the smallest
    // unit of an asset and then sending assets to the contract directly. This is addressed
    // in the Sentinel, which enforces a minimum deposit before a yang and its Gate can be
    // added to the Shrine.

    #[storage]
    struct Storage {
        // the Shrine associated with this Gate
        shrine: IShrineDispatcher,
        // the ERC-20 asset that is the underlying asset of this Gate's yang
        asset: IERC20Dispatcher,
        // the address of the Sentinel associated with this Gate
        // Also the only authorized caller of Gate
        sentinel: ContractAddress,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        Enter: Enter,
        Exit: Exit,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Enter {
        #[key]
        user: ContractAddress,
        #[key]
        trove_id: u64,
        asset_amt: u128,
        yang_amt: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Exit {
        #[key]
        user: ContractAddress,
        #[key]
        trove_id: u64,
        asset_amt: u128,
        yang_amt: Wad
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState, shrine: ContractAddress, asset: ContractAddress, sentinel: ContractAddress
    ) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.asset.write(IERC20Dispatcher { contract_address: asset });
        self.sentinel.write(sentinel);
    }

    //
    // External Gate functions
    //

    #[abi(embed_v0)]
    impl IGateImpl of IGate<ContractState> {
        //
        // Getters
        //

        fn get_shrine(self: @ContractState) -> ContractAddress {
            self.shrine.read().contract_address
        }

        fn get_sentinel(self: @ContractState) -> ContractAddress {
            self.sentinel.read()
        }

        fn get_asset(self: @ContractState) -> ContractAddress {
            self.asset.read().contract_address
        }

        fn get_total_assets(self: @ContractState) -> u128 {
            get_total_assets_helper(self.asset.read())
        }

        fn get_total_yang(self: @ContractState) -> Wad {
            self.get_total_yang_helper(self.asset.read().contract_address)
        }

        // Returns the amount of assets in Wad that corresponds to per Wad unit of yang.
        // If the asset's decimals is less than `WAD_DECIMALS`, the amount is scaled up accordingly.
        // Note that if there is no yang yet, this function will still return a positive value
        // based on the asset amount being at parity with yang (with scaling where necessary). This is
        // so that the yang price can be properly calculated by the oracle even if no assets have been
        // deposited yet.
        fn get_asset_amt_per_yang(self: @ContractState) -> Wad {
            let amt: u128 = self.convert_to_assets_helper(WAD_ONE.into());
            let decimals: u8 = self.asset.read().decimals();

            if decimals == WAD_DECIMALS {
                return amt.into();
            }

            fixed_point_to_wad(amt, decimals)
        }

        // This can be used to simulate the effects of `enter` at the current on-chain conditions.
        // `asset_amt` is denoted in the asset's decimals.
        fn convert_to_yang(self: @ContractState, asset_amt: u128) -> Wad {
            self.convert_to_yang_helper(asset_amt)
        }

        // This can be used to simulate the effects of `exit` at the current on-chain conditions.
        // The return value is denoted in the asset's decimals.
        fn convert_to_assets(self: @ContractState, yang_amt: Wad) -> u128 {
            self.convert_to_assets_helper(yang_amt)
        }

        //
        // Core Functions - External
        //

        // Transfers the stipulated amount of assets, in the asset's decimals, from the given
        // user to the Gate and returns the corresponding yang amount in Wad.
        // `asset_amt` is denominated in the decimals of the asset.
        fn enter(ref self: ContractState, user: ContractAddress, trove_id: u64, asset_amt: u128) -> Wad {
            self.assert_sentinel();

            let yang_amt: Wad = self.convert_to_yang_helper(asset_amt);
            if yang_amt.is_zero() {
                return WadZeroable::zero();
            }

            let success: bool = self.asset.read().transfer_from(user, get_contract_address(), asset_amt.into());
            assert(success, 'GA: Asset transfer failed');
            self.emit(Enter { user, trove_id, asset_amt, yang_amt });

            yang_amt
        }

        // Transfers such amount of assets, in the asset's decimals, corresponding to the
        // stipulated yang amount to the given user.
        // The return value is denominated in the decimals of the asset.
        fn exit(ref self: ContractState, user: ContractAddress, trove_id: u64, yang_amt: Wad) -> u128 {
            self.assert_sentinel();

            let asset_amt: u128 = self.convert_to_assets_helper(yang_amt);
            if asset_amt.is_zero() {
                return 0;
            }

            let success: bool = self.asset.read().transfer(user, asset_amt.into());
            assert(success, 'GA: Asset transfer failed');

            self.emit(Exit { user, trove_id, asset_amt, yang_amt });

            asset_amt
        }
    }

    //
    // Internal Gate functions
    //

    #[generate_trait]
    impl GateHelpers of GateHelpersTrait {
        #[inline(always)]
        fn assert_sentinel(self: @ContractState) {
            assert(get_caller_address() == self.sentinel.read(), 'GA: Caller is not authorized');
        }

        #[inline(always)]
        fn get_total_yang_helper(self: @ContractState, asset: ContractAddress) -> Wad {
            self.shrine.read().get_yang_total(asset)
        }

        // Helper function to calculate the amount of assets corresponding to the given
        // amount of yang.
        // Return value is denominated in the decimals of the asset.
        fn convert_to_assets_helper(self: @ContractState, yang_amt: Wad) -> u128 {
            let asset: IERC20Dispatcher = self.asset.read();
            let total_yang: Wad = self.get_total_yang_helper(asset.contract_address);

            if total_yang.is_zero() {
                let decimals: u8 = asset.decimals();
                // Scale `yang_amt` down by the difference to match the decimal
                // precision of the asset. If asset is of `Wad` precision, then
                // the same value is returned
                yang_amt.val / pow(10_u128, WAD_DECIMALS - decimals)
            } else {
                ((yang_amt * get_total_assets_helper(asset).into()) / total_yang).val
            }
        }

        // Helper function to calculate the amount of yang corresponding to the given
        // amount of assets.
        // `asset_amt` is denominated in the decimals of the asset.
        fn convert_to_yang_helper(self: @ContractState, asset_amt: u128) -> Wad {
            let asset: IERC20Dispatcher = self.asset.read();
            let total_yang: Wad = self.get_total_yang_helper(asset.contract_address);

            if total_yang.is_zero() {
                let decimals: u8 = asset.decimals();
                // Otherwise, scale `asset_amt` up by the difference to match `Wad`
                // precision of yang. If asset is of `Wad` precision, then the same
                // value is returned
                fixed_point_to_wad(asset_amt, decimals)
            } else {
                (asset_amt.into() * total_yang) / get_total_assets_helper(asset).into()
            }
        }
    }

    //
    // Internal functions for Gate that do not access Gate's storage
    //

    #[inline(always)]
    fn get_total_assets_helper(asset: IERC20Dispatcher) -> u128 {
        asset.balance_of(get_contract_address()).try_into().unwrap()
    }
}
