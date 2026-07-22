/**
 * The read-path twin of CVParserTest. Each test hands the action an exact model
 * answer and asserts the grounding gate does the honest thing: verified answers
 * pass, refusals pass, and answers that cite quotes the CV does not contain are
 * suppressed - regardless of how confident the model sounded.
 */
@IsTest
private class QueryCandidatesTest {

    private static Candidate__c makeCandidate(String name, String cvText) {
        Candidate__c c = new Candidate__c(
            Name = name, CV_Text__c = cvText, Status__c = 'Parsed', Confidence__c = 'High'
        );
        insert c;
        return c;
    }

    private static void makeFact(Id candId, String type, String name, String certainty, String evidence) {
        insert new Fact__c(
            Candidate__c = candId, Type__c = type, Name = name,
            Certainty__c = certainty, Evidence__c = evidence
        );
    }

    private static QueryCandidates.Request req(String question, List<String> ids) {
        QueryCandidates.Request r = new QueryCandidates.Request();
        r.question = question;
        r.candidateIds = ids;
        return r;
    }

    private static List<QueryCandidates.Result> ask(String question, List<String> ids) {
        return QueryCandidates.run(new List<QueryCandidates.Request>{ req(question, ids) });
    }

    @IsTest
    static void grounded_single_answer_passes_through() {
        Candidate__c c = makeCandidate('Omar Khalil', 'Skills: Apex, Kubernetes, SOQL. 5 years experience.');
        LLMServiceFactory.setMock(new MockLLMService(
            '{"answer":"Yes, he lists Kubernetes.","certainty":"Stated",' +
            '"evidence":[{"candidate":"Omar Khalil","quote":"Kubernetes"}]}'
        ));

        Test.startTest();
        List<QueryCandidates.Result> out = ask('Does Omar know Kubernetes?', new List<String>{ c.Id });
        Test.stopTest();

        System.assert(out[0].success, 'Should complete');
        System.assert(out[0].grounded, 'A verified quote means the answer is grounded');
        System.assertEquals('Stated', out[0].certainty);
        System.assert(out[0].answer.contains('Kubernetes'), 'Answer preserved');
        System.assert(out[0].evidence.contains('Kubernetes'), 'Verified quote is surfaced');
    }

    @IsTest
    static void model_refusal_passes_through() {
        Candidate__c c = makeCandidate('Omar Khalil', 'Skills: Apex.');
        LLMServiceFactory.setMock(new MockLLMService(
            '{"answer":"Not found in the CV.","certainty":"Missing","evidence":[]}'
        ));

        Test.startTest();
        List<QueryCandidates.Result> out = ask('What is his salary expectation?', new List<String>{ c.Id });
        Test.stopTest();

        System.assert(out[0].success, 'An honest refusal is not a failure');
        System.assert(!out[0].grounded, 'A refusal is not a grounded answer');
        System.assertEquals('Not found in the CV.', out[0].answer);
        System.assertEquals('Missing', out[0].certainty);
    }

    @IsTest
    static void fabricated_quote_is_suppressed() {
        // The core anti-hallucination proof on the read path: the model sounds
        // confident and cites a quote that is NOT in the CV. It must be dropped.
        Candidate__c c = makeCandidate('Omar Khalil', 'Worked at Acme Corp as a backend engineer.');
        LLMServiceFactory.setMock(new MockLLMService(
            '{"answer":"Yes, he is a Rust expert.","certainty":"Stated",' +
            '"evidence":[{"candidate":"Omar Khalil","quote":"expert in Rust"}]}'
        ));

        Test.startTest();
        List<QueryCandidates.Result> out = ask('Is he good at Rust?', new List<String>{ c.Id });
        Test.stopTest();

        System.assert(out[0].success, 'Suppression is a clean outcome, not a system failure');
        System.assert(!out[0].grounded, 'An ungrounded answer must not be marked grounded');
        System.assertEquals('Not found in the CV.', out[0].answer, 'Ungrounded answer is replaced by the refusal');

        Boolean logged = false;
        for (Agent_Log__c log : [SELECT Error__c FROM Agent_Log__c WHERE Action__c = 'QueryCandidates']) {
            if (log.Error__c != null && log.Error__c.contains('Suppressed')) {
                logged = true;
            }
        }
        System.assert(logged, 'The suppression is auditable');
    }

