use opus::types::{
    DistributionInfo, ExceptionalYangRedistribution, Health, Provision, Request, Trove, YangBalance, YangRedistribution
};
use wadray::{Wad, Ray};

#[test]
fn test_display_and_debug() {
    let h = Health { threshold: 1_u128.into(), ltv: 2_u128.into(), value: 3_u128.into(), debt: 4_u128.into() };
    let expected = "Health { threshold: 1, ltv: 2, value: 3, debt: 4 }";
    assert_eq!(format!("{}", h), expected, "Health display");
    assert_eq!(format!("{:?}", h), expected, "Health debug");

    let y = YangBalance { yang_id: 123, amount: 456_u128.into() };
    let expected = "YangBalance { yang_id: 123, amount: 456 }";
    assert_eq!(format!("{}", y), expected, "YangBalance display");
    assert_eq!(format!("{:?}", y), expected, "YangBalance debug");

    let t = Trove { charge_from: 123, last_rate_era: 456, debt: 789_u128.into() };
    let expected = "Trove { charge_from: 123, last_rate_era: 456, debt: 789 }";
    assert_eq!(format!("{}", t), expected, "Trove display");
    assert_eq!(format!("{:?}", t), expected, "Trove debug");

    let y = YangRedistribution { unit_debt: 123_u128.into(), error: 456_u128.into(), exception: true };
    let expected = "YangRedistribution { unit_debt: 123, error: 456, exception: true }";
    assert_eq!(format!("{}", y), expected, "YangRedistribution display");
    assert_eq!(format!("{:?}", y), expected, "YangRedistribution debug");

    let e = ExceptionalYangRedistribution { unit_debt: 123_u128.into(), unit_yang: 456_u128.into() };
    let expected = "ExceptionalYangRedistribution { unit_debt: 123, unit_yang: 456 }";
    assert_eq!(format!("{}", e), expected, "ExceptionalYangRedistribution display");
    assert_eq!(format!("{:?}", e), expected, "ExceptionalYangRedistribution debug");

    let d = DistributionInfo { asset_amt_per_share: 123, error: 456 };
    let expected = "DistributionInfo { asset_amt_per_share: 123, error: 456 }";
    assert_eq!(format!("{}", d), expected, "DistributionInfo display");
    assert_eq!(format!("{:?}", d), expected, "DistributionInfo debug");

    let p = Provision { epoch: 123, shares: 456_u128.into() };
    let expected = "Provision { epoch: 123, shares: 456 }";
    assert_eq!(format!("{}", p), expected, "Provision display");
    assert_eq!(format!("{:?}", p), expected, "Provision debug");

    let r = Request { timestamp: 123, timelock: 456, has_removed: true };
    let expected = "Request { timestamp: 123, timelock: 456, has_removed: true }";
    assert_eq!(format!("{}", r), expected, "Provision display");
    assert_eq!(format!("{:?}", r), expected, "Provision debug");
}
