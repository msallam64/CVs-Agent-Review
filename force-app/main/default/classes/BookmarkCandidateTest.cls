/**
 * Proves a bookmark is one self-contained, auditable record: it captures the
 * candidate overview, score, reasoning, role, timestamp and notes as shown at
 * evaluation time, derives them from the scorecards, and refuses bad input.
 */
@IsTest
private class BookmarkCandidateTest {

    private static Candidate__c makeCandidate(String name, String email, String summary) {
        Candidate__c c = new Candidate__c(
            Name = name, Email__c = email, Summary__c = summary,
            Status__c = 'Parsed', Confidence__c = 'High'
        );
        insert c;
        return c;
    }

    private static String cardsJson(Id cid, String name, Decimal score,
                                    List<String> strengths, List<String> concerns, List<String> gaps) {
        return JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'candidateId' => cid, 'name' => name, 'score' => score, 'coverage' => 80,
                'strengths' => strengths, 'concerns' => concerns, 'gaps' => gaps,
                'criteria' => new List<Object>()
            }
        });
    }

    private static BookmarkCandidate.Request req(Id candidateId, String role) {
        BookmarkCandidate.Request r = new BookmarkCandidate.Request();
        r.candidateId = candidateId;
        r.role = role;
        return r;
    }

    private static List<BookmarkCandidate.Result> run(BookmarkCandidate.Request r) {
        return BookmarkCandidate.run(new List<BookmarkCandidate.Request>{ r });
    }

    @IsTest
    static void bookmark_from_scorecards_creates_one_record() {
        Candidate__c c = makeCandidate('Alice', 'alice@example.com', 'Salesforce engineer');
        BookmarkCandidate.Request r = req(c.Id, 'Senior SF Developer');
        r.notes = 'Call her Monday';
        r.scorecardsJson = cardsJson(c.Id, 'Alice', 80,
            new List<String>{ 'Technical Skills' }, new List<String>(), new List<String>{ 'Education' });

        Test.startTest();
        List<BookmarkCandidate.Result> out = run(r);
        Test.stopTest();

        System.assert(out[0].success);
        System.assertNotEquals(null, out[0].bookmarkId);

        Bookmark__c b = [SELECT Candidate__c, Role__c, Score__c, Reason__c, Notes__c, Saved_At__c, Snapshot__c FROM Bookmark__c];
        System.assertEquals(c.Id, b.Candidate__c);
        System.assertEquals('Senior SF Developer', b.Role__c);
        System.assert(b.Score__c == 80, 'Score derived from the scorecard');
        System.assertEquals('Call her Monday', b.Notes__c);
        System.assertNotEquals(null, b.Saved_At__c, 'Timestamped');
        System.assert(b.Reason__c.contains('Technical Skills'), 'Strengths in the reasoning');
        System.assert(b.Reason__c.contains('Education'), 'Gaps in the reasoning');
    }

    @IsTest
    static void snapshot_is_self_contained() {
        Candidate__c c = makeCandidate('Alice', 'alice@example.com', 'Salesforce engineer');
        BookmarkCandidate.Request r = req(c.Id, 'Senior SF Developer');
        r.scorecardsJson = cardsJson(c.Id, 'Alice', 80,
            new List<String>{ 'Technical Skills' }, new List<String>(), new List<String>());

        Test.startTest();
        run(r);
        Test.stopTest();

        Bookmark__c b = [SELECT Snapshot__c FROM Bookmark__c];
        Map<String, Object> snap = (Map<String, Object>) JSON.deserializeUntyped(b.Snapshot__c);
        Map<String, Object> cand = (Map<String, Object>) snap.get('candidate');
        System.assertEquals('Alice', cand.get('name'), 'Overview captured for audit');
        System.assertEquals('alice@example.com', cand.get('email'));
        System.assertNotEquals(null, snap.get('scorecard'), 'Scorecard captured');
        System.assertNotEquals(null, snap.get('evaluatedAt'));
    }

    @IsTest
    static void explicit_score_and_reason_override_the_scorecard() {
        Candidate__c c = makeCandidate('Alice', 'alice@example.com', 'engineer');
        BookmarkCandidate.Request r = req(c.Id, 'Role X');
        r.score = 95;
        r.reason = 'Exceptional fit, hire fast.';

        Test.startTest();
        run(r);
        Test.stopTest();

        Bookmark__c b = [SELECT Score__c, Reason__c FROM Bookmark__c];
        System.assert(b.Score__c == 95);
        System.assertEquals('Exceptional fit, hire fast.', b.Reason__c);
    }

    @IsTest
    static void invalid_candidate_is_rejected() {
        BookmarkCandidate.Request r = new BookmarkCandidate.Request();
        r.candidateId = 'notanid';
        r.role = 'Role X';

        Test.startTest();
        List<BookmarkCandidate.Result> out = run(r);
        Test.stopTest();

        System.assert(!out[0].success);
        System.assertEquals(0, [SELECT COUNT() FROM Bookmark__c], 'Nothing saved for a bad candidate');
    }

    @IsTest
    static void missing_role_is_rejected() {
        Candidate__c c = makeCandidate('Alice', 'a@x.com', 's');
        Test.startTest();
        List<BookmarkCandidate.Result> out = run(req(c.Id, ''));
        Test.stopTest();

        System.assert(!out[0].success);
        System.assertEquals(0, [SELECT COUNT() FROM Bookmark__c]);
    }

    @IsTest
    static void bulk_is_safe() {
        List<BookmarkCandidate.Request> reqs = new List<BookmarkCandidate.Request>();
        for (Integer i = 0; i < 5; i++) {
            Candidate__c c = makeCandidate('Cand ' + i, 'c' + i + '@x.com', 's');
            reqs.add(req(c.Id, 'Role ' + i));
        }

        Test.startTest();
        List<BookmarkCandidate.Result> out = BookmarkCandidate.run(reqs);
        Test.stopTest();

        System.assertEquals(5, out.size());
        System.assertEquals(5, [SELECT COUNT() FROM Bookmark__c], 'One record per bookmark');
    }

    @IsTest
    static void action_is_logged() {
        Candidate__c c = makeCandidate('Alice', 'a@x.com', 's');
        Test.startTest();
        run(req(c.Id, 'Role X'));
        Test.stopTest();

        System.assert([SELECT COUNT() FROM Agent_Log__c WHERE Action__c = 'BookmarkCandidate'] > 0);
    }
}
