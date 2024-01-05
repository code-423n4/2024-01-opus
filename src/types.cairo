use cmp::min;
use core::fmt::{Debug, Display, DisplayInteger, Error, Formatter};
use integer::{u256_safe_div_rem, u256_try_as_non_zero};
use opus::interfaces::IAbsorber::IBlesserDispatcher;
use starknet::{ContractAddress, StorePacking};
use wadray::{Ray, Wad};

const TWO_POW_32: felt252 = 0x100000000;
const TWO_POW_64: felt252 = 0x10000000000000000;
const TWO_POW_122: felt252 = 0x4000000000000000000000000000000;
const TWO_POW_128: felt252 = 0x100000000000000000000000000000000;
const TWO_POW_250: felt252 = 0x400000000000000000000000000000000000000000000000000000000000000;

#[derive(Copy, Drop, PartialEq, Serde)]
enum YangSuspensionStatus {
    None,
    Temporary,
    Permanent
}

#[derive(Copy, Debug, Drop, Serde)]
struct Health {
    // Threshold at which a trove can be liquidated, or at which
    // recovery mode is triggered for Shrine
    threshold: Ray,
    // Debt as a percentage of value
    ltv: Ray,
    // Total value of collateral
    value: Wad,
    // Total amount of debt
    debt: Wad,
}

impl DisplayHealth of Display<Health> {
    fn fmt(self: @Health, ref f: Formatter) -> Result<(), Error> {
        Debug::fmt(self, ref f)
    }
}

#[derive(Copy, Debug, Drop, Serde)]
struct YangBalance {
    yang_id: u32, //  ID of yang in Shrine
    amount: Wad, // Amount of yang in Wad
}

impl DisplayYangBalance of Display<YangBalance> {
    fn fmt(self: @YangBalance, ref f: Formatter) -> Result<(), Error> {
        Debug::fmt(self, ref f)
    }
}

#[derive(Copy, Drop, PartialEq, Serde)]
struct AssetBalance {
    address: ContractAddress, // Address of the ERC-20 asset
    amount: u128, // Amount of the asset in the asset's decimals
}

#[derive(Copy, Debug, Drop, PartialEq, Serde)]
struct Trove {
    charge_from: u64, // Time ID (timestamp // TIME_ID_INTERVAL) for start of next accumulated interest calculation
    last_rate_era: u64,
    debt: Wad, // Normalized debt
}

impl DisplayTrove of Display<Trove> {
    fn fmt(self: @Trove, ref f: Formatter) -> Result<(), Error> {
        Debug::fmt(self, ref f)
    }
}

impl TroveStorePacking of StorePacking<Trove, u256> {
    fn pack(value: Trove) -> u256 {
        (value.charge_from.into()
            + (value.last_rate_era.into() * TWO_POW_64.into())
            + (value.debt.into() * TWO_POW_128.into()))
    }

    fn unpack(value: u256) -> Trove {
        let shift: NonZero<u256> = u256_try_as_non_zero(TWO_POW_64.into()).unwrap();
        let (rest, charge_from) = u256_safe_div_rem(value, shift);
        let (debt, last_rate_era) = u256_safe_div_rem(rest, shift);

        Trove {
            charge_from: charge_from.try_into().unwrap(),
            last_rate_era: last_rate_era.try_into().unwrap(),
            debt: debt.try_into().unwrap(),
        }
    }
}

#[derive(Copy, Debug, Drop, Serde)]
struct YangRedistribution {
    // Amount of debt in wad to be distributed to each wad unit of yang
    // This is packed into bits 0 to 127.
    unit_debt: Wad,
    // Amount of debt to be added to the next redistribution to calculate `debt_per_yang`
    // This is packed into bits 128 to 250.
    // Note that the error should never approach close to 2 ** 122, but it is capped to this
    // value anyway to prevent redistributions from failing in this unlikely scenario, at the
    // expense of some amount of redistributed debt not being attributed to troves. These
    // unattributed amounts will be backed by the initial yang amounts instead.
    error: Wad,
    // Whether the exception flow is triggered to redistribute the yang across all yangs
    // This is packed into bit 251
    exception: bool,
}

impl DisplayYangRedistribution of Display<YangRedistribution> {
    fn fmt(self: @YangRedistribution, ref f: Formatter) -> Result<(), Error> {
        Debug::fmt(self, ref f)
    }
}

// 2 ** 122 - 1
const MAX_YANG_REDISTRIBUTION_ERROR: u128 = 0x3ffffffffffffffffffffffffffffff;

impl YangRedistributionStorePacking of StorePacking<YangRedistribution, felt252> {
    fn pack(value: YangRedistribution) -> felt252 {
        let capped_error: u128 = min(value.error.val, MAX_YANG_REDISTRIBUTION_ERROR);
        (value.unit_debt.into() + (capped_error.into() * TWO_POW_128) + (value.exception.into() * TWO_POW_250))
    }

    fn unpack(value: felt252) -> YangRedistribution {
        let value: u256 = value.into();
        let shift: NonZero<u256> = u256_try_as_non_zero(TWO_POW_128.into()).unwrap();
        let (rest, unit_debt) = u256_safe_div_rem(value, shift);
        let shift: NonZero<u256> = u256_try_as_non_zero(TWO_POW_122.into()).unwrap();
        let (exception, error) = u256_safe_div_rem(rest, shift);

        YangRedistribution {
            unit_debt: unit_debt.try_into().unwrap(), error: error.try_into().unwrap(), exception: exception == 1
        }
    }
}

