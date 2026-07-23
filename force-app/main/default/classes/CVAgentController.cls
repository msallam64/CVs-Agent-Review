/**
 * Thin controller for the CV Agent LWCs. It never re-implements logic - ingestion
 * and scoring are delegated to the same invocable actions the agent uses, so the
 * UI and the agent always agree. It only adds read queries and @AuraEnabled
 * wrappers with UI-friendly shapes.
 */
public with sharing class CVAgentController {

    // --- Candidate Card ------------------------------------------------------

    public class FactGroup {
        @AuraEnabled public String certainty;
        @AuraEnabled public List<Fact__c> facts;
        public FactGroup(String certainty) {
            this.certainty = certainty;
            this.facts = new List<Fact__c>();
        }
    }

    public class CardView {
        @AuraEnabled public Candidate__c candidate;
        @AuraEnabled public List<FactGroup> groups;
    }

    @AuraEnabled(cacheable=true)
    public static CardView getCandidateCard(Id candidateId) {
        CardView view = new CardView();
        view.candidate = [
            SELECT Id, Name, Email__c, Phone__c, Summary__c, Confidence__c, Status__c,
                   Conflict_Count__c, Missing_Count__c
            FROM Candidate__c WHERE Id = :candidateId
        ];

        // Fixed order: strongest evidence first, absence last.
        Map<String, FactGroup> byCertainty = new Map<String, FactGroup>();
        for (String c : new List<String>{ 'Stated', 'Inferred', 'Conflicting', 'Missing' }) {
            byCertainty.put(c, new FactGroup(c));
        }
        for (Fact__c f : [
            SELECT Type__c, Name, Detail__c, Certainty__c, Evidence__c, Conflict__c
            FROM Fact__c WHERE Candidate__c = :candidateId
            ORDER BY Type__c, Name
        ]) {
            if (byCertainty.containsKey(f.Certainty__c)) {
                byCertainty.get(f.Certainty__c).facts.add(f);
            }
        }

        view.groups = new List<FactGroup>();
        for (String c : new List<String>{ 'Stated', 'Inferred', 'Conflicting', 'Missing' }) {
            if (!byCertainty.get(c).facts.isEmpty()) {
                view.groups.add(byCertainty.get(c));
            }
        }
        return view;
    }

    @AuraEnabled(cacheable=true)
    public static List<Candidate__c> listCandidates() {
        return [
            SELECT Id, Name, Status__c, Confidence__c, Conflict_Count__c, Missing_Count__c
            FROM Candidate__c ORDER BY Name LIMIT 200
        ];
    }

    // --- Comparison (delegates to ScoreAndCompare) ---------------------------

    public class CompareView {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String summary;
        @AuraEnabled public String recommendedName;
        @AuraEnabled public Decimal topScore;
        @AuraEnabled public Boolean strongMatch;
        @AuraEnabled public String scorecardsJson;
    }

    @AuraEnabled
    public static CompareView compareCandidates(String role, List<String> candidateIds) {
        ScoreAndCompare.Request req = new ScoreAndCompare.Request();
        req.role = role;
        req.candidateIds = candidateIds;

        ScoreAndCompare.Result res = ScoreAndCompare.run(
            new List<ScoreAndCompare.Request>{ req }
        )[0];

        CompareView v = new CompareView();
        v.success = res.success;
        v.summary = res.summary;
        v.recommendedName = res.recommendedName;
        v.topScore = res.topScore;
        v.strongMatch = res.strongMatch;
        v.scorecardsJson = res.scorecardsJson;
        return v;
    }

    // --- Ingestion (delegates to IngestCV) -----------------------------------

    public class IngestView {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String candidateId;
        @AuraEnabled public String message;
    }

    @AuraEnabled
    public static IngestView ingestCV(String cvText, String fileName) {
        IngestCV.Request req = new IngestCV.Request();
        req.cvText = cvText;
        req.fileName = fileName;

        IngestCV.Result res = IngestCV.run(new List<IngestCV.Request>{ req })[0];

        IngestView v = new IngestView();
        v.success = res.success;
        v.candidateId = res.candidateId;
        v.message = res.message;
        return v;
    }
}
