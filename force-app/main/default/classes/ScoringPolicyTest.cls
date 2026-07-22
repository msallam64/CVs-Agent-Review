/**
 * Covers the policy loader's real path: reading Custom Metadata and falling back
 * to the documented defaults when the config is absent, plus the discount map.
 */
@IsTest
private class ScoringPolicyTest {

    @IsTest
    static void falls_back_to_defaults_when_config_absent() {
        // No injection -> the metadata-read path runs; with no records it falls back.
        ScoringPolicy.injectedCriteria = null;
        ScoringPolicy.injectedConfig = null;

        Test.startTest();
        List<ScoringPolicy.Criterion> criteria = ScoringPolicy.criteria();
        ScoringPolicy.Config cfg = ScoringPolicy.config();
        Test.stopTest();

        System.assert(!criteria.isEmpty(), 'A rubric is always available');
        Decimal total = 0;
        for (ScoringPolicy.Criterion c : criteria) {
            total += c.weight;
        }
        System.assertEquals(100, total, 'Weights sum to 100');
        System.assertEquals(60, cfg.strongMatchThreshold, 'Default threshold');
    }

    @IsTest
    static void maps_metadata_records_and_defaults_nulls() {
        // In-memory __mdt instances exercise the mapping the deployed records would.
        ScoringPolicy.Criterion cr = ScoringPolicy.buildCriterion(
            new Rubric_Criterion__mdt(Weight__c = 40, Active__c = true, Guidance__c = 'g')
        );
        System.assertEquals(40, cr.weight, 'Weight mapped from the record');

        ScoringPolicy.Config full = ScoringPolicy.buildConfig(new Scoring_Config__mdt(
            Discount_Stated__c = 1.0, Discount_Inferred__c = 0.6, Discount_Conflicting__c = 0.4,
            Discount_Missing__c = 0.0, Strong_Match_Threshold__c = 55
        ));
        System.assertEquals(55, full.strongMatchThreshold, 'Threshold mapped from the record');

        // All-null record exercises the nvl fallbacks.
        ScoringPolicy.Config blank = ScoringPolicy.buildConfig(new Scoring_Config__mdt());
        System.assertEquals(1.0, blank.discountStated, 'Null field falls back to the default');
        System.assertEquals(60, blank.strongMatchThreshold);
    }

    @IsTest
    static void discount_maps_every_certainty() {
        ScoringPolicy.Config cfg = new ScoringPolicy.Config();
        System.assertEquals(1.0, cfg.discountFor('Stated'));
        System.assertEquals(0.6, cfg.discountFor('Inferred'));
        System.assertEquals(0.4, cfg.discountFor('Conflicting'));
        System.assertEquals(0.0, cfg.discountFor('Missing'));
        System.assertEquals(0.0, cfg.discountFor('unrecognised'), 'Unknown certainty gets no credit');
    }
}
