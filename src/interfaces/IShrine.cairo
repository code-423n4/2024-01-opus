use opus::types::{ExceptionalYangRedistribution, Health, Trove, YangBalance, YangRedistribution, YangSuspensionStatus};
use starknet::ContractAddress;
use wadray::{Ray, SignedWad, Wad};

#[starknet::interface]
trait IShrine<TContractState> {
    // getters
    fn get_yin(self: @TContractState, user: ContractAddress) -> Wad;
    fn get_total_yin(self: @TContractState) -> Wad;
    fn get_yin_spot_price(self: @TContractState) -> Wad;
    fn get_yang_total(self: @TContractState, yang: ContractAddress) -> Wad;
    fn get_initial_yang_amt(self: @TContractState, yang: ContractAddress) -> Wad;
    fn get_yangs_count(self: @TContractState) -> u32;
    fn get_deposit(self: @TContractState, yang: ContractAddress, trove_id: u64) -> Wad;
    fn get_budget(self: @TContractState) -> SignedWad;
    fn get_yang_price(self: @TContractState, yang: ContractAddress, interval: u64) -> (Wad, Wad);
    fn get_yang_rate(self: @TContractState, yang: ContractAddress, rate_era: u64) -> Ray;
    fn get_current_rate_era(self: @TContractState) -> u64;
    fn get_minimum_trove_value(self: @TContractState) -> Wad;
    fn get_debt_ceiling(self: @TContractState) -> Wad;
    fn get_multiplier(self: @TContractState, interval: u64) -> (Ray, Ray);
    fn get_yang_suspension_status(self: @TContractState, yang: ContractAddress) -> YangSuspensionStatus;
    fn get_yang_threshold(self: @TContractState, yang: ContractAddress) -> (Ray, Ray);
    fn get_redistributions_count(self: @TContractState) -> u32;
    fn get_trove_redistribution_id(self: @TContractState, trove_id: u64) -> u32;
    fn get_redistribution_for_yang(
        self: @TContractState, yang: ContractAddress, redistribution_id: u32
    ) -> YangRedistribution;
    fn get_exceptional_redistribution_for_yang_to_yang(
        self: @TContractState,
        recipient_yang: ContractAddress,
        redistribution_id: u32,
        redistributed_yang: ContractAddress
    ) -> ExceptionalYangRedistribution;
    fn is_recovery_mode(self: @TContractState) -> bool;
    fn get_live(self: @TContractState) -> bool;
    // external setters
    fn add_yang(
        ref self: TContractState,
        yang: ContractAddress,
        threshold: Ray,
        start_price: Wad,
        initial_rate: Ray,
        initial_yang_amt: Wad
    );
    fn set_threshold(ref self: TContractState, yang: ContractAddress, new_threshold: Ray);
    fn suspend_yang(ref self: TContractState, yang: ContractAddress);
    fn unsuspend_yang(ref self: TContractState, yang: ContractAddress);
    fn update_rates(ref self: TContractState, yangs: Span<ContractAddress>, new_rates: Span<Ray>);
    fn advance(ref self: TContractState, yang: ContractAddress, price: Wad);
    fn set_multiplier(ref self: TContractState, multiplier: Ray);
    fn set_minimum_trove_value(ref self: TContractState, value: Wad);
    fn set_debt_ceiling(ref self: TContractState, ceiling: Wad);
    fn adjust_budget(ref self: TContractState, amount: SignedWad);
    fn update_yin_spot_price(ref self: TContractState, new_price: Wad);
    fn kill(ref self: TContractState);
    // external core functions
    fn deposit(ref self: TContractState, yang: ContractAddress, trove_id: u64, amount: Wad);
    fn withdraw(ref self: TContractState, yang: ContractAddress, trove_id: u64, amount: Wad);
    fn forge(ref self: TContractState, user: ContractAddress, trove_id: u64, amount: Wad, max_forge_fee_pct: Wad);
    fn melt(ref self: TContractState, user: ContractAddress, trove_id: u64, amount: Wad);
    fn seize(ref self: TContractState, yang: ContractAddress, trove_id: u64, amount: Wad);
    fn redistribute(ref self: TContractState, trove_id: u64, debt_to_redistribute: Wad, pct_value_to_redistribute: Ray);
    fn inject(ref self: TContractState, receiver: ContractAddress, amount: Wad);
    fn eject(ref self: TContractState, burner: ContractAddress, amount: Wad);
    // view
    fn get_shrine_health(self: @TContractState) -> Health;
    fn get_current_yang_price(self: @TContractState, yang: ContractAddress) -> (Wad, Wad, u64);
    fn get_current_multiplier(self: @TContractState) -> (Ray, Ray, u64);
    fn get_forge_fee_pct(self: @TContractState) -> Wad;
    fn is_healthy(self: @TContractState, trove_id: u64) -> bool;
    fn get_max_forge(self: @TContractState, trove_id: u64) -> Wad;
    fn get_trove_health(self: @TContractState, trove_id: u64) -> Health;
    fn get_redistributions_attributed_to_trove(self: @TContractState, trove_id: u64) -> (Span<YangBalance>, Wad);
}
