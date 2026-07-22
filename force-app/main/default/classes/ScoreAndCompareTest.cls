/**
 * Proves the scoring is honest arithmetic over verified inputs, not a number the
 * model made up: the certainty discount moves the score, an ungrounded criterion
 * collapses to a gap (never a confident score), coverage falls with unknowns, a
 * weak top pick is labelled best-available, and ranking is deterministic.
 *
 * Policy is injected so the tests do not depend on deployed Custom Metadata; the
 * LLM is mocked so no callout happens.
 */
@IsTest
private class ScoreAndCompareTest {

    // A two-criterion rubric keeps the arithmetic easy to assert.
    private static void injectRubric() {
        ScoringPolicy.injectedCriteria = new List<ScoringPolicy.Criterion>{
            new ScoringPolicy.Criterion('Skill', 50, 'skill'),
            new ScoringPolicy.Criterion('Experience', 50, 'experience')
        };
        ScoringPolicy.injectedConfig = new ScoringPolicy.Config(); // 1.0 / 0.6 / 0.4 / 0.0, threshold 60
    }

    /** Routes a different model answer per candidate, by name in the prompt. */
    private class RoutingMock implements ILLMService {
        private Map<String, String> byName;
        RoutingMock(Map<String, String> byName) { this.byName = byName; }
        public LLMResponse ask(String systemPrompt, String userPrompt) {
            for (String name : byName.keySet()) {
                if (userPrompt.contains('Candidate: ' + name)) {
                    return LLMResponse.ok(byName.get(name), 200, 1);
                }
            }
            return LLMResponse.ok('{"criteria":[]}', 200, 1);
        }
    }

    private static Candidate__c makeCandidate(String name) {
        Candidate__c c = new Candidate__c(Name = name, Status__c = 'Parsed', Confidence__c = 'High');
        insert c;
        return c;
    }

    private static void makeFact(Id candId, String type, String name, String certainty, String evidence) {
        insert new Fact__c(
            Candidate__c = candId, Type__c = type, Name = name,
            Certainty__c = certainty, Evidence__c = evidence
        );
    }

    private static String resp(Decimal skillMatch, String skillQuote, Decimal expMatch, String expQuote) {
        return '{"criteria":[' +
            '{"criterion":"Skill","match":' + skillMatch + ',"certainty":"Stated","evidence":[{"quote":"' + skillQuote + '"}],"justification":"x"},' +
            '{"criterion":"Experience","match":' + expMatch + ',"certainty":"Stated","evidence":[{"quote":"' + expQuote + '"}],"justification":"y"}' +
        ']}';
    }

    private static List<ScoreAndCompare.Result> run(String role, List<String> ids) {
        ScoreAndCompare.Request r = new ScoreAndCompare.Request();
        r.role = role;
        r.candidateIds = ids;
        return ScoreAndCompare.run(new List<ScoreAndCompare.Request>{ r });
    }

    private static Map<String, Object> firstCard(ScoreAndCompare.Result r) {
        List<Object> cards = (List<Object>) JSON.deserializeUntyped(r.scorecardsJson);
        return (Map<String, Object>) cards[0];
    }

    private static Map<String, Object> criterionNamed(Map<String, Object> card, String name) {
        for (Object o : (List<Object>) card.get('criteria')) {
            Map<String, Object> m = (Map<String, Object>) o;
            if (m.get('criterion') == name) { return m; }
        }
        return null;
    }

    @IsTest
    static void all_stated_evidence_scores_full() {
        injectRubric();
        Candidate__c c = makeCandidate('Alice');
        makeFact(c.Id, 'Skill', 'Apex', 'Stated', 'Apex');
        makeFact(c.Id, 'Experience', 'Tenure', 'Stated', '5 years');
        LLMServiceFactory.setMock(new MockLLMService(resp(1.0, 'Apex', 1.0, '5 years')));

        Test.startTest();
        List<ScoreAndCompare.Result> out = run('Engineer', new List<String>{ c.Id });
        Test.stopTest();

        System.assert(out[0].success);
        System.assertEquals(100.0, out[0].topScore, 'Two fully-evidenced Stated criteria = 100');
        System.assert(out[0].strongMatch, 'Above the threshold');
        System.assertEquals('Alice', out[0].recommendedName);
        System.assert(((List<Object>) firstCard(out[0]).get('gaps')).isEmpty(), 'No gaps when all evidenced');
    }

    @IsTest
    static void inferred_evidence_is_discounted() {
        injectRubric();
        Candidate__c c = makeCandidate('Alice');
        // The Skill quote matches an INFERRED fact -> discounted to 0.6.
        makeFact(c.Id, 'Skill', 'Leadership', 'Inferred', 'led a team of four');
        makeFact(c.Id, 'Experience', 'Tenure', 'Stated', '5 years');
        LLMServiceFactory.setMock(new MockLLMService(resp(1.0, 'led a team of four', 1.0, '5 years')));

        Test.startTest();
        List<ScoreAndCompare.Result> out = run('Engineer', new List<String>{ c.Id });
        Test.stopTest();

        // Skill: 1 * 50 * 0.6 = 30 ; Experience: 1 * 50 * 1.0 = 50 ; /100 * 100 = 80
        System.assertEquals(80.0, out[0].topScore, 'Inferred evidence must lower the score');
        System.assertEquals('Inferred', criterionNamed(firstCard(out[0]), 'Skill').get('certainty'),
            'Certainty is read from the fact, not the model');
    }

