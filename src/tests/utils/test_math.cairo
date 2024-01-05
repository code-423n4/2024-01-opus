mod test_math {
    use debug::PrintTrait;
    use integer::BoundedU128;
    use opus::tests::common::assert_equalish;
    use opus::utils::math::{pow, sqrt};
    use wadray::{Ray, RAY_ONE};


    #[test]
    fn test_sqrt() {
        let ERROR_MARGIN = Ray { val: 1 };

        assert(sqrt(0_u128.into()).val == 0_u128.into(), 'wrong sqrt #1');

        // Ground truth tests

        // 1000
        assert_equalish(
            sqrt(1000000000000000000000000000000_u128.into()),
            31622776601683793319988935444_u128.into(),
            ERROR_MARGIN,
            'wrong sqrt #2'
        );

        // 6969
        assert_equalish(
            sqrt(6969000000000000000000000000000_u128.into()),
            83480536653761396384637711221_u128.into(),
            ERROR_MARGIN,
            'wrong sqrt #3'
        );

        // pi
        assert_equalish(
            sqrt(3141592653589793238462643383_u128.into()),
            1772453850905516027298167483_u128.into(),
            ERROR_MARGIN,
            'wrong sqrt #4'
        );

        // e
        assert_equalish(
            sqrt(2718281828459045235360287471_u128.into()),
            1648721270700128146848650787_u128.into(),
            ERROR_MARGIN,
            'wrong sqrt #5'
        );

        // Testing the property x = sqrt(x)^2

        let ERROR_MARGIN = Ray { val: 1000 };

        assert_equalish((4 * RAY_ONE).into(), pow(sqrt((4 * RAY_ONE).into()), 2), ERROR_MARGIN, 'wrong sqrt #6');

        assert_equalish((1000 * RAY_ONE).into(), pow(sqrt((1000 * RAY_ONE).into()), 2), ERROR_MARGIN, 'wrong sqrt #7');

        // tau
        assert_equalish(
            6283185307179586476925286766_u128.into(),
            pow(sqrt(6283185307179586476925286766_u128.into()), 2),
            ERROR_MARGIN,
            'wrong sqrt #8'
        );

        // testing the maximum possible value `sqrt` could accept doesn't cause it to fail
        sqrt(BoundedU128::max().into());
    }

    #[test]
    fn test_pow() {
        // u128 tests
        assert(pow(5_u128, 3) == 125_u128, 'wrong pow #1');
        assert(pow(5_u128, 0) == 1_u128, 'wrong pow #2');
        assert(pow(5_u128, 1) == 5_u128, 'wrong pow #3');
        assert(pow(5_u128, 2) == 25_u128, 'wrong pow #4');

        // Ray tests
        let ERROR_MARGIN = Ray { val: 1000 };

        assert_equalish(
            pow::<Ray>(3141592653589793238462643383_u128.into(), 2),
            9869604401089358618834490999_u128.into(),
            ERROR_MARGIN,
            'wrong pow #5'
        );

        assert_equalish(
            pow::<Ray>(1414213562373095048801688724_u128.into(), 4), (4 * RAY_ONE).into(), ERROR_MARGIN, 'wrong pow #6'
        );
    }
}
