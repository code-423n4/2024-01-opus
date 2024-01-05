use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
use starknet::ContractAddress;

#[starknet::interface]
trait IFlashLiquidator<TContractState> {
    fn flash_liquidate(
        ref self: TContractState, trove_id: u64, yangs: Span<ContractAddress>, gates: Span<IGateDispatcher>
    );
}

#[starknet::contract]
mod flash_liquidator {
    use integer::BoundedInt;
    use opus::core::flash_mint::flash_mint::ON_FLASH_MINT_SUCCESS;
    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IFlashBorrower::IFlashBorrower;
    use opus::interfaces::IFlashMint::{IFlashMintDispatcher, IFlashMintDispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::types::AssetBalance;

    use starknet::{get_contract_address, ContractAddress};
    use wadray::{Wad, WAD_ONE, WadZeroable};

    #[storage]
    struct Storage {
        shrine: IShrineDispatcher,
        abbot: IAbbotDispatcher,
        flashmint: IFlashMintDispatcher,
        purger: IPurgerDispatcher,
    }


    #[constructor]
    fn constructor(
        ref self: ContractState,
        shrine: ContractAddress,
        abbot: ContractAddress,
        flashmint: ContractAddress,
        purger: ContractAddress
    ) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
        self.flashmint.write(IFlashMintDispatcher { contract_address: flashmint });
        self.purger.write(IPurgerDispatcher { contract_address: purger });
    }

    #[abi(embed_v0)]
    impl IFlashLiquidatorImpl of super::IFlashLiquidator<ContractState> {
        fn flash_liquidate(
            ref self: ContractState, trove_id: u64, mut yangs: Span<ContractAddress>, mut gates: Span<IGateDispatcher>
        ) {
            // Approve gate for tokens
            loop {
                match yangs.pop_front() {
                    Option::Some(yang) => {
                        let gate: IGateDispatcher = *gates.pop_front().unwrap();
                        let token = IERC20Dispatcher { contract_address: *yang };
                        token.approve(gate.contract_address, BoundedInt::max());
                    },
                    Option::None => { break; }
                };
            };

            let purger: IPurgerDispatcher = self.purger.read();
            let (_, max_close_amt) = purger.preview_liquidate(trove_id).expect('FL: not liquidatable');
            let mut call_data: Array<felt252> = array![trove_id.into()];

            self
                .flashmint
                .read()
                .flash_loan(
                    get_contract_address(), // receiver
                    self.shrine.read().contract_address, // token
                    max_close_amt.into(), // amount
                    call_data.span()
                );
        }
    }

    #[abi(embed_v0)]
    impl IFlashBorrowerImpl of IFlashBorrower<ContractState> {
        fn on_flash_loan(
            ref self: ContractState,
            initiator: ContractAddress,
            token: ContractAddress,
            amount: u256,
            fee: u256,
            mut call_data: Span<felt252>
        ) -> u256 {
            let flash_liquidator: ContractAddress = get_contract_address();

            assert(
                IERC20Dispatcher { contract_address: token }.balance_of(flash_liquidator) == amount,
                'FL: incorrect loan amount'
            );

            let trove_id: u64 = (*call_data.pop_front().unwrap()).try_into().unwrap();
            let freed_assets: Span<AssetBalance> = self
                .purger
                .read()
                .liquidate(trove_id, amount.try_into().unwrap(), flash_liquidator);

            let mut provider_assets: Span<u128> = provider_assets();
            let mut updated_assets: Array<AssetBalance> = ArrayTrait::new();
            let mut freed_assets_copy = freed_assets;
            loop {
                match freed_assets_copy.pop_front() {
                    Option::Some(freed_asset) => {
                        updated_assets
                            .append(
                                AssetBalance {
                                    address: *freed_asset.address,
                                    amount: *freed_asset.amount + *provider_assets.pop_front().unwrap()
                                }
                            );
                    },
                    Option::None => { break; },
                };
            };

            // Open a trove with funded and freed assets, and mint the loan amount.
            // This should revert if the contract did not receive the freed assets
            // from the liquidation.
            self.abbot.read().open_trove(updated_assets.span(), amount.try_into().unwrap(), WadZeroable::zero());

            ON_FLASH_MINT_SUCCESS
        }
    }

    // Copy of `provider_asset_amts` in `absorber_utils`
    fn provider_assets() -> Span<u128> {
        let mut asset_amts: Array<u128> = array![20 * WAD_ONE, // 20 (Wad) - ETH
         100000000, // 1 (10 ** 8) - BTC
        ];
        asset_amts.span()
    }
}
