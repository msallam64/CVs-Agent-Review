/**
 * Agentforce action: resolve a name or keyword to matching candidates.
 *
 * Recruiters speak in names ("compare Omar and Sara"); the other actions need
 * candidate Ids. This action bridges that gap so the agent can look a candidate
 * up, then feed the Ids into Query or Score.
 */
public with sharing class FindCandidates {

    public class Request {
        @InvocableVariable(label='Search Term' description='Name or keyword to match; leave blank to list all candidates')
        public String searchTerm;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Match Count')
        public Integer matchCount;

        @InvocableVariable(label='Candidate Ids' description='Feed these into Query or Score')
        public List<String> candidateIds;

        @InvocableVariable(label='Candidate Names')
        public List<String> candidateNames;

        @InvocableVariable(label='Summary')
        public String summary;
    }

    @InvocableMethod(
        label='Find Candidates'
        description='Resolves a name or keyword to matching candidate records so other actions can use their Ids.'
    )
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(find(req));
        }
        return results;
    }

    private static Result find(Request req) {
        Result r = new Result();
        r.candidateIds = new List<String>();
        r.candidateNames = new List<String>();

        List<Candidate__c> matches;
        if (String.isBlank(req.searchTerm)) {
            matches = [SELECT Id, Name FROM Candidate__c ORDER BY Name LIMIT 50];
        } else {
            String pattern = '%' + req.searchTerm.trim() + '%';
            matches = [SELECT Id, Name FROM Candidate__c WHERE Name LIKE :pattern ORDER BY Name LIMIT 50];
        }

        for (Candidate__c c : matches) {
            r.candidateIds.add(c.Id);
            r.candidateNames.add(c.Name);
        }
        r.matchCount = matches.size();
        r.success = true;
        r.summary = matches.isEmpty()
            ? 'No candidates found' + (String.isBlank(req.searchTerm) ? '.' : ' matching "' + req.searchTerm + '".')
            : 'Found ' + matches.size() + ': ' + String.join(r.candidateNames, ', ') + '.';
        return r;
    }
}
