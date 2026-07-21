/**
 * Exercises the whole IngestCV action with the LLM mocked out, so no callout
 * happens. Proves records are written, failures degrade gracefully, and the
 * action is bulk safe.
 */
@IsTest
private class IngestCVTest {

    private static String goodPayload() {
        return '{"name":"Omar Khalil","email":"omar@example.com","phone":"",' +
               '"summary":"Engineer","confidence":"High","facts":[' +
               '{"type":"Skill","name":"Apex","detail":"","certainty":"Stated","evidence":"Apex","conflict":""},' +
               '{"type":"Education","name":"Grad year","detail":"absent","certainty":"Missing","evidence":"","conflict":""}' +
               ']}';
    }

    private static IngestCV.Request req(String text) {
        IngestCV.Request r = new IngestCV.Request();
        r.cvText = text;
        r.fileName = 'cv.txt';
        return r;
    }

    @IsTest
    static void happy_path_creates_candidate_and_facts() {
        LLMServiceFactory.setMock(new MockLLMService(goodPayload()));

        Test.startTest();
        List<IngestCV.Result> out = IngestCV.run(new List<IngestCV.Request>{ req('some cv') });
        Test.stopTest();

        System.assert(out[0].success, 'Should succeed');
        System.assertNotEquals(null, out[0].candidateId, 'Candidate Id returned');

        System.assertEquals(1, [SELECT COUNT() FROM Candidate__c]);
        System.assertEquals(2, [SELECT COUNT() FROM Fact__c]);
        System.assertEquals(1, [SELECT COUNT() FROM Fact__c WHERE Certainty__c = 'Missing']);
    }

    @IsTest
    static void blank_cv_is_handled_without_a_callout() {
        LLMServiceFactory.setMock(new MockLLMService(goodPayload()));

        Test.startTest();
        List<IngestCV.Result> out = IngestCV.run(new List<IngestCV.Request>{ req('') });
        Test.stopTest();

        System.assert(!out[0].success, 'Blank CV should fail cleanly');
        System.assertEquals(0, [SELECT COUNT() FROM Candidate__c], 'Nothing stored');
    }

    @IsTest
    static void llm_failure_degrades_gracefully() {
        LLMServiceFactory.setMock(MockLLMService.failing('API down'));

        Test.startTest();
        List<IngestCV.Result> out = IngestCV.run(new List<IngestCV.Request>{ req('some cv') });
        Test.stopTest();

        System.assert(!out[0].success, 'Should report failure');
        System.assert(out[0].message.contains('Could not read'), 'Message explains the failure');
        System.assertEquals(0, [SELECT COUNT() FROM Candidate__c], 'No partial records');
    }

    @IsTest
    static void malformed_model_output_is_not_stored() {
        LLMServiceFactory.setMock(new MockLLMService('not json at all'));

        Test.startTest();
        List<IngestCV.Result> out = IngestCV.run(new List<IngestCV.Request>{ req('some cv') });
        Test.stopTest();

        System.assert(!out[0].success);
        System.assertEquals(0, [SELECT COUNT() FROM Candidate__c]);
    }

    @IsTest
    static void bulk_ingestion_is_safe() {
        LLMServiceFactory.setMock(new MockLLMService(goodPayload()));

        List<IngestCV.Request> many = new List<IngestCV.Request>();
        for (Integer i = 0; i < 20; i++) {
            many.add(req('cv number ' + i));
        }

        Test.startTest();
        List<IngestCV.Result> out = IngestCV.run(many);
        Test.stopTest();

        System.assertEquals(20, out.size());
        System.assertEquals(20, [SELECT COUNT() FROM Candidate__c], 'All candidates created');
        System.assertEquals(40, [SELECT COUNT() FROM Fact__c], 'Two facts each');
    }

    @IsTest
    static void agent_log_is_written() {
        LLMServiceFactory.setMock(new MockLLMService(goodPayload()));

        Test.startTest();
        IngestCV.run(new List<IngestCV.Request>{ req('some cv') });
        Test.stopTest();

        System.assert([SELECT COUNT() FROM Agent_Log__c] > 0, 'Action is logged');
    }
}
