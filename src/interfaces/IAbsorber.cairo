use opus::types::{AssetBalance, DistributionInfo, Provision, Request, Reward};
use starknet::ContractAddress;
use wadray::{Ray, Wad};

#[starknet::interface]
trait IAbsorber<TContractState> {
    // getters
    fn get_rewards_count(self: @TContractState) -> u8;
    fn get_rewards(self: @TContractState) -> Span<Reward>;
    fn get_current_epoch(self: @TContractState) -> u32;
    fn get_absorptions_count(self: @TContractState) -> u32;
    fn get_absorption_epoch(self: @TContractState, absorption_id: u32) -> u32;
    fn get_total_shares_for_current_epoch(self: @TContractState) -> Wad;
    fn get_provision(self: @TContractState, provider: ContractAddress) -> Provision;
    fn get_provider_last_absorption(self: @TContractState, provider: ContractAddress) -> u32;
    fn get_provider_request(self: @TContractState, provider: ContractAddress) -> Request;
    fn get_asset_absorption(self: @TContractState, asset: ContractAddress, absorption_id: u32) -> DistributionInfo;
    fn get_cumulative_reward_amt_by_epoch(
        self: @TContractState, asset: ContractAddress, epoch: u32
    ) -> DistributionInfo;
    fn get_provider_last_reward_cumulative(
        self: @TContractState, provider: ContractAddress, asset: ContractAddress
    ) -> u128;
    fn get_live(self: @TContractState) -> bool;
    fn is_operational(self: @TContractState) -> bool;
    fn preview_remove(self: @TContractState, provider: ContractAddress) -> Wad;
    fn preview_reap(self: @TContractState, provider: ContractAddress) -> (Span<AssetBalance>, Span<AssetBalance>);
    // external
    fn set_reward(ref self: TContractState, asset: ContractAddress, blesser: ContractAddress, is_active: bool);
    fn provide(ref self: TContractState, amount: Wad);
    fn request(ref self: TContractState);
    fn remove(ref self: TContractState, amount: Wad);
    fn reap(ref self: TContractState);
    fn update(ref self: TContractState, asset_balances: Span<AssetBalance>);
    fn kill(ref self: TContractState);
}

#[starknet::interface]
trait IBlesser<TContractState> {
    // external
    // If no reward tokens are to be distributed to the absorber, `preview_bless` and `bless`
    // should return 0 instead of reverting.
    fn bless(ref self: TContractState) -> u128;
    // view
    fn preview_bless(self: @TContractState) -> u128;
}
