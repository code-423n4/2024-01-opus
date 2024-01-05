use starknet::ContractAddress;
use wadray::{Ray, Wad};

#[starknet::interface]
trait ISentinel<TContractState> {
    // getters
    fn get_gate_address(self: @TContractState, yang: ContractAddress) -> ContractAddress;
    fn get_gate_live(self: @TContractState, yang: ContractAddress) -> bool;
    fn get_yang_addresses(self: @TContractState) -> Span<ContractAddress>;
    fn get_yang_addresses_count(self: @TContractState) -> u64;
    fn get_yang(self: @TContractState, idx: u64) -> ContractAddress;
    fn get_yang_asset_max(self: @TContractState, yang: ContractAddress) -> u128;
    fn get_asset_amt_per_yang(self: @TContractState, yang: ContractAddress) -> Wad;
    // external
    fn add_yang(
        ref self: TContractState,
        yang: ContractAddress,
        yang_asset_max: u128,
        yang_threshold: Ray,
        yang_price: Wad,
        yang_rate: Ray,
        gate: ContractAddress
    );
    fn set_yang_asset_max(ref self: TContractState, yang: ContractAddress, new_asset_max: u128);
    fn enter(
        ref self: TContractState, yang: ContractAddress, user: ContractAddress, trove_id: u64, asset_amt: u128
    ) -> Wad;
    fn exit(
        ref self: TContractState, yang: ContractAddress, user: ContractAddress, trove_id: u64, yang_amt: Wad
    ) -> u128;
    fn kill_gate(ref self: TContractState, yang: ContractAddress);
    fn suspend_yang(ref self: TContractState, yang: ContractAddress);
    fn unsuspend_yang(ref self: TContractState, yang: ContractAddress);
    // view
    fn convert_to_yang(self: @TContractState, yang: ContractAddress, asset_amt: u128) -> Wad;
    fn convert_to_assets(self: @TContractState, yang: ContractAddress, yang_amt: Wad) -> u128;
}
