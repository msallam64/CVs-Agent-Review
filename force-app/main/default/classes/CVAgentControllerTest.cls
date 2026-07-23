/**
 * Covers the LWC controller: the card query groups facts by certainty in order,
 * the picker lists candidates, and the compare/ingest wrappers delegate to the
 * invocable actions (LLM mocked, so no callout).
 */
@IsTest
private class CVAgentControllerTest {

    private static Candidate__c makeCandidate(String name) {
        Candidate__c c = new Candidate__c(Name = name, Status__c = 'Parsed', Confidence__c = 'High');
        insert c;
        return c;
    }

    private static void makeFact(Id candId, String certainty, String evidence) {
        insert new Fact__c(
            Candidate__c = candId, Type__c = 'Skill', Name = 'Item',
            Certainty__c = certainty, Evidence__c = evidence
        );
    }

    @IsTest
    static void card_groups_facts_by_certainty_in_order() {
        Candidate__c c = makeCandidate('Alice');
        makeFact(c.Id, 'Missing', '');
        makeFact(c.Id, 'Stated', 'Apex');
        makeFact(c.Id, 'Inferred', 'led a team');

        Test.startTest();
        CVAgentController.CardView view = CVAgentController.getCandidateCard(c.Id);
        Test.stopTest();

        System.assertEquals('Alice', view.candidate.Name);
        System.assertEquals(3, view.groups.size(), 'Three non-empty certainty groups');
        System.assertEquals('Stated', view.groups[0].certainty, 'Strongest first');
        System.assertEquals('Inferred', view.groups[1].certainty);
        System.assertEquals('Missing', view.groups[2].certainty, 'Absence last');
    }

    @IsTest
    static void picker_lists_candidates() {
        makeCandidate('Alice');
        makeCandidate('Bob');

        Test.startTest();
        List<Candidate__c> list1 = CVAgentController.listCandidates();
        Test.stopTest();

        System.assertEquals(2, list1.size());
    }

    @IsTest
    static void ingest_delegates_to_the_action() {
        LLMServiceFactory.setMock(new MockLLMService(
            '{"name":"Omar","email":"o@x.com","phone":"","summary":"eng","confidence":"High","facts":[' +
            '{"type":"Skill","name":"Apex","detail":"","certainty":"Stated","evidence":"Apex","conflict":""}]}'
        ));

        Test.startTest();
        CVAgentController.IngestView v = CVAgentController.ingestCV('some cv text', 'omar.txt');
        Test.stopTest();

        System.assert(v.success, 'Delegated ingestion succeeds');
        System.assertNotEquals(null, v.candidateId);
        System.assertEquals(1, [SELECT COUNT() FROM Candidate__c]);
    }

    @IsTest
    static void ingest_blank_fails_cleanly() {
        LLMServiceFactory.setMock(MockLLMService.failing('should not be called'));

        Test.startTest();
        CVAgentController.IngestView v = CVAgentController.ingestCV('', 'x.txt');
        Test.stopTest();

        System.assert(!v.success);
        System.assertEquals(0, [SELECT COUNT() FROM Candidate__c]);
    }

    @IsTest
    static void compare_delegates_to_the_action() {
        ScoringPolicy.injectedCriteria = new List<ScoringPolicy.Criterion>{
            new ScoringPolicy.Criterion('Skill', 100, 'skill')
        };
        ScoringPolicy.injectedConfig = new ScoringPolicy.Config();

        Candidate__c c = makeCandidate('Alice');
        makeFact(c.Id, 'Stated', 'Apex');
        LLMServiceFactory.setMock(new MockLLMService(
            '{"criteria":[{"criterion":"Skill","match":1.0,"certainty":"Stated",' +
            '"evidence":[{"quote":"Apex"}],"justification":"x"}]}'
        ));

        Test.startTest();
        CVAgentController.CompareView v = CVAgentController.compareCandidates('Engineer', new List<String>{ c.Id });
        Test.stopTest();

        System.assert(v.success);
        System.assertEquals('Alice', v.recommendedName);
        System.assert(v.topScore == 100);
        System.assertNotEquals(null, v.scorecardsJson);
    }
}