#[derive(Copy, Debug, Drop, Serde, starknet::Store)]
struct ExceptionalYangRedistribution {
    unit_debt: Wad, // Amount of debt to be distributed to each wad unit of recipient yang
    unit_yang: Wad, // Amount of redistributed yang to be distributed to each wad unit of recipient yang
}

impl DisplayExceptionalYangRedistribution of Display<ExceptionalYangRedistribution> {
    fn fmt(self: @ExceptionalYangRedistribution, ref f: Formatter) -> Result<(), Error> {
        Debug::fmt(self, ref f)
    }
}

//
// Absorber
//

// For absorptions, the `asset_amt_per_share` is tied to an absorption ID and is not changed once set.
// For blessings, the `asset_amt_per_share` is a cumulative value that is updated until the given epoch ends
#[derive(Copy, Debug, Drop, Serde)]
struct DistributionInfo {
    // Amount of asset in its decimal precision per share wad
    // This is packed into bits 0 to 127.
    asset_amt_per_share: u128,
    // Error to be added to next absorption
    // This is packed into bits 128 to 251.
    // Note that the error should never approach close to 2 ** 123, but it is capped to this value anyway
    // to prevent redistributions from failing in this unlikely scenario, at the expense of providers
    // losing out on some absorbed assets.
    error: u128,
}

impl DisplayDistributionInfo of Display<DistributionInfo> {
    fn fmt(self: @DistributionInfo, ref f: Formatter) -> Result<(), Error> {
        Debug::fmt(self, ref f)
    }
}

// 2 ** 123 - 1
const MAX_DISTRIBUTION_INFO_ERROR: u128 = 0x7ffffffffffffffffffffffffffffff;

impl DistributionInfoStorePacking of StorePacking<DistributionInfo, felt252> {
    fn pack(value: DistributionInfo) -> felt252 {
        let capped_error: u128 = min(value.error, MAX_DISTRIBUTION_INFO_ERROR);
        value.asset_amt_per_share.into() + (capped_error.into() * TWO_POW_128)
    }

    fn unpack(value: felt252) -> DistributionInfo {
        let value: u256 = value.into();
        let shift: NonZero<u256> = u256_try_as_non_zero(TWO_POW_128.into()).unwrap();
        let (error, asset_amt_per_share) = u256_safe_div_rem(value, shift);

        DistributionInfo {
            asset_amt_per_share: asset_amt_per_share.try_into().unwrap(), error: error.try_into().unwrap()
        }
    }
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct Reward {
    asset: ContractAddress, // ERC20 address of token
    blesser: IBlesserDispatcher, // Address of contract implementing `IBlesser` for distributing the token to the absorber
    is_active: bool, // Whether the blesser (vesting contract) should be called
}

#[derive(Copy, Debug, Drop, Serde)]
struct Provision {
    epoch: u32, // Epoch in which shares are issued
    shares: Wad, // Amount of shares for provider in the above epoch
}

impl DisplayProvision of Display<Provision> {
    fn fmt(self: @Provision, ref f: Formatter) -> Result<(), Error> {
        Debug::fmt(self, ref f)
    }
}

impl ProvisionStorePacking of StorePacking<Provision, felt252> {
    fn pack(value: Provision) -> felt252 {
        value.epoch.into() + (value.shares.into() * TWO_POW_32)
    }

    fn unpack(value: felt252) -> Provision {
        let value: u256 = value.into();
        let shift: NonZero<u256> = u256_try_as_non_zero(TWO_POW_32.into()).unwrap();
        let (shares, epoch) = u256_safe_div_rem(value, shift);

        Provision { epoch: epoch.try_into().unwrap(), shares: shares.try_into().unwrap() }
    }
}

#[derive(Copy, Debug, Drop, Serde)]
struct Request {
    timestamp: u64, // Timestamp of request
    timelock: u64, // Amount of time that needs to elapse after the timestamp before removal
    has_removed: bool, // Whether provider has called `remove`
}

impl DisplayRequest of Display<Request> {
    fn fmt(self: @Request, ref f: Formatter) -> Result<(), Error> {
        Debug::fmt(self, ref f)
    }
}

impl RequestStorePacking of StorePacking<Request, felt252> {
    fn pack(value: Request) -> felt252 {
        value.timestamp.into() + (value.timelock.into() * TWO_POW_64) + (value.has_removed.into() * TWO_POW_128)
    }

    fn unpack(value: felt252) -> Request {
        let value: u256 = value.into();
        let shift: NonZero<u256> = u256_try_as_non_zero(TWO_POW_64.into()).unwrap();
        let (rest, timestamp) = u256_safe_div_rem(value, shift);
        let (has_removed, timelock) = u256_safe_div_rem(rest, shift);

        Request {
            timestamp: timestamp.try_into().unwrap(),
            timelock: timelock.try_into().unwrap(),
            has_removed: has_removed == 1
        }
    }
}

//
// Pragma
//

mod pragma {
    #[derive(Copy, Drop, Serde)]
    enum DataType {
        SpotEntry: felt252,
        FutureEntry: (felt252, u64),
        GenericEntry: felt252,
    }

    #[derive(Copy, Drop, Serde)]
    struct PragmaPricesResponse {
        price: u128,
        decimals: u32,
        last_updated_timestamp: u64,
        num_sources_aggregated: u32,
        expiration_timestamp: Option<u64>,
    }

    #[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
    struct PriceValidityThresholds {
        // the maximum number of seconds between block timestamp and
        // the last update timestamp (as reported by Pragma) for which
        // we consider a price update valid
        freshness: u64,
        // the minimum number of data publishers used to aggregate the
        // price value
        sources: u32,
    }
}
