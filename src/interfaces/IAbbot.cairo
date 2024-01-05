use opus::types::AssetBalance;
use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
trait IAbbot<TContractState> {
    // getters
    fn get_trove_owner(self: @TContractState, trove_id: u64) -> Option<ContractAddress>;
    fn get_user_trove_ids(self: @TContractState, user: ContractAddress) -> Span<u64>;
    fn get_troves_count(self: @TContractState) -> u64;
    fn get_trove_asset_balance(self: @TContractState, trove_id: u64, yang: ContractAddress) -> u128;
    // external
    fn open_trove(
        ref self: TContractState, yang_assets: Span<AssetBalance>, forge_amount: Wad, max_forge_fee_pct: Wad
    ) -> u64;
    fn close_trove(ref self: TContractState, trove_id: u64);
    fn deposit(ref self: TContractState, trove_id: u64, yang_asset: AssetBalance);
    fn withdraw(ref self: TContractState, trove_id: u64, yang_asset: AssetBalance);
    fn forge(ref self: TContractState, trove_id: u64, amount: Wad, max_forge_fee_pct: Wad);
    fn melt(ref self: TContractState, trove_id: u64, amount: Wad);
}
