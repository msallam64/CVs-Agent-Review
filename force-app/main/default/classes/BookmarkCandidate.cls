/**
 * Agentforce action: bookmark a candidate's evaluation.
 *
 * A bookmark is a SNAPSHOT, not a recompute. It captures what the recruiter saw
 * at evaluation time - candidate overview, score, reasoning, role, timestamp,
 * notes - in one self-contained record, so it stays a faithful audit even if the
 * Candidate or its Facts change later.
 */
public with sharing class BookmarkCandidate {

    public class Request {
        @InvocableVariable(required=true label='Candidate Id')
        public String candidateId;

        @InvocableVariable(required=true label='Role' description='The role the candidate was evaluated for')
        public String role;

        @InvocableVariable(label='Notes' description='Recruiter notes to save with the bookmark')
        public String notes;

        @InvocableVariable(label='Scorecards JSON' description='The ScoreAndCompare output; the matching candidate is extracted from it')
        public String scorecardsJson;

        @InvocableVariable(label='Score' description='Overrides the score from the scorecards if provided')
        public Decimal score;

        @InvocableVariable(label='Reason' description='Overrides the reasoning from the scorecards if provided')
        public String reason;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Bookmark Id')
        public String bookmarkId;

        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(
        label='Bookmark Candidate'
        description='Saves a candidate evaluation as a single, self-contained, auditable bookmark record with recruiter notes.'
    )
    public static List<Result> run(List<Request> requests) {

        Set<Id> ids = new Set<Id>();
        for (Request req : requests) {
            Id id = toId(req.candidateId);
            if (id != null) {
                ids.add(id);
            }
        }

        Map<Id, Candidate__c> candidates = new Map<Id, Candidate__c>(
            [SELECT Id, Name, Email__c, Summary__c FROM Candidate__c WHERE Id IN :ids]
        );

        List<Result> results = new List<Result>();
        List<Bookmark__c> toInsert = new List<Bookmark__c>();
        List<Integer> insertIndex = new List<Integer>(); // maps toInsert -> results position

        for (Request req : requests) {
            Result r = new Result();
            Id id = toId(req.candidateId);

            if (String.isBlank(req.role)) {
                r.success = false;
                r.message = 'A role is required to bookmark an evaluation.';
                results.add(r);
                continue;
            }
            if (id == null || !candidates.containsKey(id)) {
                r.success = false;
                r.message = 'That candidate does not exist.';
                results.add(r);
                continue;
            }

            Candidate__c c = candidates.get(id);
            Map<String, Object> card = findCard(req.scorecardsJson, id);

            Decimal score = req.score != null ? req.score : scoreFrom(card);
            String reason = String.isNotBlank(req.reason) ? req.reason : reasonFrom(card, req.role, score);

            Bookmark__c b = new Bookmark__c(
                Candidate__c = id,
                Role__c      = req.role.abbreviate(255),
                Score__c     = score,
                Reason__c    = reason,
                Notes__c     = req.notes,
                Saved_At__c  = System.now(),
                Snapshot__c  = buildSnapshot(c, req.role, card)
            );

            results.add(r); // filled in after insert
            toInsert.add(b);
            insertIndex.add(results.size() - 1);
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
            for (Integer i = 0; i < toInsert.size(); i++) {
                Bookmark__c b = toInsert[i];
                Result r = results[insertIndex[i]];
                r.success = true;
                r.bookmarkId = b.Id;
                r.message = 'Bookmarked ' + candidates.get(b.Candidate__c).Name
                          + ' for ' + b.Role__c
                          + (b.Score__c == null ? '' : ' (score ' + b.Score__c + ').');
                AgentLogger.add('BookmarkCandidate', true, b.Role__c, r.message, null, null, b.Candidate__c);
            }
        }

        AgentLogger.flush();
        return results;
    }

    // -------------------------------------------------------------------------

    private static Map<String, Object> findCard(String cardsJson, Id candidateId) {
        if (String.isBlank(cardsJson)) {
            return null;
        }
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(cardsJson)) {
                Map<String, Object> m = (Map<String, Object>) o;
                Object cid = m.get('candidateId');
                if (cid != null && candidateId == toId(String.valueOf(cid))) {
                    return m;
                }
            }
        } catch (Exception e) {
            // malformed json -> no card; the bookmark still saves overview + notes
        }
        return null;
    }

    private static Decimal scoreFrom(Map<String, Object> card) {
        if (card == null || card.get('score') == null) {
            return null;
        }
        try {
            return Decimal.valueOf(String.valueOf(card.get('score')));
        } catch (Exception e) {
            return null;
        }
    }

    private static String reasonFrom(Map<String, Object> card, String role, Decimal score) {
        List<String> parts = new List<String>();
        parts.add('Score ' + (score == null ? 'n/a' : String.valueOf(score)) + '/100 for ' + role + '.');
        if (card != null) {
            parts.add('Strengths: ' + listOrNone(card.get('strengths')));
            parts.add('Concerns: ' + listOrNone(card.get('concerns')));
            parts.add('Gaps to validate: ' + listOrNone(card.get('gaps')));
        }
        return String.join(parts, ' ');
    }

    private static String listOrNone(Object raw) {
        if (!(raw instanceof List<Object>) || ((List<Object>) raw).isEmpty()) {
            return 'none';
        }
        List<String> vals = new List<String>();
        for (Object o : (List<Object>) raw) {
            vals.add(String.valueOf(o));
        }
        return String.join(vals, ', ');
    }

    private static String buildSnapshot(Candidate__c c, String role, Map<String, Object> card) {
        Map<String, Object> snap = new Map<String, Object>{
            'candidate' => new Map<String, Object>{
                'id' => c.Id, 'name' => c.Name, 'email' => c.Email__c, 'summary' => c.Summary__c
            },
            'role' => role,
            'evaluatedAt' => String.valueOf(System.now()),
            'scorecard' => card
        };
        return JSON.serialize(snap).abbreviate(32000);
    }

    private static Id toId(String s) {
        if (String.isBlank(s)) {
            return null;
        }
        try {
            return (Id) s.trim();
        } catch (Exception e) {
            return null;
        }
    }
}
