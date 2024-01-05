mod test_controller {
    use debug::PrintTrait;
    use opus::core::controller::controller as controller_contract;
    use opus::interfaces::IController::{IControllerDispatcher, IControllerDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common::{assert_equalish, badguy};
    use opus::tests::common;
    use opus::tests::controller::utils::controller_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{start_prank, CheatTarget, spy_events, SpyOn, EventSpy, EventAssertions};
    use wadray::{Ray, SignedRay, SignedRayZeroable, Wad};

    const YIN_PRICE1: u128 = 999942800000000000; // wad
    const YIN_PRICE2: u128 = 999879000000000000; // wad

    const ERROR_MARGIN: u128 = 1000000000000000; // 10^-12 (ray)

    #[test]
    fn test_deploy_controller() {
        let mut spy = spy_events(SpyOn::All);
        let (controller, _) = controller_utils::deploy_controller();

        let ((p_gain, i_gain), (alpha_p, beta_p, alpha_i, beta_i)) = controller.get_parameters();
        assert(p_gain == controller_utils::P_GAIN.into(), 'wrong p gain');
        assert(i_gain == controller_utils::I_GAIN.into(), 'wrong i gain');
        assert(alpha_p == controller_utils::ALPHA_P, 'wrong alpha_p');
        assert(alpha_i == controller_utils::ALPHA_I, 'wrong alpha_i');
        assert(beta_p == controller_utils::BETA_P, 'wrong beta_p');
        assert(beta_i == controller_utils::BETA_I, 'wrong beta_i');
        let expected_events = array![
            (
                controller.contract_address,
                controller_contract::Event::GainUpdated(
                    controller_contract::GainUpdated { name: 'p_gain', value: controller_utils::P_GAIN.into() }
                )
            ),
            (
                controller.contract_address,
                controller_contract::Event::GainUpdated(
                    controller_contract::GainUpdated { name: 'i_gain', value: controller_utils::I_GAIN.into() }
                )
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'alpha_p', value: controller_utils::ALPHA_P }
                )
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'alpha_i', value: controller_utils::ALPHA_I }
                )
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'beta_p', value: controller_utils::BETA_P }
                )
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'beta_i', value: controller_utils::BETA_I }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_setters() {
        let (controller, _) = controller_utils::deploy_controller();
        let mut spy = spy_events(SpyOn::One(controller.contract_address));

        start_prank(CheatTarget::One(controller.contract_address), controller_utils::admin());

        let new_p_gain: Ray = 1_u128.into();
        let new_i_gain: Ray = 2_u128.into();
        let new_alpha_p: u8 = 3;
        let new_alpha_i: u8 = 5;
        let new_beta_p: u8 = 8;
        let new_beta_i: u8 = 4;

        controller.set_p_gain(new_p_gain);
        controller.set_i_gain(new_i_gain);
        controller.set_alpha_p(new_alpha_p);
        controller.set_alpha_i(new_alpha_i);
        controller.set_beta_p(new_beta_p);
        controller.set_beta_i(new_beta_i);

        let ((p_gain, i_gain), (alpha_p, beta_p, alpha_i, beta_i)) = controller.get_parameters();
        assert(p_gain == new_p_gain.into(), 'wrong p gain');
        assert(i_gain == new_i_gain.into(), 'wrong i gain');
        assert(alpha_p == new_alpha_p, 'wrong alpha_p');
        assert(alpha_i == new_alpha_i, 'wrong alpha_i');
        assert(beta_p == new_beta_p, 'wrong beta_p');
        assert(beta_i == new_beta_i, 'wrong beta_i');
        let expected_events = array![
            (
                controller.contract_address,
                controller_contract::Event::GainUpdated(
                    controller_contract::GainUpdated { name: 'p_gain', value: new_p_gain.into() }
                )
            ),
            (
                controller.contract_address,
                controller_contract::Event::GainUpdated(
                    controller_contract::GainUpdated { name: 'i_gain', value: new_i_gain.into() }
                )
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'alpha_p', value: new_alpha_p }
                )
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'alpha_i', value: new_alpha_i }
                )
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'beta_p', value: new_beta_p }
                )
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'beta_i', value: new_beta_i }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    // Testing unauthorized calls of setters

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_p_gain_unauthorized() {
        let (controller, _) = controller_utils::deploy_controller();
        start_prank(CheatTarget::All, badguy());
        controller.set_p_gain(1_u128.into());
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_i_gain_unauthorized() {
        let (controller, _) = controller_utils::deploy_controller();
        start_prank(CheatTarget::All, badguy());
        controller.set_i_gain(1_u128.into());
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_alpha_p_unauthorized() {
        let (controller, _) = controller_utils::deploy_controller();
        start_prank(CheatTarget::All, badguy());
        controller.set_alpha_p(1);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_alpha_i_unauthorized() {
        let (controller, _) = controller_utils::deploy_controller();
        start_prank(CheatTarget::All, badguy());
        controller.set_alpha_i(1);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_beta_p_unauthorized() {
        let (controller, _) = controller_utils::deploy_controller();
        start_prank(CheatTarget::All, badguy());
        controller.set_beta_p(1);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_beta_i_unauthorized() {
        let (controller, _) = controller_utils::deploy_controller();
        start_prank(CheatTarget::All, badguy());
        controller.set_beta_i(1);
    }

    #[test]
    fn test_against_ground_truth() {
        let (controller, shrine) = controller_utils::deploy_controller();

        start_prank(CheatTarget::One(controller.contract_address), controller_utils::admin());

        // Updating `i_gain` to match the ground truth simulation
        controller.set_i_gain(100000000000000000000000_u128.into());

        assert(controller.get_p_term() == SignedRayZeroable::zero(), 'Wrong p term #1');
        assert(controller.get_i_term() == SignedRayZeroable::zero(), 'Wrong i term #1');

        controller_utils::fast_forward_1_hour();
        controller_utils::set_yin_spot_price(shrine, YIN_PRICE1.into());
        controller.update_multiplier();

        assert_equalish(controller.get_p_term(), 18715000000000000_u128.into(), ERROR_MARGIN.into(), 'Wrong p term #2');

        assert_equalish(controller.get_i_term(), SignedRayZeroable::zero(), ERROR_MARGIN.into(), 'Wrong i term #2');

        controller_utils::fast_forward_1_hour();
        controller_utils::set_yin_spot_price(shrine, YIN_PRICE2.into());
        controller.update_multiplier();

        assert_equalish(
            controller.get_p_term(), 177156100000000000_u128.into(), ERROR_MARGIN.into(), 'Wrong p term #3'
        );
        assert_equalish(
            controller.get_i_term(), 5720000000000000000_u128.into(), ERROR_MARGIN.into(), 'Wrong i term #3'
        );
    }

    #[test]
    fn test_against_ground_truth2() {
        let (controller, shrine) = controller_utils::deploy_controller();

        start_prank(CheatTarget::One(controller.contract_address), controller_utils::admin());

        // Updating `i_gain` to match the ground truth simulation
        controller.set_i_gain(100000000000000000000000000_u128.into()); // 0.1 (ray)
        controller.set_p_gain((1000000_u128 * wadray::RAY_ONE).into()); // 1,000,000 (ray)

        // Loading our ground truth into arrays for comparison
        let mut prices: Array<Wad> = array![
            990099009900990000_u128.into(),
            990366354678218000_u128.into(),
            990633735544555000_u128.into(),
            991196767996938000_u128.into(),
            991739556883818000_u128.into(),
            992242243614704000_u128.into(),
            992706195040200000_u128.into(),
            993142884628952000_u128.into(),
            993559692099288000_u128.into(),
            993955814200459000_u128.into(),
            994335056474406000_u128.into(),
            994700440013533000_u128.into(),
            995054185977344000_u128.into(),
            995399740716883000_u128.into(),
            995734834696816000_u128.into(),
            996062810539847000_u128.into(),
            996387925979872000_u128.into(),
            996705233546627000_u128.into(),
            997020242930630000_u128.into(),
            997330674543210000_u128.into(),
            997643112355959000_u128.into(),
            997949115908752000_u128.into(),
            998251035541544000_u128.into(),
            998558656038350000_u128.into(),
            998864120192415000_u128.into(),
            999166007648390000_u128.into(),
            999469499623981000_u128.into(),
            999772517479079000_u128.into(),
            1000076906317690000_u128.into(),
            999783572518900000_u128.into(),
            1000082233643610000_u128.into(),
            999782291432283000_u128.into(),
            1000084418040440000_u128.into(),
            999774651681536000_u128.into(),
            1000076306582700000_u128.into(),
            999765562823952000_u128.into(),
            1000067478586280000_u128.into(),
            999773019374451000_u128.into(),
            1000075753295850000_u128.into(),
            999771699502100000_u128.into(),
            1000074531257950000_u128.into(),
            999772965087390000_u128.into(),
            1000072685712120000_u128.into(),
            999769822334539000_u128.into(),
            1000073416183750000_u128.into(),
            999773295592982000_u128.into(),
            1000074746794400000_u128.into(),
            999770911209658000_u128.into(),
            1000070231385980000_u128.into(),
            999765417689028000_u128.into(),
            1000069974303700000_u128.into()
        ];

        let mut gt_p_terms: Array<SignedRay> = array![
            SignedRay { val: 970590147927647000000000000, sign: false },
            SignedRay { val: 894070898474206000000000000, sign: false },
            SignedRay { val: 821673437507969000000000000, sign: false },
            SignedRay { val: 682223134755347000000000000, sign: false },
            SignedRay { val: 563650679126526000000000000, sign: false },
            SignedRay { val: 466883377897327000000000000, sign: false },
            SignedRay { val: 388027439175095000000000000, sign: false },
            SignedRay { val: 322421778769981000000000000, sign: false },
            SignedRay { val: 267128295084547000000000000, sign: false },
            SignedRay { val: 220807295545965000000000000, sign: false },
            SignedRay { val: 181797017511202000000000000, sign: false },
            SignedRay { val: 148839923137893000000000000, sign: false },
            SignedRay { val: 120979934404742000000000000, sign: false },
            SignedRay { val: 97352460220021900000000000, sign: false },
            SignedRay { val: 77590330680972000000000000, sign: false },
            SignedRay { val: 61032188256437500000000000, sign: false },
            SignedRay { val: 47127014107944500000000000, sign: false },
            SignedRay { val: 35766291049440400000000000, sign: false },
            SignedRay { val: 26457120564074500000000000, sign: false },
            SignedRay { val: 19019740391049200000000000, sign: false },
            SignedRay { val: 13092320818861100000000000, sign: false },
            SignedRay { val: 8626275988050790000000000, sign: false },
            SignedRay { val: 5349866590771690000000000, sign: false },
            SignedRay { val: 2994352321987200000000000, sign: false },
            SignedRay { val: 1465538181737340000000000, sign: false },
            SignedRay { val: 580077744495169000000000, sign: false },
            SignedRay { val: 149299065094387000000000, sign: false },
            SignedRay { val: 11771833128707600000000, sign: false },
            SignedRay { val: 454868699248396000000, sign: true },
            SignedRay { val: 10137648168357900000000, sign: false },
            SignedRay { val: 556094500531630000000, sign: true },
            SignedRay { val: 10318737437779200000000, sign: false },
            SignedRay { val: 601597192010593000000, sign: true },
            SignedRay { val: 11443607803844600000000, sign: false },
            SignedRay { val: 444309924306484000000, sign: true },
            SignedRay { val: 12884852286933400000000, sign: false },
            SignedRay { val: 307254269093854000000, sign: true },
            SignedRay { val: 11694088217335100000000, sign: false },
            SignedRay { val: 434714972188474000000, sign: true },
            SignedRay { val: 11899277040162700000000, sign: false },
            SignedRay { val: 414014311714013000000, sign: true },
            SignedRay { val: 11702480865715000000000, sign: false },
            SignedRay { val: 384014080725509000000, sign: true },
            SignedRay { val: 12195217294212000000000, sign: false },
            SignedRay { val: 395708534480748000000, sign: true },
            SignedRay { val: 11651447644416500000000, sign: false },
            SignedRay { val: 417616564726968000000, sign: true },
            SignedRay { val: 12022963179828800000000, sign: false },
            SignedRay { val: 346412629605555000000, sign: true },
            SignedRay { val: 12908797294705800000000, sign: false },
            SignedRay { val: 342622403010459000000, sign: true }
        ];

        let mut gt_i_terms: Array<SignedRay> = array![
            SignedRay { val: 0, sign: false },
            SignedRay { val: 990050483961299000000000, sign: false },
            SignedRay { val: 1953370315705950000000000, sign: false },
            SignedRay { val: 2889955680281540000000000, sign: false },
            SignedRay { val: 3770244771413480000000000, sign: false },
            SignedRay { val: 4596260901939910000000000, sign: false },
            SignedRay { val: 5372013197354250000000000, sign: false },
            SignedRay { val: 6101374292736350000000000, sign: false },
            SignedRay { val: 6787069709320670000000000, sign: false },
            SignedRay { val: 7431087143392610000000000, sign: false },
            SignedRay { val: 8035494683284410000000000, sign: false },
            SignedRay { val: 8601979946211740000000000, sign: false },
            SignedRay { val: 9131928503019010000000000, sign: false },
            SignedRay { val: 9626503856398830000000000, sign: false },
            SignedRay { val: 10086524917164800000000000, sign: false },
            SignedRay { val: 10513037568019600000000000, sign: false },
            SignedRay { val: 10906753462460900000000000, sign: false },
            SignedRay { val: 11267958508146100000000000, sign: false },
            SignedRay { val: 11597433365183300000000000, sign: false },
            SignedRay { val: 11895407749273100000000000, sign: false },
            SignedRay { val: 12162339343970200000000000, sign: false },
            SignedRay { val: 12398027453761000000000000, sign: false },
            SignedRay { val: 12603115431573400000000000, sign: false },
            SignedRay { val: 12778011609926200000000000, sign: false },
            SignedRay { val: 12922145856373900000000000, sign: false },
            SignedRay { val: 13035733763855500000000000, sign: false },
            SignedRay { val: 13119132970012600000000000, sign: false },
            SignedRay { val: 13172183000149500000000000, sign: false },
            SignedRay { val: 13194931251653000000000000, sign: false },
            SignedRay { val: 13187240619906900000000000, sign: false },
            SignedRay { val: 13208883367510000000000000, sign: false },
            SignedRay { val: 13200660003177300000000000, sign: false },
            SignedRay { val: 13222430859433100000000000, sign: false },
            SignedRay { val: 13213989055419400000000000, sign: false },
            SignedRay { val: 13236523886693600000000000, sign: false },
            SignedRay { val: 13228893228445400000000000, sign: false },
            SignedRay { val: 13252336945406000000000000, sign: false },
            SignedRay { val: 13245589086793100000000000, sign: false },
            SignedRay { val: 13268287148763300000000000, sign: false },
            SignedRay { val: 13260711819200200000000000, sign: false },
            SignedRay { val: 13283541868395200000000000, sign: false },
            SignedRay { val: 13276088742621000000000000, sign: false },
            SignedRay { val: 13298792233296800000000000, sign: false },
            SignedRay { val: 13291523662104200000000000, sign: false },
            SignedRay { val: 13314541428040600000000000, sign: false },
            SignedRay { val: 13307199809685200000000000, sign: false },
            SignedRay { val: 13329870249804400000000000, sign: false },
            SignedRay { val: 13322395570385200000000000, sign: false },
            SignedRay { val: 13345304448818300000000000, sign: false },
            SignedRay { val: 13338281310237400000000000, sign: false },
            SignedRay { val: 13361739540689300000000000, sign: false }
        ];

        let mut gt_multipliers: Array<Ray> = array![
            1970590147927650000000000000_u128.into(),
            1895060948958170000000000000_u128.into(),
            1823626807823680000000000000_u128.into(),
            1685113090435630000000000000_u128.into(),
            1567420923897940000000000000_u128.into(),
            1471479638799270000000000000_u128.into(),
            1393399452372450000000000000_u128.into(),
            1328523153062720000000000000_u128.into(),
            1273915364793870000000000000_u128.into(),
            1228238382689360000000000000_u128.into(),
            1189832512194490000000000000_u128.into(),
            1157441903084100000000000000_u128.into(),
            1130111862907760000000000000_u128.into(),
            1106978964076420000000000000_u128.into(),
            1087676855598140000000000000_u128.into(),
            1071545225824460000000000000_u128.into(),
            1058033767570410000000000000_u128.into(),
            1047034249557590000000000000_u128.into(),
            1038054553929260000000000000_u128.into(),
            1030915148140320000000000000_u128.into(),
            1025254660162830000000000000_u128.into(),
            1021024303441810000000000000_u128.into(),
            1017952982022350000000000000_u128.into(),
            1015772363931910000000000000_u128.into(),
            1014387684038110000000000000_u128.into(),
            1013615811508350000000000000_u128.into(),
            1013268432035110000000000000_u128.into(),
            1013183954833280000000000000_u128.into(),
            1013194476382950000000000000_u128.into(),
            1013197378268080000000000000_u128.into(),
            1013208327273010000000000000_u128.into(),
            1013210978740620000000000000_u128.into(),
            1013221829262240000000000000_u128.into(),
            1013225432663220000000000000_u128.into(),
            1013236079576770000000000000_u128.into(),
            1013241778080730000000000000_u128.into(),
            1013252029691140000000000000_u128.into(),
            1013257283175010000000000000_u128.into(),
            1013267852433790000000000000_u128.into(),
            1013272611096240000000000000_u128.into(),
            1013283127854080000000000000_u128.into(),
            1013287791223490000000000000_u128.into(),
            1013298408219220000000000000_u128.into(),
            1013303718879400000000000000_u128.into(),
            1013314145719510000000000000_u128.into(),
            1013318851257330000000000000_u128.into(),
            1013329452633240000000000000_u128.into(),
            1013334418533570000000000000_u128.into(),
            1013344958036190000000000000_u128.into(),
            1013351190107530000000000000_u128.into(),
            1013361396918290000000000000_u128.into()
        ];

        loop {
            match prices.pop_front() {
                Option::Some(price) => {
                    controller_utils::set_yin_spot_price(shrine, price);
                    controller.update_multiplier();

                    assert_equalish(
                        controller.get_p_term(), gt_p_terms.pop_front().unwrap(), ERROR_MARGIN.into(), 'Wrong p term'
                    );

                    assert_equalish(
                        controller.get_i_term(), gt_i_terms.pop_front().unwrap(), ERROR_MARGIN.into(), 'Wrong i term'
                    );

                    assert_equalish(
                        controller.get_current_multiplier(),
                        gt_multipliers.pop_front().unwrap(),
                        ERROR_MARGIN.into(),
                        'Wrong multiplier'
                    );

                    controller_utils::fast_forward_1_hour();
                },
                Option::None => { break; }
            };
        };
    }

    // In previous simulations, the time between updates was consistently 1 hour.
    // This test is to ensure that the controller is still working as expected
    // when the time between updates is variable.
    #[test]
    fn test_against_ground_truth3() {
        let (controller, shrine) = controller_utils::deploy_controller();

        start_prank(CheatTarget::All, controller_utils::admin());

        // Updating `i_gain` to match the ground truth simulation
        controller.set_i_gain(100000000000000000000000000_u128.into()); // 0.1 (ray)
        controller.set_p_gain((1000000_u128 * wadray::RAY_ONE).into()); // 1,000,000 (ray)

        // Loading our ground truth into arrays for comparison
        let mut prices: Array<Wad> = array![
            999000000000000000_u128.into(),
            998000000000000000_u128.into(),
            997000000000000000_u128.into(),
            996000000000000000_u128.into(),
            995000000000000000_u128.into()
        ];
        let mut gt_p_terms: Array<SignedRay> = array![
            SignedRay { val: 1000000000000000000000000, sign: false },
            SignedRay { val: 1000000000000000000000000, sign: false },
            SignedRay { val: 1000000000000000000000000, sign: false },
            SignedRay { val: 8000000000000000000000000, sign: false },
            SignedRay { val: 8000000000000000000000000, sign: false },
            SignedRay { val: 27000000000000000000000000, sign: false },
            SignedRay { val: 64000000000000000000000000, sign: false },
            SignedRay { val: 64000000000000000000000000, sign: false },
            SignedRay { val: 125000000000000000000000000, sign: false },
            SignedRay { val: 125000000000000000000000000, sign: false }
        ];
        let mut gt_i_terms: Array<SignedRay> = array![
            SignedRay { val: 0, sign: false },
            SignedRay { val: 99999950000037500000000, sign: false },
            SignedRay { val: 199999900000075000000000, sign: false },
            SignedRay { val: 299999850000113000000000, sign: false },
            SignedRay { val: 499999450001313000000000, sign: false },
            SignedRay { val: 699999050002513000000000, sign: false },
            SignedRay { val: 999997700011625000000000, sign: false },
            SignedRay { val: 1399994500050020000000000, sign: false },
            SignedRay { val: 1799991300088420000000000, sign: false },
            SignedRay { val: 2299985050205610000000000, sign: false }
        ];
        let mut gt_multipliers: Array<Ray> = array![
            1001000000000000000000000000_u128.into(),
            1001099999950000000000000000_u128.into(),
            1001199999900000000000000000_u128.into(),
            1008299999850000000000000000_u128.into(),
            1008499999450000000000000000_u128.into(),
            1027699999050000000000000000_u128.into(),
            1064999997700010000000000000_u128.into(),
            1065399994500050000000000000_u128.into(),
            1126799991300090000000000000_u128.into(),
            1127299985050210000000000000_u128.into()
        ];
        let mut gt_update_intervals: Array<u64> = array![1, 4, 6, 7, 9];

        let mut current_interval: u64 = 1;
        let end_interval: u64 = 10;

        loop {
            if current_interval > end_interval {
                break;
            }

            if gt_update_intervals.len() > 0 {
                if current_interval == *gt_update_intervals.at(0) {
                    let _ = gt_update_intervals.pop_front();
                    let price: Wad = prices.pop_front().unwrap();
                    controller_utils::set_yin_spot_price(shrine, price);
                    controller.update_multiplier();
                }
            }

            assert_equalish(
                controller.get_p_term(), gt_p_terms.pop_front().unwrap(), ERROR_MARGIN.into(), 'Wrong p term'
            );

            assert_equalish(
                controller.get_i_term(), gt_i_terms.pop_front().unwrap(), ERROR_MARGIN.into(), 'Wrong i term'
            );

            assert_equalish(
                controller.get_current_multiplier(),
                gt_multipliers.pop_front().unwrap(),
                ERROR_MARGIN.into(),
                'Wrong multiplier'
            );

            controller_utils::fast_forward_1_hour();
            current_interval += 1;
        }
    }

    #[test]
    fn test_against_ground_truth4() {
        let (controller, shrine) = controller_utils::deploy_controller();

        start_prank(CheatTarget::One(controller.contract_address), controller_utils::admin());

        // Updating `i_gain` to match the ground truth simulation
        controller.set_i_gain(100000000000000000000000000_u128.into()); // 0.1 (ray)
        controller.set_p_gain((1000000_u128 * wadray::RAY_ONE).into()); // 1,000,000 (ray)

        // Loading our ground truth into arrays for comparison
        let mut prices: Array<Wad> = array![
            1010000000000000000_u128.into(),
            1009070214084160000_u128.into(),
            1008140856336630000_u128.into(),
            1007913464870420000_u128.into(),
            1007501969998440000_u128.into(),
            1007052728821550000_u128.into(),
            1006534504840420000_u128.into(),
            1005954136457240000_u128.into(),
            1005313382507510000_u128.into(),
            1004610965226620000_u128.into(),
            1003853817920420000_u128.into(),
            1003050483282290000_u128.into(),
            1002211038229070000_u128.into(),
            1001347832590710000_u128.into(),
            1000467142052610000_u128.into(),
            999579268159293000_u128.into(),
            999876291246443000_u128.into(),
            1000170338496500000_u128.into(),
            999281991878406000_u128.into(),
            999576275080028000_u128.into(),
            999875348924666000_u128.into()
        ];

        let mut gt_p_terms: Array<SignedRay> = array![
            SignedRay { val: 1000000000000000000000000000, sign: true },
            SignedRay { val: 746195479082780000000000000, sign: true },
            SignedRay { val: 539523383476549000000000000, sign: true },
            SignedRay { val: 495564327004449000000000000, sign: true },
            SignedRay { val: 422207524565069000000000000, sign: true },
            SignedRay { val: 350809670272340000000000000, sign: true },
            SignedRay { val: 279021745992780000000000000, sign: true },
            SignedRay { val: 211084503271797000000000000, sign: true },
            SignedRay { val: 150007593859640000000000000, sign: true },
            SignedRay { val: 98033733163599700000000000, sign: true },
            SignedRay { val: 57236566790630100000000000, sign: true },
            SignedRay { val: 28386114337654400000000000, sign: true },
            SignedRay { val: 10809080591591700000000000, sign: true },
            SignedRay { val: 2448543705069680000000000, sign: true },
            SignedRay { val: 101940531609356000000000, sign: true },
            SignedRay { val: 74475965338374500000000, sign: false },
            SignedRay { val: 1893220914100550000000, sign: false },
            SignedRay { val: 4942406121262390000000, sign: true },
            SignedRay { val: 370158792771361000000000, sign: false },
            SignedRay { val: 76076761869019800000000, sign: false },
            SignedRay { val: 1936814769447970000000, sign: false }
        ];

        let mut gt_i_terms: Array<SignedRay> = array![
            SignedRay { val: 0, sign: false },
            SignedRay { val: 999950003749688000000000, sign: true },
            SignedRay { val: 1906934104693500000000000, sign: true },
            SignedRay { val: 2720992763528470000000000, sign: true },
            SignedRay { val: 3512314473517650000000000, sign: true },
            SignedRay { val: 4262490363876780000000000, sign: true },
            SignedRay { val: 4967745706202580000000000, sign: true },
            SignedRay { val: 5621182239604350000000000, sign: true },
            SignedRay { val: 6216585331384020000000000, sign: true },
            SignedRay { val: 6747916081914270000000000, sign: true },
            SignedRay { val: 7209007702967550000000000, sign: true },
            SignedRay { val: 7594386633212950000000000, sign: true },
            SignedRay { val: 7899433542145930000000000, sign: true },
            SignedRay { val: 8120536824601320000000000, sign: true },
            SignedRay { val: 8255319961245460000000000, sign: true },
            SignedRay { val: 8302034161409560000000000, sign: true },
            SignedRay { val: 8259960981062700000000000, sign: true },
            SignedRay { val: 8247590105801630000000000, sign: true },
            SignedRay { val: 8264623955204720000000000, sign: true },
            SignedRay { val: 8192823161553290000000000, sign: true },
            SignedRay { val: 8150450673359900000000000, sign: true }
        ];

        let mut gt_multipliers: Array<Ray> = array![
            200000000000000000000000000_u128.into(),
            252804570913471000000000000_u128.into(),
            458569682418758000000000000_u128.into(),
            501714680232022000000000000_u128.into(),
            574280160961414000000000000_u128.into(),
            644927839363783000000000000_u128.into(),
            716010508301017000000000000_u128.into(),
            783294314488599000000000000_u128.into(),
            843775820808976000000000000_u128.into(),
            895218350754486000000000000_u128.into(),
            935554425506402000000000000_u128.into(),
            964019499029133000000000000_u128.into(),
            981291485866262000000000000_u128.into(),
            989430919470329000000000000_u128.into(),
            991642739507145000000000000_u128.into(),
            991772441803929000000000000_u128.into(),
            991741932239851000000000000_u128.into(),
            991747467488077000000000000_u128.into(),
            992105534837567000000000000_u128.into(),
            991883253600316000000000000_u128.into(),
            991851486141410000000000000_u128.into()
        ];

        loop {
            match prices.pop_front() {
                Option::Some(price) => {
                    controller_utils::set_yin_spot_price(shrine, price);
                    controller.update_multiplier();

                    assert_equalish(
                        controller.get_p_term(), gt_p_terms.pop_front().unwrap(), ERROR_MARGIN.into(), 'Wrong p term'
                    );
                    assert_equalish(
                        controller.get_i_term(), gt_i_terms.pop_front().unwrap(), ERROR_MARGIN.into(), 'Wrong i term'
                    );
                    assert_equalish(
                        controller.get_current_multiplier(),
                        gt_multipliers.pop_front().unwrap(),
                        ERROR_MARGIN.into(),
                        'Wrong multiplier'
                    );

                    controller_utils::fast_forward_1_hour();
                },
                Option::None => { break; }
            };
        };
    }

    #[test]
    fn test_frequent_updates() {
        let (controller, shrine) = controller_utils::deploy_controller();
        start_prank(CheatTarget::One(controller.contract_address), controller_utils::admin());
        controller.set_i_gain(100000000000000000000000_u128.into()); // Ensuring the integral gain is non-zero

        controller_utils::set_yin_spot_price(shrine, YIN_PRICE1.into());
        controller.update_multiplier();

        // Standard flow, updating the multiplier every hour
        let prev_multiplier: Ray = controller.get_current_multiplier();
        controller_utils::fast_forward_1_hour();
        controller.update_multiplier();
        let current_multiplier: Ray = controller.get_current_multiplier();
        assert(current_multiplier > prev_multiplier, 'Multiplier should increase');

        // Suddenly the multiplier is updated multiple times within the same block.
        // The multiplier should not change.
        controller.update_multiplier();
        controller.update_multiplier();
        controller.update_multiplier();

        assert(current_multiplier == controller.get_current_multiplier(), 'Multiplier should not change');
    }
}
