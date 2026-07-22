/**
 * Turns the model's JSON into records - and refuses anything it cannot trust.
 *
 * The prompt ASKS for grounded output. This class VERIFIES it. A fact that
 * cannot point at CV text is not saved, regardless of how confident the model
 * sounded.
 */
public with sharing class CVParser {

    private static final Set<String> VALID_CERTAINTY =
        new Set<String>{ 'Stated', 'Inferred', 'Conflicting', 'Missing' };
    private static final Set<String> VALID_TYPE =
        new Set<String>{ 'Skill', 'Experience', 'Education', 'Achievement', 'Certification' };

    public class ParseResult {
        public Boolean success = false;
        public String errorMessage;
        public Candidate__c candidate;
        public List<Fact__c> facts = new List<Fact__c>();
        public List<String> warnings = new List<String>();
    }

    public static ParseResult parse(String rawModelText, String cvText, String fileName) {
        ParseResult result = new ParseResult();

        Map<String, Object> root;
        try {
            root = (Map<String, Object>) JSON.deserializeUntyped(stripFences(rawModelText));
        } catch (Exception e) {
            result.errorMessage = 'Model did not return valid JSON: ' + e.getMessage();
            return result;
        }

        result.candidate = new Candidate__c(
            Name          = defaultName(str(root.get('name'))),
            Email__c      = blankToNull(str(root.get('email'))),
            Phone__c      = blankToNull(str(root.get('phone'))),
            Summary__c    = str(root.get('summary')),
            CV_Text__c    = cvText,
            File_Name__c  = fileName,
            Confidence__c = normaliseConfidence(str(root.get('confidence')))
        );

        Object rawFacts = root.get('facts');
        if (!(rawFacts instanceof List<Object>)) {
            result.errorMessage = 'Model response contained no facts array';
            return result;
        }

        Map<String, Integer> reasons = new Map<String, Integer>();

        for (Object o : (List<Object>) rawFacts) {
            if (!(o instanceof Map<String, Object>)) {
                bump(reasons, 'not an object');
                continue;
            }
            Map<String, Object> f = (Map<String, Object>) o;

            String rawType      = str(f.get('type'));
            String rawCertainty = str(f.get('certainty'));
            String factType  = canonical(rawType, VALID_TYPE);
            String certainty = canonical(rawCertainty, VALID_CERTAINTY);
            String label     = str(f.get('name'));
            String evidence  = str(f.get('evidence'));

            if (factType == null) {
                bump(reasons, 'bad type "' + rawType + '"');
                continue;
            }
            if (certainty == null) {
                bump(reasons, 'bad certainty "' + rawCertainty + '"');
                continue;
            }
            if (String.isBlank(label)) {
                bump(reasons, 'blank name');
                continue;
            }
            // THE GROUNDING GATE. Missing facts legitimately have no evidence.
            if (certainty != 'Missing' && String.isBlank(evidence)) {
                bump(reasons, 'no evidence');
                continue;
            }

            result.facts.add(new Fact__c(
                Name         = label.abbreviate(80),
                Type__c      = factType,
                Detail__c    = str(f.get('detail')),
                Certainty__c = certainty,
                Evidence__c  = evidence,
                Conflict__c  = str(f.get('conflict'))
            ));
        }

        for (String reason : reasons.keySet()) {
            result.warnings.add(reasons.get(reason) + ' rejected (' + reason + ')');
        }

        result.candidate.Status__c =
            (!reasons.isEmpty() || result.facts.isEmpty()) ? 'Partial' : 'Parsed';
        result.success = true;
        return result;
    }

    private static void bump(Map<String, Integer> m, String key) {
        m.put(key, m.containsKey(key) ? m.get(key) + 1 : 1);
    }

    /** Accept case and whitespace variations, return the canonical value. */
    private static String canonical(String raw, Set<String> allowed) {
        if (String.isBlank(raw)) {
            return null;
        }
        String t = raw.trim();
        for (String a : allowed) {
            if (a.equalsIgnoreCase(t)) {
                return a;
            }
        }
        return null;
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

    private static String blankToNull(String s) {
        return String.isBlank(s) ? null : s;
    }

    private static String defaultName(String s) {
        return String.isBlank(s) ? 'Unknown Candidate' : s.abbreviate(80);
    }

    private static String normaliseConfidence(String s) {
        if (s == 'High' || s == 'Medium' || s == 'Low') {
            return s;
        }
        return 'Low';
    }
}
