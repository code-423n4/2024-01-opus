use starknet::ContractAddress;
use wadray::{Ray, SignedRay};

#[starknet::interface]
trait IController<TContractState> {
    // View Functions
    fn get_current_multiplier(self: @TContractState) -> Ray;
    fn get_p_term(self: @TContractState) -> SignedRay;
    fn get_i_term(self: @TContractState) -> SignedRay;
    fn get_parameters(self: @TContractState) -> ((SignedRay, SignedRay), (u8, u8, u8, u8));

    // External Functions
    fn update_multiplier(ref self: TContractState);
    fn set_p_gain(ref self: TContractState, p_gain: Ray);
    fn set_i_gain(ref self: TContractState, i_gain: Ray);
    fn set_alpha_p(ref self: TContractState, alpha_p: u8);
    fn set_beta_p(ref self: TContractState, beta_p: u8);
    fn set_alpha_i(ref self: TContractState, alpha_i: u8);
    fn set_beta_i(ref self: TContractState, beta_i: u8);
}
