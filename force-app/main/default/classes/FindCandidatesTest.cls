/**
 * Proves the name/keyword resolution the agent relies on: partial + case-
 * insensitive matching, list-all on blank, a clean empty result, and bulk.
 */
@IsTest
private class FindCandidatesTest {

    private static Candidate__c mk(String name) {
        Candidate__c c = new Candidate__c(Name = name, Status__c = 'Parsed', Confidence__c = 'High');
        insert c;
        return c;
    }

    private static List<FindCandidates.Result> run(String term) {
        FindCandidates.Request q = new FindCandidates.Request();
        q.searchTerm = term;
        return FindCandidates.run(new List<FindCandidates.Request>{ q });
    }

    @IsTest
    static void finds_by_partial_name() {
        mk('Omar Khalil');
        mk('Sara Nasser');

        Test.startTest();
        List<FindCandidates.Result> out = run('omar');
        Test.stopTest();

        System.assert(out[0].success);
        System.assertEquals(1, out[0].matchCount);
        System.assertEquals('Omar Khalil', out[0].candidateNames[0]);
        System.assertNotEquals(null, out[0].candidateIds[0]);
    }

    @IsTest
    static void matching_is_case_insensitive() {
        mk('Omar Khalil');

        Test.startTest();
        List<FindCandidates.Result> out = run('OMAR');
        Test.stopTest();

        System.assertEquals(1, out[0].matchCount);
    }

    @IsTest
    static void blank_lists_all() {
        mk('A');
        mk('B');
        mk('C');

        Test.startTest();
        List<FindCandidates.Result> out = run('');
        Test.stopTest();

        System.assertEquals(3, out[0].matchCount);
    }

    @IsTest
    static void no_match_is_clean() {
        mk('Omar');

        Test.startTest();
        List<FindCandidates.Result> out = run('zzz');
        Test.stopTest();

        System.assert(out[0].success, 'No match is not a failure');
        System.assertEquals(0, out[0].matchCount);
        System.assert(out[0].summary.contains('No candidates'));
    }

    @IsTest
    static void multiple_matches_returned() {
        mk('Sara Nasser');
        mk('Sara Ahmed');

        Test.startTest();
        List<FindCandidates.Result> out = run('Sara');
        Test.stopTest();

        System.assertEquals(2, out[0].matchCount);
    }

    @IsTest
    static void bulk_is_safe() {
        mk('Omar');
        mk('Sara');
        FindCandidates.Request a = new FindCandidates.Request();
        a.searchTerm = 'Omar';
        FindCandidates.Request b = new FindCandidates.Request();
        b.searchTerm = 'Sara';

        Test.startTest();
        List<FindCandidates.Result> out = FindCandidates.run(new List<FindCandidates.Request>{ a, b });
        Test.stopTest();

        System.assertEquals(2, out.size());
        System.assertEquals(1, out[0].matchCount);
        System.assertEquals(1, out[1].matchCount);
    }
}