    @IsTest
    static void no_candidates_refuses_without_a_callout() {
        // A failing mock proves no callout is made: if it were, success would be false.
        LLMServiceFactory.setMock(MockLLMService.failing('should never be called'));

        Test.startTest();
        List<QueryCandidates.Result> out = ask('Anything?', new List<String>{});
        Test.stopTest();

        System.assert(out[0].success, 'No data is an honest refusal, not a failure');
        System.assert(!out[0].grounded);
        System.assertEquals('Not found in the CV.', out[0].answer);
        System.assertEquals(0, out[0].candidateCount);
    }

    @IsTest
    static void blank_question_is_handled_without_a_callout() {
        Candidate__c c = makeCandidate('Omar Khalil', 'Skills: Apex.');
        LLMServiceFactory.setMock(MockLLMService.failing('should never be called'));

        Test.startTest();
        List<QueryCandidates.Result> out = ask('', new List<String>{ c.Id });
        Test.stopTest();

        System.assert(!out[0].success, 'A blank question is a caller error');
        System.assert(!out[0].grounded);
    }

    @IsTest
    static void malformed_answer_is_not_trusted() {
        Candidate__c c = makeCandidate('Omar Khalil', 'Skills: Apex.');
        LLMServiceFactory.setMock(new MockLLMService('this is not json'));

        Test.startTest();
        List<QueryCandidates.Result> out = ask('Does he know Apex?', new List<String>{ c.Id });
        Test.stopTest();

        System.assert(!out[0].success, 'Unparseable output is a failure, not an answer');
        System.assert(!out[0].grounded);
    }

    @IsTest
    static void multi_candidate_certainty_comes_from_the_fact_not_the_model() {
        // Two candidates -> Fact-row mode. The model CLAIMS "Stated", but the
        // matched fact is Inferred. Apex must trust the fact, not the model.
        Candidate__c a = makeCandidate('Omar Khalil', 'Led a team of four engineers on the migration.');
        Candidate__c b = makeCandidate('Sara Nasser', 'Individual contributor, 3 years.');
        makeFact(a.Id, 'Skill', 'Leadership', 'Inferred', 'Led a team of four engineers on the migration');
        makeFact(b.Id, 'Experience', 'Tenure', 'Stated', 'Individual contributor, 3 years');

        LLMServiceFactory.setMock(new MockLLMService(
            '{"answer":"Omar shows leadership signal.","certainty":"Stated",' +
            '"evidence":[{"candidate":"Omar Khalil","quote":"Led a team of four engineers"}]}'
        ));

        Test.startTest();
        List<QueryCandidates.Result> out = ask(
            'Who has leadership experience?', new List<String>{ a.Id, b.Id }
        );
        Test.stopTest();

        System.assert(out[0].grounded, 'Quote matches a real fact, so the answer is grounded');
        System.assertEquals(2, out[0].candidateCount, 'Multi-candidate mode');
        System.assertEquals('Inferred', out[0].certainty,
            'Certainty is read from the Inferred fact, not the model claim of Stated');
    }

    @IsTest
    static void multi_candidate_wrong_attribution_is_suppressed() {
        // The quote is real but attributed to the wrong candidate -> not verifiable.
        Candidate__c a = makeCandidate('Omar Khalil', 'x');
        Candidate__c b = makeCandidate('Sara Nasser', 'y');
        makeFact(a.Id, 'Skill', 'Leadership', 'Stated', 'Led a team of four engineers');

        LLMServiceFactory.setMock(new MockLLMService(
            '{"answer":"Sara led a team.","certainty":"Stated",' +
            '"evidence":[{"candidate":"Sara Nasser","quote":"Led a team of four engineers"}]}'
        ));

        Test.startTest();
        List<QueryCandidates.Result> out = ask(
            'Did Sara lead a team?', new List<String>{ a.Id, b.Id }
        );
        Test.stopTest();

        System.assert(!out[0].grounded, 'A quote pinned to the wrong candidate does not verify');
        System.assertEquals('Not found in the CV.', out[0].answer);
    }
}
