/**
 * Agentforce action: score and rank candidates against a role, with reasoning.
 *
 * The model judges each rubric criterion for ONE candidate at a time and cites
 * verbatim evidence. It never scores, never ranks, never compares. Apex verifies
 * every citation, computes the score from the rubric (ScoringPolicy), and ranks -
 * so the ordering is deterministic and every point is explainable.
 *
 * Uncertainty moves the number: a criterion's contribution is discounted by the
 * certainty of the facts behind it, and Missing (unknown) counts as zero but is
 * surfaced as a gap to validate - never as a confirmed weakness.
 */
public with sharing class ScoreAndCompare {

    public class Request {
        @InvocableVariable(required=true label='Role' description='The role to evaluate candidates for')
        public String role;

        @InvocableVariable(label='Candidate Ids' description='The candidates to compare')
        public List<String> candidateIds;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Summary' description='The ranked recommendation with strengths, concerns and gaps')
        public String summary;

        @InvocableVariable(label='Recommended Candidate Id')
        public String recommendedCandidateId;

        @InvocableVariable(label='Recommended Name')
        public String recommendedName;

        @InvocableVariable(label='Top Score')
        public Decimal topScore;

        @InvocableVariable(label='Strong Match' description='True when the top candidate clears the strong-match threshold')
        public Boolean strongMatch;

        @InvocableVariable(label='Scorecards JSON' description='Structured per-candidate breakdown for the UI and bookmark snapshot')
        public String scorecardsJson;

        @InvocableVariable(label='Candidate Count')
        public Integer candidateCount;
    }

    @InvocableMethod(
        label='Score And Compare Candidates'
        description='Scores candidates against a role using a fixed rubric, ranks them, and explains the reasoning with strengths, concerns and gaps.'
    )
    public static List<Result> run(List<Request> requests) {

        Set<Id> allIds = new Set<Id>();
        for (Request req : requests) {
            allIds.addAll(toIds(req.candidateIds));
        }

        Map<Id, Candidate__c> candidates = new Map<Id, Candidate__c>(
            [SELECT Id, Name FROM Candidate__c WHERE Id IN :allIds]
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
        List<ScoringPolicy.Criterion> criteria = ScoringPolicy.criteria();
        ScoringPolicy.Config config = ScoringPolicy.config();

        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(evaluate(req, candidates, factsByCandidate, criteria, config, llm));
        }

        AgentLogger.flush();
        return results;
    }

    // -------------------------------------------------------------------------

    private static Result evaluate(Request req, Map<Id, Candidate__c> candidates,
                                   Map<Id, List<Fact__c>> factsByCandidate,
                                   List<ScoringPolicy.Criterion> criteria,
                                   ScoringPolicy.Config config, ILLMService llm) {
        Result r = new Result();

        if (String.isBlank(req.role)) {
            r.success = false;
            r.summary = 'No role was provided to evaluate against.';
            r.candidateCount = 0;
            return r;
        }

        List<Candidate__c> scope = new List<Candidate__c>();
        for (Id id : toIds(req.candidateIds)) {
            if (candidates.containsKey(id)) {
                scope.add(candidates.get(id));
            }
        }
        r.candidateCount = scope.size();

        if (scope.isEmpty()) {
            r.success = false;
            r.summary = 'No candidates were provided to compare.';
            return r;
        }

        String systemPrompt = CVPrompts.SCORING;
        String rubricText = buildRubricText(criteria);

        List<Scorecard> cards = new List<Scorecard>();
        for (Candidate__c c : scope) {
            Scorecard card = scoreCandidate(c, factsByCandidate.get(c.Id),
                                            req.role, rubricText, criteria, config, llm, systemPrompt);
            if (card != null) {
                cards.add(card);
            }
        }

        if (cards.isEmpty()) {
            r.success = false;
            r.summary = 'None of the candidates could be scored (the evaluator was unavailable or returned unusable output).';
            return r;
        }

        cards.sort(); // Scorecard is Comparable: score desc, then coverage desc

        Scorecard top = cards[0];
        r.success = true;
        r.recommendedCandidateId = top.candidateId;
        r.recommendedName = top.name;
        r.topScore = top.score;
        r.strongMatch = top.score >= config.strongMatchThreshold;
        r.summary = buildSummary(req.role, cards, config);
        r.scorecardsJson = JSON.serialize(toJson(cards));
        return r;
    }

    // --- scoring one candidate ----------------------------------------------

    private static Scorecard scoreCandidate(Candidate__c c, List<Fact__c> facts,
                                            String role, String rubricText,
                                            List<ScoringPolicy.Criterion> criteria,
                                            ScoringPolicy.Config config,
                                            ILLMService llm, String systemPrompt) {
        LLMResponse res = llm.ask(
            systemPrompt,
            'ROLE: ' + role + '\n\n' + rubricText +
            '\n\nCANDIDATE INFORMATION:\n' + buildFactContext(c, facts) +
            '\n\nAssess each rubric criterion. Output JSON only.'
        );

        if (!res.success) {
            AgentLogger.add('ScoreAndCompare', false, role, null, res.errorMessage, res.durationMs, c.Id);
            return null;
        }

        Map<String, Object> assessment = new Map<String, Object>();
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(stripFences(res.text));
            Object rawCriteria = root.get('criteria');
            if (rawCriteria instanceof List<Object>) {
                for (Object o : (List<Object>) rawCriteria) {
                    if (o instanceof Map<String, Object>) {
                        Map<String, Object> m = (Map<String, Object>) o;
                        assessment.put(normalise(str(m.get('criterion'))), m);
                    }
                }
            }
        } catch (Exception e) {
            AgentLogger.add('ScoreAndCompare', false, role, res.text,
                            'Unparseable scoring output: ' + e.getMessage(), res.durationMs, c.Id);
            return null;
        }

        Scorecard card = new Scorecard();
        card.candidateId = c.Id;
        card.name = c.Name;

        Decimal numerator = 0;
        Decimal totalWeight = 0;
        Decimal evidencedWeight = 0;

        for (ScoringPolicy.Criterion crit : criteria) {
            totalWeight += crit.weight;

            Map<String, Object> m = (Map<String, Object>) assessment.get(normalise(crit.label));
            Decimal claimedMatch = m == null ? 0 : clamp(toDecimal(m.get('match')));

            // Verify the cited evidence; certainty comes from the matched facts.
            List<String> matched = new List<String>();
            String verifiedQuote = null;
            if (m != null) {
                Object rawEv = m.get('evidence');
                if (rawEv instanceof List<Object>) {
                    for (Object eo : (List<Object>) rawEv) {
                        String quote = (eo instanceof Map<String, Object>)
                            ? str(((Map<String, Object>) eo).get('quote')) : '';
                        String cert = certaintyOfMatchingFact(quote, facts);
                        if (cert != null) {
                            matched.add(cert);
                            if (verifiedQuote == null) { verifiedQuote = quote; }
                        }
                    }
                }
            }

            String certainty;
            Decimal match;
            if (matched.isEmpty()) {
                // Ungrounded (or absent) criterion collapses to unknown, whatever the model claimed.
                certainty = 'Missing';
                match = 0;
            } else {
                certainty = weakestLink(matched);
                match = claimedMatch;
                evidencedWeight += crit.weight;
            }

            Decimal discount = config.discountFor(certainty);
            Decimal contribution = match * crit.weight * discount;
            numerator += contribution;

            // Buckets: strengths / concerns / gaps
            if (certainty == 'Missing') {
                card.gaps.add(crit.label);
            } else if (certainty == 'Conflicting') {
                card.concerns.add(crit.label + ' (CV is inconsistent)');
            } else if (certainty == 'Stated' && match >= 0.6) {
                card.strengths.add(crit.label);
            }

            card.criteria.add(new Map<String, Object>{
                'criterion'   => crit.label,
                'weight'      => crit.weight,
                'match'       => match,
                'certainty'   => certainty,
                'contribution'=> contribution.setScale(2),
                'evidence'    => verifiedQuote,
                'justification' => m == null ? null : str(m.get('justification'))
            });
        }

        card.score = totalWeight == 0 ? 0 : (numerator / totalWeight * 100).setScale(1);
        card.coverage = totalWeight == 0 ? 0 : (evidencedWeight / totalWeight * 100).setScale(0);
        AgentLogger.add('ScoreAndCompare', true, role, c.Name + ' scored ' + card.score, null, res.durationMs, c.Id);
        return card;
    }

    // --- narrative -----------------------------------------------------------

    private static String buildSummary(String role, List<Scorecard> cards, ScoringPolicy.Config config) {
        Scorecard top = cards[0];
        String label = top.score >= config.strongMatchThreshold ? 'strong match' : 'best available match';

        List<String> out = new List<String>();
        out.add('Role: ' + role);
        out.add('Recommended: ' + top.name + ' - ' + top.score + '/100 (' + label + ').');
        if (top.score < config.strongMatchThreshold) {
            out.add('No candidate is a strong match; the recommendation is the best available option. Validate the gaps below in interview.');
        }

        out.add('\nRanking:');
        Integer rank = 1;
        for (Scorecard c : cards) {
            String tag = c.score >= config.strongMatchThreshold ? 'strong' : 'best available';
            out.add(rank + '. ' + c.name + ' - ' + c.score + '/100, ' + c.coverage + '% evidenced [' + tag + ']');
            rank++;
        }

        for (Scorecard c : cards) {
            out.add('\n' + c.name + ':');
            out.add('  Strengths: ' + (c.strengths.isEmpty() ? 'none clearly evidenced' : String.join(c.strengths, ', ')));
            out.add('  Concerns: ' + (c.concerns.isEmpty() ? 'none' : String.join(c.concerns, ', ')));
            out.add('  Gaps to validate: ' + (c.gaps.isEmpty() ? 'none' : String.join(c.gaps, ', ')));
        }
        return String.join(out, '\n');
    }

    private static List<Map<String, Object>> toJson(List<Scorecard> cards) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Scorecard c : cards) {
            out.add(new Map<String, Object>{
                'candidateId' => c.candidateId,
                'name'        => c.name,
                'score'       => c.score,
                'coverage'    => c.coverage,
                'strengths'   => c.strengths,
                'concerns'    => c.concerns,
                'gaps'        => c.gaps,
                'criteria'    => c.criteria
            });
        }
        return out;
    }

    // --- scorecard -----------------------------------------------------------

    private class Scorecard implements Comparable {
        Id candidateId;
        String name;
        Decimal score = 0;
        Decimal coverage = 0;
        List<String> strengths = new List<String>();
        List<String> concerns = new List<String>();
        List<String> gaps = new List<String>();
        List<Map<String, Object>> criteria = new List<Map<String, Object>>();

        public Integer compareTo(Object other) {
            Scorecard o = (Scorecard) other;
            if (score != o.score)       { return score > o.score ? -1 : 1; }
            if (coverage != o.coverage) { return coverage > o.coverage ? -1 : 1; }
            return 0;
        }
    }

    // --- context builders ----------------------------------------------------

    private static String buildRubricText(List<ScoringPolicy.Criterion> criteria) {
        List<String> lines = new List<String>{ 'RUBRIC (judge each criterion independently):' };
        for (ScoringPolicy.Criterion c : criteria) {
            lines.add('- ' + c.label + ' (weight ' + c.weight + '): ' + c.guidance);
        }
        return String.join(lines, '\n');
    }

    private static String buildFactContext(Candidate__c c, List<Fact__c> facts) {
        List<String> lines = new List<String>{ 'Candidate: ' + c.Name };
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
        return String.join(lines, '\n');
    }

    // --- verification helpers ------------------------------------------------

    /** Return the certainty of a fact whose evidence matches the quote, else null. */
    private static String certaintyOfMatchingFact(String quote, List<Fact__c> facts) {
        String needle = normalise(quote);
        if (String.isBlank(needle) || facts == null) {
            return null;
        }
        for (Fact__c f : facts) {
            if (String.isBlank(f.Evidence__c)) {
                continue;
            }
            String ev = normalise(f.Evidence__c);
            if (ev.contains(needle) || needle.contains(ev)) {
                return f.Certainty__c;
            }
        }
        return null;
    }

    private static String weakestLink(List<String> certs) {
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

    // --- small helpers -------------------------------------------------------

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

    private static Decimal toDecimal(Object o) {
        if (o == null) {
            return 0;
        }
        try {
            return Decimal.valueOf(String.valueOf(o));
        } catch (Exception e) {
            return 0;
        }
    }

    private static Decimal clamp(Decimal d) {
        if (d < 0) { return 0; }
        if (d > 1) { return 1; }
        return d;
    }

    private static String normalise(String s) {
        return s == null ? '' : s.toLowerCase().replaceAll('\\s+', ' ').trim();
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
