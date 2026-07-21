/**
 * These tests are the proof behind the README's claims about ambiguity.
 * Each one hands the parser an exact payload - including the awkward shapes a
 * real model will not produce on demand - and asserts the parser does the
 * right, honest thing.
 */
@IsTest
private class CVParserTest {

    // Helper: wrap a facts array in the standard envelope.
    private static String envelope(String factsJson) {
        return '{"name":"Test Person","email":"t@example.com","phone":"",' +
               '"summary":"s","confidence":"High","facts":' + factsJson + '}';
    }

    @IsTest
    static void clean_stated_fact_is_stored() {
        String json = envelope('[{"type":"Skill","name":"Apex","detail":"",' +
            '"certainty":"Stated","evidence":"Skills: Apex","conflict":""}]');

        Test.startTest();
        CVParser.ParseResult r = CVParser.parse(json, 'raw cv text', 'cv.txt');
        Test.stopTest();

        System.assert(r.success, 'Parse should succeed');
        System.assertEquals(1, r.facts.size(), 'One fact expected');
        System.assertEquals('Stated', r.facts[0].Certainty__c);
        System.assertEquals('Apex', r.facts[0].Name);
        System.assertEquals('Parsed', r.candidate.Status__c, 'Clean input is fully Parsed');
    }

    @IsTest
    static void missing_fact_is_kept_even_without_evidence() {
        // The whole point: absence must be recorded, not silently dropped.
        String json = envelope('[{"type":"Education","name":"Graduation year",' +
            '"detail":"No year given","certainty":"Missing","evidence":"","conflict":""}]');

        Test.startTest();
        CVParser.ParseResult r = CVParser.parse(json, 'raw', 'cv.txt');
        Test.stopTest();

        System.assertEquals(1, r.facts.size(), 'Missing fact must survive');
        System.assertEquals('Missing', r.facts[0].Certainty__c);
        System.assert(String.isBlank(r.facts[0].Evidence__c), 'Missing fact has no evidence by design');
    }

    @IsTest
    static void inferred_fact_retains_its_source_evidence() {
        String json = envelope('[{"type":"Skill","name":"Leadership",' +
            '"detail":"Inferred from managing a team","certainty":"Inferred",' +
            '"evidence":"Led a team of four engineers","conflict":""}]');

        Test.startTest();
        CVParser.ParseResult r = CVParser.parse(json, 'raw', 'cv.txt');
        Test.stopTest();

        System.assertEquals(1, r.facts.size());
        System.assertEquals('Inferred', r.facts[0].Certainty__c);
        System.assert(r.facts[0].Evidence__c.contains('Led a team'),
            'Inferred fact must keep the text it was inferred from');
    }

    @IsTest
    static void conflicting_fact_captures_both_sides() {
        String json = envelope('[{"type":"Experience","name":"Start date",' +
            '"detail":"Dates disagree","certainty":"Conflicting",' +
            '"evidence":"March 2020 ... joined in 2021",' +
            '"conflict":"Header says 2020, note says 2021"}]');

        Test.startTest();
        CVParser.ParseResult r = CVParser.parse(json, 'raw', 'cv.txt');
        Test.stopTest();

        System.assertEquals(1, r.facts.size());
        System.assertEquals('Conflicting', r.facts[0].Certainty__c);
        System.assert(String.isNotBlank(r.facts[0].Conflict__c),
            'Conflicting fact must explain the disagreement');
    }

    @IsTest
    static void ungrounded_fact_is_rejected() {
        // A Stated fact with no evidence is exactly the hallucination case.
        String json = envelope('[{"type":"Skill","name":"Rust","detail":"",' +
            '"certainty":"Stated","evidence":"","conflict":""}]');

        Test.startTest();
        CVParser.ParseResult r = CVParser.parse(json, 'raw', 'cv.txt');
        Test.stopTest();

        System.assertEquals(0, r.facts.size(), 'Ungrounded Stated fact must be dropped');
        System.assertEquals('Partial', r.candidate.Status__c,
            'Dropping a fact marks the card Partial');
    }

    @IsTest
    static void unknown_certainty_value_is_rejected() {
        String json = envelope('[{"type":"Skill","name":"Java","detail":"",' +
            '"certainty":"ProbablyTrue","evidence":"Java","conflict":""}]');

        Test.startTest();
        CVParser.ParseResult r = CVParser.parse(json, 'raw', 'cv.txt');
        Test.stopTest();

        System.assertEquals(0, r.facts.size(), 'Value outside the vocabulary must be rejected');
    }

    @IsTest
    static void case_variations_are_accepted() {
        // Models often emit lower case. That should not cost a valid fact.
        String json = envelope('[{"type":"skill","name":"Docker","detail":"",' +
            '"certainty":"stated","evidence":"Docker","conflict":""}]');

        Test.startTest();
        CVParser.ParseResult r = CVParser.parse(json, 'raw', 'cv.txt');
        Test.stopTest();

        System.assertEquals(1, r.facts.size(), 'Case should be normalised, not rejected');
        System.assertEquals('Stated', r.facts[0].Certainty__c);
        System.assertEquals('Skill', r.facts[0].Type__c);
    }

    @IsTest
    static void malformed_json_fails_cleanly() {
        Test.startTest();
        CVParser.ParseResult r = CVParser.parse('this is not json', 'raw', 'cv.txt');
        Test.stopTest();

        System.assert(!r.success, 'Malformed JSON must not succeed');
        System.assert(String.isNotBlank(r.errorMessage), 'A reason must be given');
        System.assertEquals(0, r.facts.size(), 'Nothing is stored from garbage');
    }

    @IsTest
    static void json_wrapped_in_markdown_fences_is_recovered() {
        String fenced = '```json\n' + envelope('[{"type":"Skill","name":"Go",' +
            '"detail":"","certainty":"Stated","evidence":"Go","conflict":""}]') + '\n```';

        Test.startTest();
        CVParser.ParseResult r = CVParser.parse(fenced, 'raw', 'cv.txt');
        Test.stopTest();

        System.assertEquals(1, r.facts.size(), 'Fenced JSON should still parse');
    }
}