    @IsTest
    static void fabricated_quote_collapses_to_a_gap() {
        injectRubric();
        Candidate__c c = makeCandidate('Alice');
        makeFact(c.Id, 'Experience', 'Tenure', 'Stated', '5 years');
        // Model is confident about Skill but cites a quote that is not in any fact.
        LLMServiceFactory.setMock(new MockLLMService(resp(0.9, 'expert in Rust', 1.0, '5 years')));

        Test.startTest();
        List<ScoreAndCompare.Result> out = run('Engineer', new List<String>{ c.Id });
        Test.stopTest();

        // Skill collapses to Missing (0); only Experience counts: 50/100*100 = 50
        System.assertEquals(50.0, out[0].topScore, 'Ungrounded criterion must contribute nothing');
        System.assert(!out[0].strongMatch, 'Below threshold');
        System.assert(out[0].summary.contains('best available'), 'Weak top pick is framed honestly');

        Map<String, Object> card = firstCard(out[0]);
        System.assertEquals('Missing', criterionNamed(card, 'Skill').get('certainty'));
        System.assert(((List<Object>) card.get('gaps')).contains('Skill'), 'Unknown is a gap, not a confirmed weakness');
        System.assertEquals('50', String.valueOf(card.get('coverage')), 'Coverage falls with the unknown criterion');
    }

    @IsTest
    static void ranking_is_deterministic_and_apex_side() {
        injectRubric();
        Candidate__c alice = makeCandidate('Alice');
        Candidate__c bob = makeCandidate('Bob');
        makeFact(alice.Id, 'Skill', 'Apex', 'Stated', 'Apex');
        makeFact(alice.Id, 'Experience', 'Tenure', 'Stated', '5 years');
        makeFact(bob.Id, 'Experience', 'Tenure', 'Stated', '2 years');

        LLMServiceFactory.setMock(new RoutingMock(new Map<String, String>{
            'Alice' => resp(1.0, 'Apex', 1.0, '5 years'),          // -> 100
            'Bob'   => resp(0.9, 'not in the cv', 1.0, '2 years')  // Skill unverifiable -> 50
        }));

        Test.startTest();
        List<ScoreAndCompare.Result> out = run('Engineer', new List<String>{ bob.Id, alice.Id });
        Test.stopTest();

        System.assertEquals(2, out[0].candidateCount);
        System.assertEquals('Alice', out[0].recommendedName, 'Higher score ranks first regardless of input order');
        System.assertEquals(100.0, out[0].topScore);

        List<Object> cards = (List<Object>) JSON.deserializeUntyped(out[0].scorecardsJson);
        System.assertEquals('Alice', ((Map<String, Object>) cards[0]).get('name'));
        System.assertEquals('Bob', ((Map<String, Object>) cards[1]).get('name'));
    }

    @IsTest
    static void blank_role_fails() {
        injectRubric();
        Candidate__c c = makeCandidate('Alice');
        LLMServiceFactory.setMock(MockLLMService.failing('should never be called'));

        Test.startTest();
        List<ScoreAndCompare.Result> out = run('', new List<String>{ c.Id });
        Test.stopTest();

        System.assert(!out[0].success, 'No role is a caller error');
    }

    @IsTest
    static void no_candidates_fails() {
        injectRubric();
        LLMServiceFactory.setMock(MockLLMService.failing('should never be called'));

        Test.startTest();
        List<ScoreAndCompare.Result> out = run('Engineer', new List<String>{});
        Test.stopTest();

        System.assert(!out[0].success, 'Nothing to compare');
    }

    @IsTest
    static void llm_failure_leaves_nothing_scored() {
        injectRubric();
        Candidate__c c = makeCandidate('Alice');
        LLMServiceFactory.setMock(MockLLMService.failing('evaluator down'));

        Test.startTest();
        List<ScoreAndCompare.Result> out = run('Engineer', new List<String>{ c.Id });
        Test.stopTest();

        System.assert(!out[0].success, 'A candidate that could not be scored is not silently given a number');
    }

    @IsTest
    static void action_is_logged() {
        injectRubric();
        Candidate__c c = makeCandidate('Alice');
        makeFact(c.Id, 'Skill', 'Apex', 'Stated', 'Apex');
        LLMServiceFactory.setMock(new MockLLMService(resp(1.0, 'Apex', 0.0, 'x')));

        Test.startTest();
        run('Engineer', new List<String>{ c.Id });
        Test.stopTest();

        System.assert([SELECT COUNT() FROM Agent_Log__c WHERE Action__c = 'ScoreAndCompare'] > 0, 'Decisions are audited');
    }
}
