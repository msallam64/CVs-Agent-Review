/**
 * Agentforce action: answer a grounded question about one or more candidates.
 *
 * The prompt ASKS the model to cite verbatim CV evidence and to refuse when the
 * CV does not support an answer. This class VERIFIES that: every cited quote is
 * checked against the source, and an answer whose evidence cannot be found is
 * replaced with the refusal - the read-path twin of the CVParser grounding gate.
 *
 * Context routing (decided in Apex, not in the prompt):
 *   one candidate   -> raw CV_Text__c        (maximum fidelity; certainty is the model's claim)
 *   many candidates -> Fact__c rows          (compact, pre-grounded; certainty read from the fact)
 *   zero candidates -> refusal, no callout    (no data is answered like unsupported data)
 */
public with sharing class QueryCandidates {

    private static final String REFUSAL = 'Not found in the CV.';

    public class Request {
        @InvocableVariable(required=true label='Question' description='The recruiter question in natural language')
        public String question;

        @InvocableVariable(label='Candidate Ids' description='One candidate for a focused question, several to compare')
        public List<String> candidateIds;
    }

    public class Result {
        @InvocableVariable(label='Success' description='False only on a system failure, not on an honest refusal')
        public Boolean success;

        @InvocableVariable(label='Grounded' description='True when a verified answer was returned; false means the CV did not support one')
        public Boolean grounded;

        @InvocableVariable(label='Answer')
        public String answer;

        @InvocableVariable(label='Certainty' description='Stated, Inferred, Conflicting or Missing')
        public String certainty;

        @InvocableVariable(label='Evidence' description='Verbatim quotes that support the answer')
        public String evidence;

        @InvocableVariable(label='Candidate Count')
        public Integer candidateCount;
    }

    @InvocableMethod(
        label='Query Candidates'
        description='Answers a grounded question about one or more candidates, citing CV evidence and refusing when the CV does not support an answer.'
    )
    public static List<Result> run(List<Request> requests) {

        // --- gather every candidate id across all requests: one SOQL each ---
        Set<Id> allIds = new Set<Id>();
        for (Request req : requests) {
            allIds.addAll(toIds(req.candidateIds));
        }

        Map<Id, Candidate__c> candidates = new Map<Id, Candidate__c>(
            [SELECT Id, Name, CV_Text__c FROM Candidate__c WHERE Id IN :allIds]
        );

        Map<Id, List<Fact__c>> factsByCandidate = new Map<Id, List<Fact__c>>();
        for (Fact__c f : [SELECT Candidate__c, Type__c, Name, Detail__c, Certainty__c, Evidence__c
                          FROM Fact__c WHERE Candidate__c IN :allIds]) {
            if (!factsByCandidate.containsKey(f.Candidate__c)) {
                factsByCandidate.put(f.Candidate__c, new List<Fact__c>());
            }
            factsByCandidate.get(f.Candidate__c).add(f);
        }

        ILLMService llm = LLMServiceFactory.getService();
        String systemPrompt = CVPrompts.QUERY;

        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(answerOne(req, candidates, factsByCandidate, llm, systemPrompt));
        }

        AgentLogger.flush();
        return results;
    }

    // -------------------------------------------------------------------------

    private static Result answerOne(Request req, Map<Id, Candidate__c> candidates,
                                    Map<Id, List<Fact__c>> factsByCandidate,
                                    ILLMService llm, String systemPrompt) {
        Result r = new Result();

        if (String.isBlank(req.question)) {
            r.success = false;
            r.grounded = false;
            r.answer = 'No question was provided.';
            r.candidateCount = 0;
            return r;
        }

        // Candidates in scope for THIS request, in the order asked, existing only.
        List<Candidate__c> scope = new List<Candidate__c>();
        for (Id id : toIds(req.candidateIds)) {
            if (candidates.containsKey(id)) {
                scope.add(candidates.get(id));
            }
        }
        r.candidateCount = scope.size();

        // No data is answered the same honest way as unsupported data - and costs no callout.
        if (scope.isEmpty()) {
            return refuse(r);
        }

        Boolean multi = scope.size() > 1;
        String context = multi
            ? buildFactContext(scope, factsByCandidate)
            : buildRawContext(scope[0]);

        LLMResponse llmResult = llm.ask(
            systemPrompt,
            'QUESTION:\n' + req.question +
            '\n\nCANDIDATE INFORMATION:\n' + context +
            '\n\nAnswer using only the information above. Output JSON only.'
        );

        if (!llmResult.success) {
            AgentLogger.add('QueryCandidates', false, req.question, null,
                            llmResult.errorMessage, llmResult.durationMs, scope[0].Id);
            r.success = false;
            r.grounded = false;
            r.answer = 'Could not answer this question: ' + llmResult.errorMessage;
            return r;
        }

        Map<String, Object> root;
        try {
            root = (Map<String, Object>) JSON.deserializeUntyped(stripFences(llmResult.text));
        } catch (Exception e) {
            AgentLogger.add('QueryCandidates', false, req.question, llmResult.text,
                            'Unparseable answer: ' + e.getMessage(), llmResult.durationMs, scope[0].Id);
            r.success = false;
            r.grounded = false;
            r.answer = 'Could not read the answer for this question.';
            return r;
        }

        String rawAnswer = str(root.get('answer'));

        // Branch 1: the model refused. A refusal needs no evidence, just like a Missing fact.
        if (isRefusal(rawAnswer)) {
            r.success = true;
            r.grounded = false;
            r.answer = REFUSAL;
            r.certainty = 'Missing';
            r.evidence = '';
            return r;
        }

        // Verify every cited quote against the source.
        List<String> verifiedLines = new List<String>();
        List<String> matchedCertainties = new List<String>();

        Object rawEvidence = root.get('evidence');
        if (rawEvidence instanceof List<Object>) {
            for (Object o : (List<Object>) rawEvidence) {
                if (!(o instanceof Map<String, Object>)) {
                    continue;
                }
                Map<String, Object> ev = (Map<String, Object>) o;
                String quote = str(ev.get('quote'));
                if (String.isBlank(quote)) {
                    continue;
                }

                VerifyResult vr = multi
                    ? verifyAgainstFacts(str(ev.get('candidate')), quote, scope, factsByCandidate)
                    : verifyAgainstText(scope[0], quote);

                if (vr.verified) {
                    verifiedLines.add(vr.candidateName + ': "' + quote + '"');
                    if (vr.certainty != null) {
                        matchedCertainties.add(vr.certainty);
                    }
                }
            }
        }

        // Branch 3: nothing verified. Suppress the answer - however confident it sounded.
        if (verifiedLines.isEmpty()) {
            AgentLogger.add('QueryCandidates', true, req.question, rawAnswer,
                            'Suppressed ungrounded answer', llmResult.durationMs, scope[0].Id);
            return refuse(r);
        }

        // Branch 2: verified answer. In multi mode certainty is READ from the matched
        // fact rows (not trusted); in single mode it is the model's claim, enum-checked.
        r.success = true;
        r.grounded = true;
        r.answer = rawAnswer;
        r.certainty = multi
            ? deriveCertainty(matchedCertainties)
            : normaliseCertainty(str(root.get('certainty')));
        r.evidence = String.join(verifiedLines, '\n');
        AgentLogger.add('QueryCandidates', true, req.question, r.answer,
                        null, llmResult.durationMs, scope[0].Id);
        return r;
    }

    // --- context builders ----------------------------------------------------

    private static String buildRawContext(Candidate__c c) {
        return 'Candidate: ' + c.Name + '\n' + (c.CV_Text__c == null ? '' : c.CV_Text__c);
    }

    private static String buildFactContext(List<Candidate__c> scope,
                                           Map<Id, List<Fact__c>> factsByCandidate) {
        List<String> blocks = new List<String>();
        for (Candidate__c c : scope) {
            List<String> lines = new List<String>{ 'Candidate: ' + c.Name };
            List<Fact__c> facts = factsByCandidate.get(c.Id);
            if (facts != null) {
                for (Fact__c f : facts) {
                    String ev = String.isBlank(f.Evidence__c)
                        ? '(no evidence - information is absent)'
                        : '"' + f.Evidence__c + '"';
                    lines.add('- [' + f.Certainty__c + '] ' + f.Type__c + ': ' + f.Name
                              + (String.isBlank(f.Detail__c) ? '' : ' - ' + f.Detail__c)
                              + ' | evidence: ' + ev);
                }
            }
            blocks.add(String.join(lines, '\n'));
        }
        return String.join(blocks, '\n\n');
    }

    // --- verification --------------------------------------------------------

    private class VerifyResult {
        Boolean verified = false;
        String candidateName;
        String certainty;
    }

    /** Single candidate: the quote must appear verbatim in the raw CV text. */
    private static VerifyResult verifyAgainstText(Candidate__c c, String quote) {
        VerifyResult vr = new VerifyResult();
        String needle = normalise(quote);
        if (String.isNotBlank(needle) && normalise(c.CV_Text__c).contains(needle)) {
            vr.verified = true;
            vr.candidateName = c.Name;
        }
        return vr;
    }

    /**
     * Multi candidate: the quote must match a real Fact evidence for the named
     * candidate. On a match, certainty comes from that fact - it is verified,
     * not asserted by the model.
     */
    private static VerifyResult verifyAgainstFacts(String candName, String quote,
                                                   List<Candidate__c> scope,
                                                   Map<Id, List<Fact__c>> factsByCandidate) {
        VerifyResult vr = new VerifyResult();
        String needle = normalise(quote);
        if (String.isBlank(needle) || String.isBlank(candName)) {
            return vr;
        }
        for (Candidate__c c : scope) {
            if (c.Name == null || !c.Name.equalsIgnoreCase(candName.trim())) {
                continue;
            }
            List<Fact__c> facts = factsByCandidate.get(c.Id);
            if (facts == null) {
                return vr;
            }
            for (Fact__c f : facts) {
                if (String.isBlank(f.Evidence__c)) {
                    continue;
                }
                String ev = normalise(f.Evidence__c);
                if (ev.contains(needle) || needle.contains(ev)) {
                    vr.verified = true;
                    vr.candidateName = c.Name;
                    vr.certainty = f.Certainty__c;
                    return vr;
                }
            }
            return vr; // matched the candidate, but no quote matched a fact
        }
        return vr;
    }

    /** Weakest link wins: any Conflicting -> Conflicting; else any Inferred -> Inferred. */
    private static String deriveCertainty(List<String> certs) {
        Boolean hasConflicting = false;
        Boolean hasInferred = false;
        for (String c : certs) {
            if (c == 'Conflicting') { hasConflicting = true; }
            else if (c == 'Inferred') { hasInferred = true; }
        }
        if (hasConflicting) { return 'Conflicting'; }
        if (hasInferred)    { return 'Inferred'; }
        return 'Stated';
    }

    // --- helpers -------------------------------------------------------------

    private static Result refuse(Result r) {
        r.success = true;
        r.grounded = false;
        r.answer = REFUSAL;
        r.certainty = 'Missing';
        r.evidence = '';
        return r;
    }

    private static Boolean isRefusal(String answer) {
        return answer != null && answer.trim().toLowerCase().startsWith('not found in the cv');
    }

    private static List<Id> toIds(List<String> raw) {
        List<Id> ids = new List<Id>();
        if (raw == null) {
            return ids;
        }
        for (String s : raw) {
            if (String.isBlank(s)) {
                continue;
            }
            try {
                ids.add((Id) s.trim());
            } catch (Exception e) {
                // ignore anything that is not a real id
            }
        }
        return ids;
    }

    private static String normalise(String s) {
        return s == null ? '' : s.toLowerCase().replaceAll('\\s+', ' ').trim();
    }

    private static String normaliseCertainty(String s) {
        if (String.isBlank(s)) {
            return 'Inferred';
        }
        String t = s.trim();
        for (String v : new List<String>{ 'Stated', 'Inferred', 'Conflicting', 'Missing' }) {
            if (v.equalsIgnoreCase(t)) {
                return v;
            }
        }
        return 'Inferred';
    }

    private static String stripFences(String s) {
        if (String.isBlank(s)) {
            return s;
        }
        String t = s.trim();
        Integer first = t.indexOf('{');
        Integer last  = t.lastIndexOf('}');
        if (first >= 0 && last > first) {
            return t.substring(first, last + 1);
        }
        return t;
    }

    private static String str(Object o) {
        return o == null ? '' : String.valueOf(o);
    }
}
